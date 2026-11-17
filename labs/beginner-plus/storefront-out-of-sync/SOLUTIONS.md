# Solutions: Out of sync with the warehouse

> **Spoilers.** Try the lab and [HINTS.md](HINTS.md) first. You'll learn far
> more from fighting with it for a while.

## The big picture

Three independent root causes, all in larch's *surroundings*, never in larch
itself, plus one alarm that isn't a problem at all. None of them leaves a
useful message in a log. Each one is plain to see as soon as you watch the
system calls.

```text
  warehouse-sim (scenery) --signed feed--> /srv/warehouse/outbox/stock.csv
                                               |
  larch-sync.timer, every 2 min: `larch sync` (user larch)
     open /etc/larch/keys/warehouse.key -X- EACCES: the keys directory is root:root 0700
                                           since yesterday's key rotation (CHG-0618) ........ Issue A
     so /var/lib/larch/stock.dat is frozen at yesterday 15:58 -> the shop sells sold-out books

  customers --> nginx :80 --> storefront (python, user storefront, HOME=/var/lib/storefront)
                                 |
                                 |-- POST /order --> /var/spool/larch/outgoing/PB-....order
                                 |                      |
                                 |   larch-ship (user larch): flock(spool.lock, LOCK_EX)
                                 |     -X- blocked: `larch admin reconcile` holds the lock, and is
                                 |         itself blocked in read(0) at a y/N prompt in Sam's tmux .... Issue B
                                 |
                                 '-- /book/N, estimate not cached --> `larch quote N`
                                       reads $HOME/.larch.conf (Sam's sandbox test, CHG-0611)
                                       instead of /etc/larch/larch.conf
                                       connect(/run/larch-sandbox/rates.sock) = ENOENT, sleep 0.5 s
                                       ... retry, sleep 1 s ... retry, sleep 2 s ... retry: 3.5 s
                                       then "Usually ships in 3-5 working days" ...................... Issue C

  strace of larch "full of No such file or directory" -> config search and the loader ..... red herring
```

| # | Issue | Category | Visible symptom | Since |
|---|---|---|---|---|
| A | Stock levels stuck | path resolution, directory permissions | `E2041 credential check failed` every 2 minutes. The key file's own permissions look right | CHG-0618, yesterday 16:00 |
| B | Orders don't reach the warehouse | file locks, blocking system calls, terminals | `larch-ship` is "active (running)", idle and silent. Orders pile up in the spool | this morning, when Sam ran `larch admin reconcile` |
| C | Book pages slow now and then | the process environment, config search paths, retries | 3.5 s on a cache miss, then fast for 5 minutes. A generic estimate everywhere | CHG-0611, 3 days ago |
| - | "The install is broken" | normal failed system calls | `ENOENT` all over an strace | none |

---

## System calls in five minutes

A process runs in **user space**: it can compute, and read and write its own
memory, and nothing else. Anything that touches the outside world (files,
other processes, the network, the clock, sleeping) goes through the
**kernel**. The process puts a call number and its arguments into CPU
registers and executes a special instruction (`svc` on ARM64, `syscall` on
x86-64). The CPU switches to kernel mode, the kernel does the work, and it
puts a result back in a register. That's a **system call**. Your C library
(glibc) wraps each one in a function, so a program calls `open()` or
`sleep()`, and glibc makes the real call (`openat`, `clock_nanosleep`).

The result is a number. Zero or more means success: for `openat` it's the new
**file descriptor**, a small integer that indexes the process's table of open
files (`/proc/<pid>/fd`). `-1` means failure, and a second number, **errno**,
says why: `ENOENT` (no such file), `EACCES` (permission denied), `EAGAIN`
(try again)... The program decides what to do with it. It can retry, try
something else, give up with a helpful message, or give up with an unhelpful
one, like `E2041`.

**How strace sees all this.** strace uses `ptrace`, the kernel's debugging
interface. The kernel stops the traced process at every system call's entry
and exit, and strace reads the registers, decodes the call, and prints it.
That's why it works on any program, in any language, with or without source
or symbols: the system call boundary is the same for everyone. It's also why
it's **slow**. Every call means two extra trips through the scheduler, and a
busy process can run 10 to 100 times slower under strace. In production,
attach briefly, filter with `-e`, and detach.

**Waiting.** Some calls return at once, and others *block*: `read` from a
terminal waits for someone to type, `flock` waits for a lock, `clock_nanosleep`
waits for time to pass. While a process waits, it's **asleep** in the kernel:
`S` in `ps`'s `STAT` column (or `D` for an uninterruptible wait, usually on
disk I/O). It uses no CPU. `top` shows 0%. `systemctl` says "active (running)".
`/proc/<pid>/wchan` names the kernel function it's sleeping in,
`/proc/<pid>/stack` shows the whole kernel call chain, and `strace -p` shows
the system call that got it there.

---

