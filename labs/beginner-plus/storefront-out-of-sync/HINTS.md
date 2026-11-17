# Hints: Out of sync with the warehouse

Use these only when you're stuck. Each issue has numbered hints that go from
vague to specific. Open one, then go back and try again before opening the
next. The last hint for each issue is close to the answer.

The section titles describe **symptoms you'll see**, not causes, so it's safe to
scroll. Hints stay collapsed until you click them. (They render as collapsible
blocks on GitHub and in most Markdown previewers. In a plain text editor,
everything is visible.)

## Before you start: a 15-minute strace warm-up (no spoilers)

A program can't open a file, start another program, sleep, take a lock or talk
to another process on its own. It asks the kernel to do it, with a **system
call** ("syscall"). `strace` runs a program, or attaches to one that's already
running, and prints every system call it makes, with the arguments and the
kernel's answer. It works on any program, with or without its source code.

Try these in the VM on harmless commands first:

1. **One line per system call.**

   ```bash
   strace cat /etc/hostname
   ```

   Each line reads `name(arguments) = result`. Near the end, find the `openat`
   that opens `/etc/hostname`. It returns a small number, a **file
   descriptor** (fd): the program's handle for the open file. Then find the
   `read` from that fd, and the `write` to fd 1, which is stdout. Everything
   before that is the program starting up: the dynamic loader finding and
   loading libraries (`libc.so.6`).

2. **Errors.**

   ```bash
   strace -e trace=openat cat /etc/shadow
   ```

   A failed call returns `-1` and an error code, here `EACCES (Permission
   denied)`. `errno -l` lists every error code, `errno EACCES` explains one,
   and `man 2 openat` (section 2 of the manual is the system calls) lists which
   errors a call can return and why.

3. **Only what you care about.**
   `-e trace=%file` shows only calls that take a file name, `%process` shows
   processes starting and ending, `%net` shows networking, `%desc` shows calls
   on file descriptors, and `-e trace=openat,read` shows just the ones you list.
   `-Z` shows only calls that failed. `-o trace.txt` writes to a file you can
   open with `less`, and `-s 200` prints longer strings.

4. **Children.**

   ```bash
   strace -f -e trace=execve,clone,clone3 bash -c 'id; date'
   ```

   Without `-f`, strace follows only the first process. With `-f` it follows
   every child and thread, and each line starts with the `[pid N]` it came
   from.

5. **Time.**

   ```bash
   strace -tt -T -e trace=clock_nanosleep sleep 1.5
   strace -c ls -R /usr/share/doc >/dev/null
   ```

   `-tt` puts the time of day in front of each line, and `-T` adds the time
   spent *inside* the call at the end, in `<seconds>`. `-c` prints a table
   instead: how many times each call ran, how many failed, and the time spent.
   Add `-w` to `-c` to count wall-clock time, which includes time spent waiting.

6. **Attaching to a running process.**

   ```bash
   sleep 600 | cat &     # cat waits to read from a pipe that sleep never writes to
   strace -p $!          # fails: "Operation not permitted"
   sudo strace -p $!     # works: read(0,
   kill %1
   ```

   Ubuntu only lets you trace your own children, so attaching to anything
   else needs `sudo`. `strace -p` shows the call the process is in right now,
   and waits. Ctrl-C detaches, and the process carries on as if nothing
   happened. Add `-y` to see file names next to fd numbers. If the process was
   in the middle of a sleep, you'll see `restart_syscall(<... resuming
   interrupted ...>)` instead: attaching interrupted the call, and the kernel
   restarted it. (On ARM64, strace sometimes names the wrong call in that line.)

7. **The rest of the toolbox.** Every process has a folder, `/proc/<pid>`:

   ```bash
   ls -l /proc/$$/fd          # $$ is your shell's PID: its open files
   ls -l /proc/$$/cwd         # its current directory
   tr '\0' '\n' </proc/$$/environ | head   # its environment
   cat /proc/$$/wchan; echo   # what it's waiting for inside the kernel
   ps -o pid,stat,wchan:30,cmd -p $$
   ```

   `S` in the `STAT` column means sleeping, waiting for something.
   `sudo cat /proc/<pid>/stack` shows the kernel functions it's waiting in.
   `sudo lsof -p <pid>` lists a process's open files. `sudo lsof <file>` lists
   who has a file open.

### A method for this lab

1. **Reproduce each symptom, and measure it.** A number beats an impression.
2. **Find the process responsible.** Which program is supposed to do this
   job? Is it running, sleeping, or not running at all? `systemctl status`,
   `systemctl list-timers`, `ps -ef --forest`.
3. **Watch it work.** Run it under `strace`, or attach to it.
4. **Find the one line that matters.** For a program that gives up, it's
   usually the *last* failed call before it exits. For a program that hangs,
   it's the call it's stuck in. For a slow one, it's the call with the biggest
   time.
5. **Turn that line into a question about the system.** Whose file is it? Who
   else has it open? Where does that path come from?
6. **Change one thing at a time**, then measure again and run `sudo lab-check`.

Commands worth knowing for this lab: `strace`, `ps`, `pstree`, `pgrep`,
`lsof`, `namei`, `ss`, `cat /proc/locks`, `/proc/<pid>/{fd,cwd,environ,wchan,stack}`,
`systemctl cat`, `journalctl -u`, `sudo -u`, `errno`, `man 2`.

### Which hints do I need?

| What you're seeing | lab-check item | Go to |
|---|---|---|
| The shop's stock levels never change. `E2041 credential check failed` | 1, 5 | [Issue A](#issue-a-the-shops-stock-levels-are-stuck) |
| Orders pile up in `/var/spool/larch/outgoing`. `larch-ship` is "active (running)" and says nothing | 2, 3 | [Issue B](#issue-b-orders-dont-reach-the-warehouse) |
| Book pages take seconds, sometimes. "Usually ships in 3-5 working days" everywhere | 4 | [Issue C](#issue-c-book-pages-are-slow-now-and-then) |
| You ran the same command yourself, and it worked fine | any | [It works when I run it](#it-works-when-i-run-it) |
| strace output full of "No such file or directory" | none | [Is the install broken?](#is-the-install-broken) |
| `strace -p` says "Operation not permitted" | none | warm-up step 6 |
| Orders flow again, but check 3 still fails | 3 | [Issue B](#issue-b-orders-dont-reach-the-warehouse), hint B6 |
| "Nothing important was removed or weakened" fails | 6 | [Guard check](#guard-check-6) |

---

## Issue A: the shop's stock levels are stuck

<details><summary>Hint A1</summary>

Who is supposed to update the stock levels, and how often? Find it in
`systemctl list-timers`, then read its unit with `systemctl cat`. Is it
running, and is it succeeding? `systemctl status <unit>` and
`journalctl -u <unit>`. Larch's README, `/opt/larch/README`, lists what the
message codes mean. What does the message tell you, and what does it *not*
tell you?

</details>

<details><summary>Hint A2</summary>

The night on-call checked the key file and found nothing wrong. Don't argue
with them yet. Reproduce the failure yourself, **exactly as the service runs
it**: same command (from `ExecStart=`), same user (`User=`):
`sudo -u larch larch sync`. Does it fail the same way? Now you have a failure
you can repeat as often as you like, and nothing else needs to change.

</details>

<details><summary>Hint A3</summary>

Watch the failure:

```bash
sudo -u larch strace -o /tmp/sync.trace larch sync
less /tmp/sync.trace
```

The trace is short. A program that gives up usually does it right after the
call that went wrong, so read it from the bottom up: find `exit_group(1)`,
then the error message it writes, then the call just before that. (There are
other failed calls higher up. See [Is the install broken?](#is-the-install-broken)
before you chase them.)

</details>

<details><summary>Hint A4</summary>

The call that matters is the `openat` of `/etc/larch/keys/warehouse.key`, and
it fails with `EACCES`. But `ls -l` says group `larch` may read the file, and
`id larch` says larch is in that group. So what else does the kernel check?
To open a path, it walks it one directory at a time, and checks a permission
on *every* directory on the way. Show them all at once:
`namei -l /etc/larch/keys/warehouse.key`. Which permission does a directory
need for you to pass *through* it?

</details>

<details><summary>Hint A5 (nearly the answer)</summary>

On a directory, `x` means "search": the right to go through it to something
inside. `/etc/larch/keys` is `drwx------ root root`. Only root can pass, so
the key's own permissions never come into play. Yesterday's key rotation
recreated the directory like that. Give group `larch` the right to go in, and
nobody else: `sudo chgrp larch /etc/larch/keys` and
`sudo chmod 0750 /etc/larch/keys`. Then run the job the way its timer does,
`sudo systemctl start larch-sync.service`, and check `systemctl status` and
the home page. Opening the key file to everyone, or running larch as root,
would also make the error go away, and the guard check knows.

</details>

---

## Issue B: orders don't reach the warehouse

<details><summary>Hint B1</summary>

Reproduce it. Place an order (`curl -s -d book=3 http://localhost/order`) and
watch where it goes: `ls -l /var/spool/larch/outgoing`. Which service is meant
to send it on? Larch's README and `systemctl list-units 'larch*'` will tell
you. Is that service running? Is it *busy*? `top`, or
`ps -o pid,stat,pcpu,cmd -C larch`.