## Walkthrough: one efficient path

You might take a different route, and that's fine. Sample output is shortened.
PIDs, times and sizes will differ on your machine.

**1. Look at the scheduled job first** (it's the one with a message):

```console
$ systemctl status larch-sync.service
× larch-sync.service - Larch: fetch the warehouse's stock levels
     Active: failed (Result: exit-code) since Tue 2026-11-17 21:50:00 UTC; 29s ago
TriggeredBy: ● larch-sync.timer
   Main PID: 5839 (code=exited, status=1/FAILURE)
Nov 17 21:50:00 web-05 larch[5839]: larch[sync]: E2041 credential check failed
```

**2. Reproduce it exactly as the service runs it, and watch:**

```console
$ sudo -u larch strace -o /tmp/sync.trace larch sync
larch[sync]: E2041 credential check failed
$ tail -4 /tmp/sync.trace
openat(AT_FDCWD, "/etc/larch/conf.d", O_RDONLY|O_NONBLOCK|O_CLOEXEC|O_DIRECTORY) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/etc/larch/keys/warehouse.key", O_RDONLY|O_CLOEXEC) = -1 EACCES (Permission denied)
write(2, "larch[sync]: E2041 credential ch"..., 43) = 43
exit_group(1)                           = ?
$ namei -l /etc/larch/keys/warehouse.key
f: /etc/larch/keys/warehouse.key
drwxr-xr-x root root  /
drwxr-xr-x root root  etc
drwxr-xr-x root root  larch
drwx------ root root  keys            <- larch can't get past this
-rw-r----- root larch warehouse.key
```

Fix the directory (Issue A). Stock levels sync again.

**3. Orders.** larch-ship is running, uses no CPU, and the spool is filling up.
Ask the kernel what it's waiting for:

```console
$ ps -o pid,user,stat,wchan:24,cmd -C larch
    PID USER     STAT WCHAN                    CMD
   5369 larch    Ss   locks_lock_inode_wait    /opt/larch/bin/larch ship
   5652 larch    S+   wait_woken               larch admin reconcile
$ sudo strace -y -p 5369
strace: Process 5369 attached
flock(3</var/spool/larch/spool.lock>, LOCK_EX       <- and it never returns
$ sudo lsof /var/spool/larch/spool.lock
COMMAND  PID  USER   FD   TYPE DEVICE SIZE/OFF    NODE NAME
larch   5369 larch    3u   REG  252,0        0 1182743 /var/spool/larch/spool.lock
larch   5652 larch    3uW  REG  252,0        0 1182743 /var/spool/larch/spool.lock
$ sudo strace -p 5652
strace: Process 5652 attached
read(0,                                             <- waiting for someone to type
```

PID 5652 holds the lock (`W`) and waits for input on its terminal. It's Sam's
`larch admin reconcile`. Answer `n` in Sam's tmux session, or stop it (Issue B).
The backlog ships within 2 seconds.

**4. Book pages.** Make one slow on demand and watch the storefront and its
children:

```console
$ sudo rm /var/cache/storefront/estimates/6
$ sudo strace -f -tt -T -o /tmp/sf.trace -p $(systemctl show -p MainPID --value storefront) &
$ curl -s -o /dev/null -w '%{time_total}s\n' http://localhost/book/6
3.532365s
$ sudo kill %1; grep -E 'execve|larch.conf|connect|nanosleep' /tmp/sf.trace
6009  21:52:43.817050 execve("/opt/larch/bin/larch", ["/opt/larch/bin/larch", "quote", "6"], 0xffffc7002db0 /* 12 vars */ <unfinished ...>
6009  21:52:43.822019 openat(AT_FDCWD, "/var/lib/storefront/.larch.conf", O_RDONLY|O_CLOEXEC) = 3 <0.000058>
6009  21:52:43.823315 connect(3, {sa_family=AF_UNIX, sun_path="/run/larch-sandbox/rates.sock"}, 110) = -1 ENOENT (No such file or directory) <0.000082>
6009  21:52:43.823588 clock_nanosleep(CLOCK_REALTIME, 0, {tv_sec=0, tv_nsec=500000000},  <unfinished ...>
...
```

The storefront's larch reads a config file in its `HOME` that nobody knew
about. Move it away (Issue C). Book pages are fast, with real estimates.

---

## Issue A: the shop's stock levels are stuck

### Root cause

`larch sync` must read the warehouse key, `/etc/larch/keys/warehouse.key`, to
check the signature on the warehouse's stock feed. Yesterday at 16:00 Security
rotated the key (CHG-0618). Their script deleted the keys directory and
created it again as `root:root 0700`, then wrote the new key with exactly the
owner and mode Larch's README asks for: `root:larch 0640`.

To open a file, the kernel resolves its path one component at a time, and for
every **directory** on the way it checks the **search** permission, `x`, for
the calling user. `larch` has `x` on `/`, `/etc` and `/etc/larch`, but not on
`/etc/larch/keys`: owner root, group root, nothing for anyone else. So
`openat` fails with `EACCES` before the kernel ever looks at the key file's
own permissions. larch reports it as `E2041 credential check failed` and exits
with status 1. The timer tries again every 2 minutes, and fails every time.

### Diagnosis

The night on-call's check was right, as far as it went:

```console
$ ls -l /etc/larch/keys/warehouse.key
-rw-r----- 1 root larch 78 Nov 16 16:00 /etc/larch/keys/warehouse.key
```

The trace is short. Here's all of it, minus the loader's work:

```console
$ sudo -u larch strace -o /tmp/sync.trace larch sync
$ cat /tmp/sync.trace
execve("/usr/local/bin/larch", ["larch", "sync"], 0xfffff39be378 /* 12 vars */) = 0
faccessat(AT_FDCWD, "/etc/ld.so.preload", R_OK) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/etc/ld.so.cache", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "/lib/aarch64-linux-gnu/libc.so.6", O_RDONLY|O_CLOEXEC) = 3
...                                                   (the dynamic loader maps libc)
openat(AT_FDCWD, "/usr/lib/locale/locale-archive", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "/var/lib/larch/.larch.conf", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/usr/local/etc/larch/larch.conf", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/etc/larch/larch.conf", O_RDONLY|O_CLOEXEC) = 3
read(3, "# Larch fulfilment agent 4.2: Pi"..., 4096) = 561
close(3)                                = 0
openat(AT_FDCWD, "/etc/larch/conf.d", O_RDONLY|O_NONBLOCK|O_CLOEXEC|O_DIRECTORY) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/etc/larch/keys/warehouse.key", O_RDONLY|O_CLOEXEC) = -1 EACCES (Permission denied)
write(2, "larch[sync]: E2041 credential ch"..., 43) = 43
exit_group(1)                           = ?
+++ exited with 1 +++
```

Read it bottom up: the program exits, after writing its message, right after
one failed `openat`. The four `ENOENT`s above it are harmless (see
[the red herring](#the-red-herring-the-install-is-broken)). The trace also
documents larch's config search order, which Issue C depends on.

`EACCES` on a file whose permissions are fine always means "look at the
directories". `namei -l` shows every component's owner and mode at once.

### Fix

Let group `larch` search the directory, and nobody else:

```bash
sudo chgrp larch /etc/larch/keys
sudo chmod 0750 /etc/larch/keys        # rwx for root, r-x for group larch, nothing for others
sudo systemctl start larch-sync.service
systemctl status larch-sync.service    # Deactivated successfully
```

`0710` (search but not list) would work too. The next timer run updates the
shop within 2 minutes. `lab-check` triggers one immediately.

### What not to do

- **Don't `chmod 0755` (or 0777) the directory, or `chmod o+r` the key.** Both
  make the error go away. The second hands the warehouse key to every account
  on the server. The guard check fails on a key readable by others.
- **Don't run larch as root** (`User=root` in a drop-in). It would work, and
  turn every bug in a vendor binary you can't read into a root bug.
- **Don't copy the key somewhere else** and point `key_file` at it. Security
  rotates the key in `/etc/larch/keys`, and your copy goes stale at the next
  rotation.
- **Don't reinstall larch.** Nothing is wrong with it.

### Prevention

- Rotation scripts should set the owner and mode of everything they create,
  explicitly: `install -d -o root -g larch -m 0750 /etc/larch/keys`. A
  `mkdir` takes its mode from the umask, and root's umask in a hardening
  script is often `077`.
- After rotating, test as the consumer: `sudo -u larch larch sync`.
- Alert on what customers feel: the age of `stock.dat`, or a failed
  `larch-sync.service` (`OnFailure=` in the unit, or your monitoring's systemd
  check). The failure ran for 18 hours before anyone noticed.

### Concepts

- **Path resolution.** The kernel walks a path from `/`, one component at a
  time. Every directory needs `x` (search) for you to go through it. `r` on a
  directory only lets you *list* its names, and `w` lets you create, delete
  and rename entries in it. A file's own mode is checked last.
- **`EACCES` vs `EPERM` vs `ENOENT`.** `EACCES` means a permission bit said no.
  `EPERM` means the operation needs a privilege the process doesn't have (like
  `chown` for a normal user). `ENOENT` means a component of the path doesn't
  exist. Note that you get `EACCES`, not `ENOENT`, for files inside a directory
  you can't search, even if they don't exist. The kernel won't tell you.
- **errno.** `errno -l` lists them all, `man 3 errno` explains them, and each
  system call's man page lists the ones it can return.

---

## Issue B: orders don't reach the warehouse

### Root cause

Larch's agent lets only one larch at a time work in the spool: `larch ship`
and the admin commands each take an exclusive lock on
`/var/spool/larch/spool.lock` with `flock()` before they touch it, and wait
for as long as it takes to get it.

This morning Sam ran `sudo -u larch larch admin reconcile` in a tmux session,
to look at the 3 orders from Monday the warehouse never acknowledged. The
command took the spool lock, printed its findings, and asked
`Re-send them ...? [y/N]`. Then it called `read()` on its terminal, and has
been waiting there since, holding the lock. Sam went off shift and left the
tmux session running.

`larch ship` wakes up every 2 seconds, calls `flock(fd, LOCK_EX)`, and has
been asleep inside that call ever since. Restarting it doesn't help: the new
process blocks on the same lock at once. Meanwhile the storefront keeps
dropping orders into `outgoing/` and telling customers "Order placed".

### Diagnosis

```console
$ ls /var/spool/larch/outgoing
PB-20261117-4102.order  PB-20261117-4103.order  PB-20261117-4104.order ...
$ systemctl status larch-ship
     Active: active (running) since Tue 2026-11-17 21:47:49 UTC; 3min 37s ago
   Main PID: 5369 (larch)
        CPU: 1ms
Nov 17 21:47:51 web-05 larch[5369]: larch[ship]: sent PB-20261117-4101     <- the last order it sent
```

Active, 1 ms of CPU in nearly 4 minutes, silent. What is it waiting for?

```console
$ ps -o pid,user,stat,wchan:32,cmd -p 5369
    PID USER     STAT WCHAN                            CMD
   5369 larch    Ss   locks_lock_inode_wait            /opt/larch/bin/larch ship
$ sudo cat /proc/5369/stack
[<0>] locks_lock_inode_wait+0xb4/0x1f8
[<0>] __do_sys_flock+0x1e4/0x228
[<0>] __arm64_sys_flock+0x28/0x50
[<0>] invoke_syscall+0x7c/0x130
...
$ sudo strace -y -p 5369
strace: Process 5369 attached
flock(3</var/spool/larch/spool.lock>, LOCK_EX
```

Three views of the same fact: it's in the `flock` system call, waiting for a
lock on `/var/spool/larch/spool.lock`. Who holds it?

```console
$ cat /proc/locks
1: FLOCK  ADVISORY  WRITE 5652 fc:00:1182743 0 EOF
1: -> FLOCK  ADVISORY  WRITE 5369 fc:00:1182743 0 EOF
$ ls -i /var/spool/larch/spool.lock
1182743 /var/spool/larch/spool.lock
```

Lock 1 is held by PID 5652 on inode 1182743 of device `fc:00`, and the `->`
line is PID 5369 queued behind it. `sudo lsof /var/spool/larch/spool.lock`
says the same thing, with names: `3uW` marks the holder's write lock.

```console
$ ps -ef --forest
sam       5626     1  0 21:47 ?      00:00:00 tmux new-session -d -s larch -x 150 -y 45 -c /home/sam
sam       5627  5626  0 21:47 pts/0  00:00:00  \_ -bash
root      5649  5627  0 21:47 pts/0  00:00:00      \_ sudo -u larch larch admin reconcile
root      5651  5649  0 21:47 pts/1  00:00:00          \_ sudo -u larch larch admin reconcile
larch     5652  5651  0 21:47 pts/1  00:00:00              \_ larch admin reconcile
$ sudo strace -p 5652
strace: Process 5652 attached
read(0,
$ sudo ls -l /proc/5652/fd
lrwx------ 1 larch larch 64 Nov 17 21:51 0 -> /dev/pts/1
lrwx------ 1 larch larch 64 Nov 17 21:51 1 -> /dev/pts/1
lrwx------ 1 larch larch 64 Nov 17 21:51 2 -> /dev/pts/1
lrwx------ 1 larch larch 64 Nov 17 21:51 3 -> /var/spool/larch/spool.lock
```

The holder is reading fd 0, a pseudo-terminal, `/dev/pts/1`. That terminal
belongs to Sam's tmux session (`who` lists it too). Look at Sam's screen:

```console
$ sudo -u sam tmux attach -t larch
sam@web-05:~$ sudo -u larch larch admin reconcile
larch 4.2.1 reconcile: comparing shipped orders with the warehouse's acknowledgements...
402 orders shipped, 399 acknowledged.

3 shipped orders with no acknowledgement from the warehouse:
  PB-20261115-4062
  PB-20261115-4063
  PB-20261115-4064

Re-send them to the warehouse now? Orders the warehouse already has will be shipped twice. [y/N]
```

### Fix

Sam's handover note settles it: the warehouse already shipped those 3 orders,
and only the acknowledgements are missing. Answer `n` (in the tmux session:
type `n`, Enter, then detach with Ctrl-b d), or end the command:

```bash
sudo kill 5652          # SIGTERM. Use the PID from your own `cat /proc/locks`
```

Either way the process exits. When a process exits, the kernel closes all its
file descriptors, and closing the last descriptor for an open file releases
its `flock` locks. larch-ship's `flock` returns at once:

```console
$ journalctl -u larch-ship -n 4
Nov 17 21:53:59 web-05 larch[5369]: larch[ship]: sent PB-20261117-4104
Nov 17 21:53:59 web-05 larch[5369]: larch[ship]: sent PB-20261117-4105
Nov 17 21:53:59 web-05 larch[5369]: larch[ship]: sent PB-20261117-4106
Nov 17 21:53:59 web-05 larch[5369]: larch[ship]: sent PB-20261117-4107
```

Then tell Sam, so they know their reconcile didn't run.

### What not to do

- **Don't answer `y`.** That ships 3 orders twice, which is exactly what the
  ticket asks you not to do. Check 3 fails for good if you do, because the
  warehouse records the duplicates.
- **Don't delete the lock file.** It's tempting, and it's subtle why it's
  wrong. `flock` locks the *open file* (the inode), not the name. After `rm`,
  the stuck reconcile still holds its lock on the old, now nameless inode, and
  larch-ship still waits for it. The next larch to start creates a *new*
  `spool.lock` and locks that one without waiting. Now two larches can be in
  the spool at once: exactly what the lock was there to prevent.
- **Don't `kill -9` larch-ship** or keep restarting it. It isn't broken. It's
  waiting, correctly.
- **Don't reboot.** It would end the tmux session and release the lock, so the
  orders would flow, but you'd never learn why. Sam's reconcile would vanish
  without anyone knowing whether it ran.
- **Don't move the order files to the warehouse by hand.** larch-ship also
  files them under `sent/`, which the reconcile and your accountants rely on.

### Prevention

- **Never hold a lock while waiting for a human.** That's larch's design flaw,
  worth reporting to the vendor: ask the question first, then take the lock,
  then check that nothing changed. Lock holders should be short and bounded.
- Waiters should give up eventually: `flock -w 30` in scripts, `LOCK_NB` plus
  a retry loop with a timeout in code, and a log line that says *what* they're
  waiting for. Five silent hours is the worst outcome.
- Alert on the age of the oldest file in `outgoing/`, not on whether
  larch-ship is running. "Active (running)" isn't the same as "working".
- Interactive admin commands go in the runbook with a "finish what you start"
  rule. A shared team tmux, or a note in the handover, makes it visible when
  something is left half-done.

### Concepts

- **Advisory locks.** `flock()` (whole file) and `fcntl()` locks (byte ranges,
  "POSIX locks") only work between processes that *ask* for them. Any process
  can still read and write the file. `/proc/locks` lists them all, with the
  holder's PID, and `->` lines for waiters.
- **Locks and file descriptors.** A `flock` lock belongs to the open file (the
  thing `openat` created), not to the process or the file name. It's released
  when the last descriptor for that open file is closed, which includes every
  way a process can die. That's why the kernel cleans up after `kill`, and why
  deleting the file doesn't.
- **Blocking calls and process states.** A blocked process sleeps in the
  kernel: `S` (interruptible: a signal can wake it) or `D` (uninterruptible,
  usually disk I/O). `wchan` and `/proc/<pid>/stack` show where, and
  `strace -p` shows which system call. A sleeping process uses no CPU, which
  is why `top` makes it look fine.
- **Terminals.** fd 0, 1 and 2 of a command run in a terminal point at a
  pseudo-terminal, `/dev/pts/N`. `S+` in `STAT` means it's in the terminal's
  foreground process group. `sudo` here allocates its own pty (`use_pty`),
  which is why there are two `sudo` processes and two pts numbers.

---

## Issue C: book pages are slow now and then

### Root cause

When a book page's delivery estimate isn't in the 5-minute cache
(`/var/cache/storefront/estimates`), the storefront runs `larch quote <book>`
as a child process. The child inherits the storefront's environment, which
systemd set up from the `storefront` user: `HOME=/var/lib/storefront`.

larch looks for its configuration in this order, and stops at the first file
that exists: `$LARCH_CONF`, `$HOME/.larch.conf`,
`/usr/local/etc/larch/larch.conf`, `/etc/larch/larch.conf`. Three days ago,
while testing the 4.2 upgrade (CHG-0611), Sam created
`/var/lib/storefront/.larch.conf` to point quotes at Larch's sandbox rate
service. The sandbox's socket, `/run/larch-sandbox/rates.sock`, disappeared
when the test ended. The file stayed.

So for the storefront, and only for the storefront, every quote tries to
`connect()` to a socket that doesn't exist, sleeps 0.5 s, tries again, sleeps
1 s, tries again, sleeps 2 s, tries a last time, and falls back to the generic
"Usually ships in 3-5 working days". 3.5 seconds per uncached book page, and
the cache hides it for the next 5 minutes. That's why it comes and goes.

### Diagnosis

The pattern first: slow once, then fast, per book:

```console
$ for i in 1 2 3; do curl -s -o /dev/null -w '%{time_total}s\n' http://localhost/book/4; done
3.505047s
0.001707s
0.001499s
$ journalctl -u storefront -n 1
Nov 17 21:52:39 web-05 python3[5987]: larch[quote]: W3101 live rates unavailable, using the default estimate
```

"Live rates"? `/etc/larch/larch.conf` has `rates_socket` commented out. And
when you run it yourself, it's fine:

```console
$ time larch quote 4
In stock: ships in 2 working days.
real	0m0.001s
$ sudo -u storefront bash -c 'time larch quote 4'
Usually ships in 3-5 working days.
larch[quote]: W3101 live rates unavailable, using the default estimate
real	0m3.503s
```

Same binary, same argument, different user, different result. Watch the real
thing with timings, following the storefront's threads and children:

```console
$ sudo strace -f -tt -T -o /tmp/sf.trace -p $(systemctl show -p MainPID --value storefront)
(load an uncached book page in another terminal, then Ctrl-C)
$ grep -E 'execve|larch.conf|connect|nanosleep|exit_group' /tmp/sf.trace
6009  21:52:43.817050 execve("/opt/larch/bin/larch", ["/opt/larch/bin/larch", "quote", "6"], 0xffffc7002db0 /* 12 vars */ <unfinished ...>
6009  21:52:43.822019 openat(AT_FDCWD, "/var/lib/storefront/.larch.conf", O_RDONLY|O_CLOEXEC) = 3 <0.000058>
6009  21:52:43.823315 connect(3, {sa_family=AF_UNIX, sun_path="/run/larch-sandbox/rates.sock"}, 110) = -1 ENOENT (No such file or directory) <0.000082>
6009  21:52:43.823588 clock_nanosleep(CLOCK_REALTIME, 0, {tv_sec=0, tv_nsec=500000000},  <unfinished ...>
6009  21:52:44.324520 <... clock_nanosleep resumed>NULL) = 0 <0.500889>
6009  21:52:44.325254 connect(3, {sa_family=AF_UNIX, sun_path="/run/larch-sandbox/rates.sock"}, 110) = -1 ENOENT (No such file or directory) <0.000104>
6009  21:52:44.325664 clock_nanosleep(CLOCK_REALTIME, 0, {tv_sec=1, tv_nsec=0},  <unfinished ...>
6009  21:52:45.325957 <... clock_nanosleep resumed>NULL) = 0 <1.000222>
6009  21:52:45.326204 connect(3, {sa_family=AF_UNIX, sun_path="/run/larch-sandbox/rates.sock"}, 110) = -1 ENOENT (No such file or directory) <0.000047>
6009  21:52:45.326364 clock_nanosleep(CLOCK_REALTIME, 0, {tv_sec=2, tv_nsec=0},  <unfinished ...>
6009  21:52:47.327618 <... clock_nanosleep resumed>NULL) = 0 <2.001217>
6009  21:52:47.328036 connect(3, {sa_family=AF_UNIX, sun_path="/run/larch-sandbox/rates.sock"}, 110) = -1 ENOENT (No such file or directory) <0.000094>
6009  21:52:47.329818 exit_group(0)     = ?
```

How to read it:

- `-f` is essential. The work happens in a *grandchild*: the main thread
  starts a thread per request (`clone3` with `CLONE_THREAD`), that thread
  starts larch (`clone` with `CLONE_VFORK`, then `execve`), and each line
  carries its PID.
- `-T` puts the time spent in each call at the end. The `connect`s fail in
  microseconds. The *sleeps* take the time: 0.5 + 1 + 2 = 3.5 s. Nothing is
  slow. larch is waiting on purpose, between retries.
- The `openat` shows *which* config it read. It never even tries
  `/etc/larch/larch.conf`, because it found one in `HOME` first.
- `strace -c -w` on the same request makes the point as a table:

  ```text
  % time     seconds  usecs/call     calls    errors syscall
   70.78    8.533584      609541        14         1 ppoll
   29.06    3.503413     1167804         3           clock_nanosleep
    0.00    0.000505         126         4         4 connect
  ```

  `ppoll` is the web server's main thread idling between visitors, which is
  normal. Then 3.5 s of `clock_nanosleep`, and 4 `connect`s with 4 errors.

Why `HOME`?

```console
$ sudo tr '\0' '\n' </proc/$(systemctl show -p MainPID --value storefront)/environ | grep HOME
HOME=/var/lib/storefront
$ ls -la /var/lib/storefront/.larch.conf
-rw-r--r-- 1 storefront storefront 205 Nov 14 14:20 /var/lib/storefront/.larch.conf
$ cat /var/lib/storefront/.larch.conf
# Trying larch 4.2 quotes against Larch's sandbox before the upgrade (CHG-0611). -- Sam
account      = PINEWOOD-SANDBOX
stock_file   = /var/lib/larch/stock.dat
rates_socket = /run/larch-sandbox/rates.sock
```

### Fix

Move Sam's test config out of the storefront's home, and keep it, because it's
evidence for the post-incident note and for Sam:

```bash
sudo mv /var/lib/storefront/.larch.conf /root/sam-sandbox-larch.conf
sudo rm -f /var/cache/storefront/estimates/*       # forget the bad estimates
curl -s -o /dev/null -w '%{time_total}s\n' http://localhost/book/6
```

Optionally, make sure it can't happen again. Pin the storefront's larch to the
system config with a drop-in (`sudo systemctl edit storefront`):

```ini
[Service]
Environment=LARCH_CONF=/etc/larch/larch.conf
```

then `sudo systemctl restart storefront`. `$LARCH_CONF` comes first in larch's
search order, so a stray `~/.larch.conf` is never read again.

### What not to do

- **Don't create `/run/larch-sandbox/rates.sock`**, or start some fake
  service on it. The real problem is that the storefront uses a test
  configuration.
- **Don't raise the cache time.** Pages would be slow less often, and the
  estimates would still all be the generic fallback.
- **Don't just delete the file.** It's the only record of what was changed in
  CHG-0611, and Sam may want it for the next sandbox test.

### Prevention

- Test with an explicit config (`LARCH_CONF=/tmp/sandbox.conf larch quote 7`),
  never by leaving a file where the program looks by default. Every change
  should list what it created, and its back-out should remove it.
- Pin services to their configuration (an explicit `--config` or environment
  variable in the unit), so the contents of a home directory can't change
  their behaviour.
- Alert on the warning. `W3101` was in the journal on every cache miss for
  three days.

### Concepts

- **The process environment.** Every process gets a copy of its parent's
  environment at `execve` time. systemd builds a service's environment from
  the unit, and for `User=` it sets `HOME`, `USER`, `LOGNAME` and `SHELL` from
  the user's account. Your shell's environment has nothing to do with it.
  `/proc/<pid>/environ` shows a process's starting environment.
- **Config search paths.** Many programs read the first of several config
  files: `~/.ssh/config`, `~/.my.cnf`, `~/.gitconfig`, `~/.aws/config`,
  `~/.npmrc`. A file in a home directory quietly overrides `/etc`. strace with
  `-e trace=%file` shows the real search order, documented or not.
- **Retries with exponential backoff.** Waiting longer after each failure (0.5,
  1, 2 s) protects a struggling server. It also turns "fails instantly" into
  "slow", which is why the failure was hard to see.
- **Caches make slowness intermittent.** A slow path behind a 5-minute cache
  shows up as "sometimes slow". When something is "slow now and then", look for
  a cache, a schedule, or a lock.
- **UNIX sockets.** `connect()` to an `AF_UNIX` socket path that doesn't exist
  fails with `ENOENT`. A path that exists but where nobody listens fails with
  `ECONNREFUSED`. `ss -xlp` lists the UNIX sockets that have a listener, and
  which process owns each one.

---

## The red herring: "the install is broken"

The night on-call's strace *was* full of `ENOENT`, and every one of them is
normal:

| Call | Why it fails, and why that's fine |
|---|---|
| `faccessat("/etc/ld.so.preload") = -1 ENOENT` | The dynamic loader checks for this optional file at the start of *every* dynamically linked program. |
| `openat("/var/lib/larch/.larch.conf") = -1 ENOENT` | larch's config search: no personal config, move on. |
| `openat("/usr/local/etc/larch/larch.conf") = -1 ENOENT` | Same: no local override, move on to `/etc`. |
| `openat("/etc/larch/conf.d", ..., O_DIRECTORY) = -1 ENOENT` | Optional drop-in directory. |

Programs often ask "does this exist?" by simply trying it. A failed system
call only matters if the program *reacts* to it: it gives up, retries, or goes
another way. In Issue A, the error that mattered was the one right before
`exit_group(1)`. In Issue C, the errors that mattered were the ones followed by
`clock_nanosleep`. Reinstalling larch would have changed none of it.

---

## Verifying the fix

```bash
sudo lab-check                                   # 6/6
ls /var/spool/larch/outgoing                     # empty, or only orders a few seconds old
curl -s -o /dev/null -w '%{time_total}s\n' http://localhost/book/9   # fast, even uncached
sudo reboot                                      # then, after a minute:
sudo lab-check                                   # still 6/6
```

---

## Example post-incident note

> **INC-2471: stock levels, orders and delivery estimates out of sync with the warehouse**
>
> **Impact.** For about 18 hours the shop showed stale stock levels, and
> customers ordered at least 2 titles the warehouse had sold out of. From early
> this morning no orders reached the warehouse (5 customer orders delayed, all
> delivered once, none twice). For 3 days, uncached book pages took 3.5 s and
> every delivery estimate was a generic fallback.
>
> **Root causes.**
> 1. The key rotation (CHG-0618) recreated `/etc/larch/keys` as `root:root
>    0700`. The key file was correct, but larch couldn't enter the directory,
>    so every stock sync failed with `E2041` (`EACCES` on `openat`).
> 2. An interactive `larch admin reconcile` was left waiting at a y/N prompt
>    in a tmux session. It held the spool's `flock`, so `larch ship` waited in
>    `flock(LOCK_EX)`, silently, for hours.
> 3. A sandbox test config from the larch 4.2 upgrade (CHG-0611) was left at
>    `~storefront/.larch.conf`. larch reads it before `/etc/larch/larch.conf`,
>    so quotes retried a nonexistent socket for 3.5 s, then fell back.
>
> **Resolution.** Made `/etc/larch/keys` `root:larch 0750`. Answered "n" to
> the reconcile prompt (the warehouse already had those orders), which
> released the lock; the backlog shipped within seconds. Moved the test config
> to `/root` and pinned the storefront to `LARCH_CONF=/etc/larch/larch.conf`.
> Verified with lab-check, before and after a reboot.
>
> **Detection gap.** None of the three produced a useful log message. All
> three were found with strace: the failing `openat`, the blocked `flock`, and
> the `connect`/`clock_nanosleep` retry loop.
>
> **Actions.**
> - Security: rotation scripts set owner and mode explicitly, and test as the
>   consumer afterwards.
> - Platform: alert on stock.dat age, the oldest order in the spool, and
>   `W3101`/`E2041` in the journal.
> - Platform: test against sandboxes with an explicit `LARCH_CONF`. Back-out
>   plans list the files a change creates.
> - Vendor ticket: don't hold the spool lock while waiting for input, log
>   while waiting for a lock, and include the reason (`strerror`) in errors.

---

## Cheat sheet: system calls and the tools around them

| Question | Command |
|---|---|
| What does this command do, call by call? | `strace <cmd>`, `strace -o file -f <cmd>` |
| Which files does it touch? | `strace -e trace=%file <cmd>`, add `-Z` for failures only |
| What does a running process do? | `sudo strace -p <pid>`, add `-f` for threads and children |
| What's fd 3? | `sudo strace -y ...`, `sudo ls -l /proc/<pid>/fd` |
| Where does the time go? | `strace -tt -T ...`, `strace -c -w ...` |
| Run it the way the service does | `sudo -u <user> <cmd>`, `sudo systemd-run --pipe --wait -p User=<user> <cmd>` |
| What is a process waiting for? | `ps -o pid,stat,wchan:32,cmd -p <pid>`, `sudo cat /proc/<pid>/stack`, `strace -p` |
| Who holds a lock? | `cat /proc/locks` (PID, then device:inode), `sudo lsof <file>` |
| Who has this file open? | `sudo lsof <file>`, `sudo fuser -v <file>` |
| Where did this process come from? | `ps -ef --forest`, `pstree -aps <pid>` |
| What's its environment? Its current directory? | `sudo tr '\0' '\n' </proc/<pid>/environ`, `sudo ls -l /proc/<pid>/cwd` |
| Why can't it open this path? | `namei -l <path>` |
| Which UNIX sockets are listening? | `ss -xlp` |
| What does this error code mean? | `errno EACCES`, `errno -l`, `man 3 errno`, `man 2 <call>` |

---

## Extra credit

1. **Fault injection.** strace can *make* a system call fail:
   `sudo -u larch strace -e inject=openat:error=EACCES:when=5 larch sync`.
   Which file does the 5th `openat` open, and does larch's error message
   change? Try `ENOENT` on the config file instead.
2. **The cost of watching.** Time `dd if=/dev/zero of=/dev/null bs=1 count=500000`,
   then the same under `strace -o /dev/null`. How much slower, and why?
   Repeat with `strace -e trace=none` and with `--seccomp-bpf -e trace=openat`.
   What changed?
3. **Your own program.** `gcc` is installed. Write a 10-line C program that
   opens a file, takes an `flock`, and sleeps. Run two copies, and watch the
   second one with `strace -p`, `/proc/locks` and `wchan`. Then `kill -9` the
   first one and watch the second wake up.
4. **Process states.** `sudo kill -STOP` larch-ship and look at `STAT` (`T`).
   What happens to new orders? `kill -CONT` it. How is a stopped process
   different from one blocked in `flock`?
5. **Stack traces.** `strace -k` prints the user-space call stack for each
   system call. It's not much use on a stripped binary like larch. Try it on
   `ls`, then on the program from (3) compiled with `-g`.
6. **Lighter tools.** Read about `perf trace` and the `bpftrace` one-liners
   (`opensnoop`, `execsnoop`). They watch system calls for the whole system
   with a fraction of strace's overhead. They're the next step after this lab.