</details>

<details><summary>Hint B2</summary>

A process that's running, uses no CPU and does nothing is almost always
*waiting* for something. Ask the kernel what:
`ps -o pid,stat,wchan:32,cmd -C larch` (the `WCHAN` column is the kernel
function it's sleeping in), and `sudo cat /proc/<pid>/stack`. Then attach to
it: `sudo strace -p <pid>`. Which call is it in, and does it ever return? Try
`sudo systemctl restart larch-ship` and look again. Does a restart help? Why
not?

</details>

<details><summary>Hint B3</summary>

It's stuck in `flock(3, LOCK_EX`. `man 2 flock`: it's waiting for an exclusive
**lock** on a file, and it waits as long as someone else holds one. Which file
is fd 3? `sudo ls -l /proc/<pid>/fd`, or attach again with `strace -y -p`.
Then, who holds a lock on it? Two ways to ask:

- `cat /proc/locks`: every lock in the system. The column after `WRITE` is
  the PID that holds it, and a line with `->` is a process waiting for it. The
  file is shown as `device:inode`, so compare with `ls -i <file>`.
- `sudo lsof <file>`: who has it open. A `W` after the fd number marks the
  process that holds the write lock.

</details>

<details><summary>Hint B4</summary>

Look at the lock holder: `ps -o pid,user,stat,tty,lstart,cmd -p <pid>`, and
where it came from: `ps -ef --forest` or `pstree -aps <pid>`. What is it
doing? Attach to it too. What's its fd 0 (stdin)? `sudo ls -l /proc/<pid>/fd`.
`who` can help as well.

</details>

<details><summary>Hint B5</summary>

The holder is `larch admin reconcile`. Sam started it in a `tmux` session,
and it's stuck in `read(0, ...`: it asked a question on its terminal and is
waiting for an answer, while holding the spool lock the whole time. You can
look at Sam's screen: `sudo -u sam tmux ls`, then
`sudo -u sam tmux attach -t <session>` (detach again with Ctrl-b, then d).
Before you type anything into it, read the question and Sam's handover note in
the ticket. What would each answer do?

</details>

<details><summary>Hint B6 (nearly the answer)</summary>

Don't answer `y`. The warehouse already has those 3 orders. Only their
acknowledgements are missing, and Larch is re-sending them. Re-sending the
orders would ship them twice. Either answer `n` in Sam's tmux session, or
stop the command with `sudo kill <pid>` (a plain `SIGTERM`). Either way the
process ends, and when a process ends the kernel closes its file descriptors,
which releases its lock. Then watch `journalctl -u larch-ship -f` and
`ls /var/spool/larch/outgoing`. If you already answered `y`, check 3 will keep
failing in this VM. Restore your snapshot and try again.

</details>

---

## Issue C: book pages are slow now and then

<details><summary>Hint C1</summary>

Measure it. Load the same book page in a loop:
`for i in $(seq 5); do curl -s -o /dev/null -w '%{time_total}s\n' http://localhost/book/4; done`.
Then a book you haven't opened yet. When is it slow? The app's own description
explains the pattern: `head -25 /opt/storefront/app.py`. Once you know why it's
only *sometimes*, make it slow on demand. That's what you need for the next
steps.

</details>

<details><summary>Hint C2</summary>

The estimate comes from `larch quote <book>`. Time it yourself:
`time larch quote 4`. Fast, with a sensible answer? Now the app's side:
`journalctl -u storefront` shows what larch wrote to stderr when the app ran
it. So the same command behaves differently for you and for the app. See
[It works when I run it](#it-works-when-i-run-it).

</details>

<details><summary>Hint C3</summary>

Watch the real thing. Attach to the storefront, follow every thread and
child (`-f`), and time every call:

```bash
sudo strace -f -tt -T -o /tmp/sf.trace -p $(systemctl show -p MainPID --value storefront)
```

In a second terminal, make a book page slow (hint C1) and load it. Then
Ctrl-C the strace. Find where the app starts larch (`grep -n execve
/tmp/sf.trace`), and follow that PID. Which calls take the time (the
`<seconds>` at the end of each line), and what happens just before each one?
(The storefront's main thread calls `ppoll` every half second with a timeout.
That's the web server waiting for visitors, and it's normal.)

</details>

<details><summary>Hint C4</summary>

larch tries to `connect` to a socket, gets `ENOENT`, sleeps, and tries again,
with longer sleeps each time, then gives up and uses a default estimate. Where
does that socket path come from? `/etc/larch/larch.conf` doesn't use it. So
which configuration file does larch read when the *storefront* runs it?
`grep -n openat /tmp/sf.trace`, for the larch PID. Compare with
`strace -e trace=%file larch quote 4` when *you* run it.

</details>

<details><summary>Hint C5</summary>

larch looks for `$HOME/.larch.conf` first, and only falls back to
`/etc/larch/larch.conf` if that doesn't exist. Every process has its own
environment: compare yours with the storefront's,
`sudo tr '\0' '\n' </proc/<storefront pid>/environ`. Which `HOME` does the
storefront have, and what's in it? `ls -la` that directory. Who made the file
in there, and when?

</details>

<details><summary>Hint C6 (nearly the answer)</summary>

It's Sam's test config from the larch 4.2 upgrade (CHG-0611), pointing quotes
at Larch's sandbox, whose socket no longer exists. Move it out of the
storefront's home, and keep a copy, because it's evidence:
`sudo mv /var/lib/storefront/.larch.conf /root/`. Or, as well, make the
storefront always use the system file:
`sudo systemctl edit storefront`, then add `[Service]` and
`Environment=LARCH_CONF=/etc/larch/larch.conf`, and restart it. Then empty the
cache (`sudo rm /var/cache/storefront/estimates/*`) and measure again.

</details>

---

## It works when I run it

A service doesn't run in your shell. It has its own user, its own environment
(`HOME`, `PATH`, `LANG`...), its own current directory, and no terminal. A
command that works for you can fail for a service, and the other way round.
To reproduce a problem faithfully:

- Run it as the same user, from the same command line (`systemctl cat <unit>`):
  `sudo -u <user> <command>`. `sudo` also sets `HOME` to that user's home
  directory.
- Compare environments: `sudo tr '\0' '\n' </proc/<pid>/environ` for the
  service, `env` for you. Also compare `ls -l /proc/<pid>/cwd`.
- Or have systemd run it for you, as a throwaway service with that user, and
  show you the output: `sudo systemd-run --pipe --wait -p User=<user> <command>`.
  The command gets the environment a service gets, not yours.
- Or skip reproducing and watch the real thing: `sudo strace -f -p <pid>`.

One trap: `sudo strace -u <user> <command>` runs the command as that user, but
keeps *root's* environment, including `HOME=/root`. That isn't how the service
runs. `sudo -u <user> strace <command>` is closer.

## Is the install broken?

<details><summary>The night on-call's strace was "full of No such file or directory"</summary>

Failed system calls are normal. Programs often *ask* the kernel whether
something exists by just trying it. Look at an strace of a command that works
perfectly, such as `strace -e trace=%file ls`: the dynamic loader checks for
`/etc/ld.so.preload` every time, and gets `ENOENT`. Programs that search for
their configuration try one place after another, and only the last attempt
succeeds. An error matters when the program *reacts* to it: it gives up,
retries, or takes a different path. So read what happens right after an error,
not how many errors there are. Reinstalling larch wouldn't have changed any of
them.

</details>

## Guard check (6)

<details><summary>Check 6: "Nothing important was removed or weakened"</summary>

It fails if any of these is true:

- `larch-sync` or `larch-ship` no longer run as the user `larch`, or the
  storefront no longer runs as `storefront`.
- Larch's binary, the warehouse key, or the warehouse simulator changed.
- The key file gives any permission at all to "others".
- Something in `/etc/larch`, `/etc/larch/keys`, `/var/lib/larch`, the spool,
  or the warehouse's inbox is writable by everyone.
- Shipped orders were deleted from `/var/spool/larch/sent`.

</details>
