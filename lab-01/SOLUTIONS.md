# Lab 01 solutions

> **Spoilers.** Try the lab and [HINTS.md](HINTS.md) first. You'll learn far
> more from fighting with it for a while.

## The big picture

Four independent root causes stacked on top of each other. Each one hid the
next, which is typical of real incidents after a messy change window.

```text
  Your Mac ---X---> host firewall (ufw): default deny, only 22/tcp allowed ...... Issue A
                          |
                       nginx :80 ---X---> upstream 127.0.0.1:8081 ............... Issue D
                                          (nothing listens there)
                       bookshop backend :8080   [failed]
                          |-X- can't read /etc/bookshop/bookshop.conf
                          |    (now root:root 0600; the service runs as "bookshop") ... Issue B
                          '-X- audit volume /var/log/bookshop is 100% full:
                               trace-debug.log was deleted but is still held open
                               by bookshop-tracer (Restart=always, enabled at boot) ... Issue C
```

| # | Issue | Category | Visible symptom |
|---|---|---|---|
| A | Host firewall drops HTTP | networking | timeout from outside; works from inside |
| B | Config file unreadable by the service account | permissions, systemd | `bookshop.service` failed, `PermissionError` in the journal |
| C | Disk full from a deleted-but-open file, plus a runaway service | disk, processes, systemd | `No space left on device`; `df` shows 100% but `du` finds nothing |
| D | nginx upstream points at the wrong port | logs, ports | `502 Bad Gateway`, `connect() failed (111: Connection refused)` |

---

## Walkthrough: one efficient path

You might take a different route, and that's fine. This is the "outside in"
approach. The sample output uses `172.16.129.11` for web-01 and `172.16.129.1`
for the Mac. Your subnet will differ.

**1. Reproduce from the user's side (on the Mac).**

```console
$ curl -v --max-time 5 http://<LAB_IP>/
*   Trying 172.16.129.11:80...
* Connection timed out after 5002 milliseconds
curl: (28) Connection timed out after 5002 milliseconds
```

It's a *timeout*, not "connection refused". Note that, because it matters later.
Meanwhile `vagrant ssh` works, so the machine and the network path are up.

**2. Same request from inside the server.**

```console
$ curl -sI http://localhost/ | head -1
HTTP/1.1 502 Bad Gateway
```

Inside, you get an answer, but it's a 502. So there are at least two problems:
something between the Mac and nginx (Issue A), and something behind nginx.

**3. What does nginx say?**

```console
$ sudo tail -n 1 /var/log/nginx/error.log
... [error] ... connect() failed (111: Connection refused) while connecting to upstream,
client: 127.0.0.1, server: _, request: "GET / HTTP/1.1", upstream: "http://127.0.0.1:8081/", ...
```

**4. Is the backend running?**

```console
$ systemctl status bookshop
× bookshop.service - Pinewood Books storefront backend
     Loaded: loaded (/etc/systemd/system/bookshop.service; enabled; preset: enabled)
     Active: failed (Result: exit-code) since ...
...
bookshop.service: Start request repeated too quickly.
bookshop.service: Failed with result 'exit-code'.

$ sudo journalctl -u bookshop -n 20 --no-pager
...
    with open(args.config, encoding="utf-8") as fh:
         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
PermissionError: [Errno 13] Permission denied: '/etc/bookshop/bookshop.conf'
```

That's Issue B. Fix it (see below) and restart. The service fails again, but with
a *different* error:

```console
$ sudo journalctl -u bookshop -n 4 -o cat --no-pager
FATAL cannot write audit log: [Errno 28] No space left on device (free 0 MiB, need 50 MiB): '/var/log/bookshop/audit.log'
FATAL refusing to start without audit logging (policy SEC-7)
```

That's Issue C. Fix it, restart, and the backend is finally `active (running)`.

**5. Still 502?** nginx is trying `127.0.0.1:8081`, but `ss -tlnp` shows the
backend on `127.0.0.1:8080`. That's Issue D. Fix it, and `curl localhost` returns 200.

**6. Back on the Mac, still a timeout.** Now that everything inside works, the
only thing left between the Mac and nginx is the host firewall. That's Issue A.

**7. Verify:** load the page from the Mac, run `sudo lab-check`, then
`sudo reboot` and check again.

---

## Issue A: host firewall blocks HTTP

**Root cause.** The "security hardening" item in last night's change enabled
`ufw` with a default-deny policy for incoming traffic, and it only allowed SSH
(22/tcp). nginx was listening on all interfaces the whole time, but the kernel
dropped every incoming packet for port 80 before nginx ever saw it.

**Diagnose.**

```console
$ sudo ss -tlnp | grep ':80 '
LISTEN 0 511   0.0.0.0:80   0.0.0.0:*   users:(("nginx",pid=...))     <- listening on ALL interfaces

$ sudo ufw status verbose
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), deny (routed)
...
To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    Anywhere                   # SSH
22/tcp (v6)                ALLOW IN    Anywhere (v6)              # SSH

$ sudo journalctl -k --since "-5min" | grep 'UFW BLOCK'          # right after a retry from the Mac
... [UFW BLOCK] IN=eth1 OUT= ... SRC=172.16.129.1 DST=172.16.129.11 ... PROTO=TCP SPT=53122 DPT=80 ... SYN
```

(Your interface name may differ.) You can also *watch* the SYNs arrive and go
unanswered: `sudo tcpdump -ni any tcp port 80`, then retry from the Mac.

**Fix.**

```bash
sudo ufw allow 80/tcp          # or: sudo ufw allow 'Nginx HTTP'
sudo ufw status
```

**Don't:** `ufw disable` or `ufw default allow incoming`. Either one "works",
but it removes protection from every other port. Check 6 fails if you do it.
Also, `iptables -I INPUT -p tcp --dport 80 -j ACCEPT` works only until the next
reboot, because ufw rebuilds its rules from `/etc/ufw/*.rules` at boot. Check 5
fails if you do that.

**Concepts.**
- **Timeout vs refused.** *Refused* (a TCP RST) means the host received the
  packet and nothing listens on that port, or a firewall REJECTs it. A
  *timeout* means the packet was silently dropped (a firewall DROP, routing, or
  the host is down).
- **Test from multiple vantage points.** Requests from the VM to itself go over
  the loopback interface, which ufw always allows. That's why `curl localhost`
  inside the VM can never show you a firewall problem.
- `ufw` is a friendly front end. Underneath, the kernel's netfilter
  (`nftables`/`iptables`) does the filtering. Run `sudo iptables -S` or
  `sudo nft list ruleset` to see what ufw generated.
- Default policies, rule order, and persistent vs runtime rules.

**Prevention.** Firewall changes should go through review with a list of
required ports per service. After any change window, test with a synthetic
check *from outside* the host. Use configuration management (Ansible, etc.) so
the allowed ports are declared next to the service.

---

## Issue B: config file unreadable by the service account

**Root cause.** During the change window someone edited
`/etc/bookshop/bookshop.conf` as root and copied it back with mode `0600` and
owner `root:root`. The backend runs as the unprivileged user `bookshop`, so it
can no longer open its own config. It crashes on startup, systemd retries five
times in quick succession, and then gives up (`start-limit-hit`).

**Diagnose.**

```console
$ ls -l /etc/bookshop/bookshop.conf
-rw------- 1 root root 497 Nov  8 06:31 /etc/bookshop/bookshop.conf     <- recently modified, too

$ systemctl show -p User bookshop
User=bookshop

$ sudo -u bookshop cat /etc/bookshop/bookshop.conf
cat: /etc/bookshop/bookshop.conf: Permission denied

$ namei -l /etc/bookshop/bookshop.conf        # checks every directory on the path too
f: /etc/bookshop/bookshop.conf
drwxr-xr-x root root /
drwxr-xr-x root root etc
drwxr-xr-x root root bookshop
-rw------- root root bookshop.conf
```

**Fix.** Give the service's group read access and nobody else.

```bash
sudo chown root:bookshop /etc/bookshop/bookshop.conf
sudo chmod 0640 /etc/bookshop/bookshop.conf
sudo systemctl restart bookshop       # if it refuses: sudo systemctl reset-failed bookshop
```

`root:bookshop 0640` means root can edit it, the app can read it, and everyone
else gets nothing. The app can't modify its own config either, which is a bonus.

**Don't:** `chmod 644` or `chmod 777`. The file holds a payment API key, so
world-readable means every local user and every compromised process can read
it. Also don't change the unit to `User=root` to "get past" permissions, because
then any bug in the app is a root bug. Check 6 catches all of these.

**Concepts.**
- Owner, group and other; `rwx`; octal modes (`0640` = `rw-r-----`); `stat -c '%a %U:%G' file`.
- To open a file you need execute (`x`) permission on every directory in the
  path *and* read on the file. That's what `namei -l` shows.
- Which user a service runs as: `User=`/`Group=` in the unit, `systemctl show -p User`, `ps -o user,pid,cmd`.
- systemd restart behaviour: `Restart=on-failure`, `RestartSec=`, and start rate
  limiting (`StartLimitBurst`/`StartLimitIntervalSec`). After the limit is hit,
  the unit stays `failed` until you start it again or run `reset-failed`.
- Reading a Python traceback: the **last line** has the error, and the lines
  above it show where it happened.

**Prevention.** Manage config files with configuration management, which
enforces owner and mode on every run. Edit root-owned files with `sudoedit`. Put
files in place with `install -o root -g bookshop -m 0640 src dst`, which sets
ownership and mode explicitly instead of inheriting them from your umask or
from `cp`. Alert on a service in `failed` state.

---

## Issue C: disk full from a deleted-but-open file and a runaway service

This is the "aha" issue of the level.

**Root cause.** A "temporary" debugging tool, `bookshop-tracer`, was left
running as a systemd service. It wrote verbose traces into the dedicated 1 GB
log volume at about 1 MB/s until the volume filled up. The night on-call
"cleaned up some old logs" with `rm`. That removed the file's *name*, but the
tracer still had the file open, so the kernel couldn't free its blocks. The
volume stayed 100% full, and the backend (which refuses to run without at least
50 MiB of audit-log headroom) couldn't start.

Two extra twists:
- The unit has `Restart=always`. If you `kill` the process, systemd starts a new
  one within 5 seconds, which creates a new trace file and starts filling the
  disk again.
- The unit is **enabled**, so it comes back after every reboot too.

**Diagnose.**

```console
$ df -h /var/log/bookshop
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n2    974M  907M     0 100% /var/log/bookshop

$ sudo du -sh /var/log/bookshop
24K     /var/log/bookshop                          <- df says 907M used, du finds 24K?!

$ sudo lsof +L1                                    # open files with fewer than 1 link, i.e. deleted
COMMAND  PID     USER   FD   TYPE DEVICE  SIZE/OFF NLINK NODE NAME
python3 1653 bookshop    3w   REG  259,2 950206464     0   13 /var/log/bookshop/trace-debug.log (deleted)

$ ps -fp 1653
UID          PID    PPID  C STIME TTY          TIME CMD
bookshop    1653       1  0 06:31 ?        00:00:00 /usr/bin/python3 /usr/local/bin/bookshop-tracer

$ systemctl status 1653                            # systemctl accepts a PID: which unit owns it?
● bookshop-tracer.service - Bookshop request tracer (TEMPORARY - debugging INC-4471)
     Loaded: loaded (/etc/systemd/system/bookshop-tracer.service; enabled; preset: enabled)
     Active: active (running) since ...
```

(The device name may be `/dev/loop0` if the extra disk wasn't attached. That
makes no difference to the lab.) No `lsof`? Try
`sudo find /proc/*/fd -lname '*(deleted)' -ls`.

**Fix.**

```bash
sudo systemctl disable --now bookshop-tracer      # stop it now AND at boot
sudo rm -f /var/log/bookshop/trace-debug.log      # only exists if it was restarted meanwhile
df -h /var/log/bookshop                           # back to ~1%
sudo systemctl restart bookshop
```

In a real company, you'd also tell the owner of INC-4471, then remove the unit
and script (or `systemctl mask` it) once they agree.

**Emergency relief without killing the process.** Sometimes you can't stop the
process yet, for example a database in the middle of a transaction. You can
truncate the deleted file through `/proc`:
`sudo truncate -s 0 /proc/<PID>/fd/<FD>` (FD `3` above). The blocks are freed
immediately and the process keeps running. That buys time, but it doesn't fix
anything.

**Concepts.**
- **Files vs names (inodes).** A file is an inode plus data blocks. A directory
  entry is just a *name* pointing to an inode. `rm` removes the name (unlink).
  The kernel frees the inode and its blocks only when the link count is 0
  **and** no process has the file open.
- **`df` vs `du`.** `df` asks the filesystem how many blocks are allocated. `du`
  walks directories and adds up the files it can see. A big gap between them
  usually means deleted-but-open files (or files hidden under a mount point).
- **Reserved blocks.** `Size 974M, Used 907M, Avail 0`. Where are the other
  ~67M? ext4 reserves 5% for root by default (`sudo tune2fs -l <device> | grep
  -i 'reserved block'`). The backend runs as non-root, so for it the volume was
  full even though root could still write.
- **Who started this process?** `systemctl status <PID>`, `ps -o pid,ppid,user,cmd -p <PID>`,
  `pstree -sp <PID>`, and the unit's `Restart=` setting.
  `kill` only fights the symptom, while `systemctl stop`/`disable`/`mask`
  addresses the cause.
- `start` vs `enable`: `start`/`stop` change *now*, and `enable`/`disable` change *boot*.
  `disable --now` does both.
- **Why a reboot "fixed" the disk.** Rebooting kills every process, so the
  deleted file is finally released. But the tracer is enabled, so it starts
  again, creates a fresh (now visible) `trace-debug.log`, and fills the volume
  again in about 15 minutes. If you rebooted early, that's what you saw.

**Prevention.**
- Never `rm` a log file that a process has open. Truncate it instead
  (`truncate -s 0 file` or `: > file`), or rotate it properly with logrotate
  using `copytruncate` or a `postrotate` signal so the writer reopens.
- Time-box debugging tools: a `RuntimeMaxSec=` on the unit, a removal ticket, or
  an owner and expiry date in the description.
- Alert on disk usage *rate* (time until full), not just a threshold, and page
  someone who acts on it instead of only acking it.
- Keep noisy logs on their own volume (done right here). It contained the blast
  radius to one app instead of the whole OS.

---

## Issue D: nginx upstream points at the wrong port

**Root cause.** Prep work for a backend port move changed the nginx upstream to
`127.0.0.1:8081`. The backend still listens on `8080`, as configured in
`/etc/bookshop/bookshop.conf`. nginx itself was healthy, but it had nowhere to
send requests, so every request got a 502.

**Diagnose.**

```console
$ sudo tail -n 1 /var/log/nginx/error.log
... connect() failed (111: Connection refused) while connecting to upstream, ...
    upstream: "http://127.0.0.1:8081/", host: "localhost"

$ sudo ss -tlnp
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      5          127.0.0.1:8080       0.0.0.0:*    users:(("python3",pid=2362,fd=3))
LISTEN 0      511          0.0.0.0:80         0.0.0.0:*    users:(("nginx",pid=...))
...

$ sudo nginx -T | grep -n -B1 -A3 'upstream bookshop_backend'
# configuration file /etc/nginx/conf.d/bookshop-upstream.conf:
# Backend for the Pinewood Books storefront.
upstream bookshop_backend {
    server 127.0.0.1:8081;
}
```

Gotcha: `grep -r proxy_pass /etc/nginx/sites-enabled/` finds **nothing**,
because the files there are symlinks and `grep -r` doesn't follow them. Use
`grep -R`, or better, `nginx -T`, which prints the exact merged config nginx
loaded.

**Fix.**

```bash
sudo sed -i 's/127.0.0.1:8081/127.0.0.1:8080/' /etc/nginx/conf.d/bookshop-upstream.conf
sudo nginx -t                    # always validate before reloading
sudo systemctl reload nginx      # graceful: no dropped connections
curl -sI http://localhost/ | head -1     # HTTP/1.1 200 OK
```

`reload` is graceful and asynchronous: old workers finish their requests while
new ones start. A request sent within the same second can still hit an old
worker and get the old behaviour. Give it a moment before you decide it didn't
work.

(Changing the backend to listen on 8081 would also work. But the smallest
change that restores service is better in an incident. The port move can
happen properly later.)

**Concepts.**
- **Reverse proxy**: the client talks to nginx, and nginx talks to the backend.
- **502 vs 503 vs 504.** 502 Bad Gateway means the upstream refused the
  connection or sent garbage. 503 means the service is unavailable (here, the
  app returns 503 when its audit log is full). 504 means the upstream timed out.
- `ss -tlnp` shows what is listening, on which address and port, and which process owns it.
- `nginx -t` (validate), `nginx -T` (dump the full config), and `reload` vs `restart`.
- **Config drift.** Two files must agree (nginx upstream and app port), and a
  half-finished change left them out of sync.

**Prevention.** Ship coupled changes together, or make one value the single
source of truth (template both configs from the same variable). Use a health
check that goes *through* the proxy, not just straight to the app.

---

## Verifying the fix

```bash
# on the Mac
open http://<LAB_IP>/            # or: curl -s http://<LAB_IP>/ | grep Pinewood

# in the VM
sudo lab-check                     # expect 6/6 PASS
sudo reboot                        # then: vagrant ssh && sudo lab-check  (still 6/6)
```

---

## Example post-incident note

> **INC-2207: Storefront outage on web-01 (SEV-2)**
>
> **Impact:** The storefront was unavailable to all customers from about 02:14
> (degraded) / 06:55 (fully down) until <time fixed>.
>
> **Root causes:**
> 1. A temporary debug tracer (INC-4471) was left running and enabled. It
>    filled the 1 GB audit-log volume. The on-call deleted its log file, but the
>    file stayed open, so no space was freed. The backend refuses to serve
>    without audit-log space (SEC-7).
> 2. CHG-0311 replaced the backend config with `root:root 0600`, so the
>    `bookshop` service account could no longer read it.
> 3. CHG-0311 pointed nginx's upstream at port 8081 ahead of a planned port
>    move. The backend still listens on 8080.
> 4. CHG-0311 enabled the host firewall without allowing HTTP.
>
> **Resolution:** Disabled the tracer and freed the space. Restored config
> ownership and mode to `root:bookshop 0640`. Pointed the upstream back to
> 8080. Allowed 80/tcp in ufw. Verified from outside the host and after a reboot.
>
> **What went well:** The separate log volume kept the OS disk healthy. The
> backend failed safe instead of serving without an audit trail.
>
> **Action items:**
> - Remove or time-box debug tooling (`RuntimeMaxSec`, owner and expiry in the unit description).
> - Runbook entry: "disk full, but `du` disagrees with `df`", using `lsof +L1`.
> - Manage `/etc/bookshop` and nginx config with config management, with enforced modes.
> - Firewall changes must list the required ports. Add an external synthetic HTTP check after change windows.
> - Disk alerts should page based on time-until-full, and acking needs a follow-up ticket.

Write it **blameless**: describe how the system and process let it happen, not
who typed what.

---

## Cheat sheet: commands from this level

| Task | Command |
|---|---|
| Is a service running, and why not? | `systemctl status <unit>` · `journalctl -u <unit> -n 50 --no-pager` · `journalctl -u <unit> -f` |
| What's failed? | `systemctl list-units --failed` |
| Start vs enable | `systemctl start/stop <unit>` (now) · `systemctl enable/disable <unit>` (boot) · `systemctl disable --now <unit>` |
| Clear start-limit state | `systemctl reset-failed <unit>` |
| Which unit owns a PID? | `systemctl status <PID>` |
| Process details | `ps -fp <PID>` · `ps -o pid,ppid,user,cmd -p <PID>` · `pstree -sp <PID>` |
| Disk usage by filesystem | `df -h` · `df -i` (inodes) |
| Disk usage by directory | `du -sh /path/*` · `ncdu /path` |
| Deleted-but-open files | `lsof +L1` · `find /proc/*/fd -lname '*(deleted)'` |
| Free a deleted file's space now | `truncate -s 0 /proc/<PID>/fd/<FD>` |
| Permissions | `ls -l` · `stat -c '%a %U:%G %n' <file>` · `namei -l <path>` · `sudo -u <user> cat <file>` |
| Change ownership and mode | `chown user:group <file>` · `chmod 0640 <file>` · `install -o -g -m` |
| What's listening? | `ss -tlnp` (TCP) · `ss -ulnp` (UDP) |
| HTTP from the CLI | `curl -v URL` · `curl -sI URL` · `curl -s -o /dev/null -w '%{http_code}\n' URL` |
| nginx | `nginx -t` · `nginx -T` · `systemctl reload nginx` · `/var/log/nginx/{access,error}.log` |
| Firewall | `ufw status verbose` · `ufw allow 80/tcp` · `journalctl -k \| grep 'UFW BLOCK'` · `iptables -S` · `nft list ruleset` |
| Watch packets | `tcpdump -ni any tcp port 80` |

## Extra credit

1. The tracer runs as `bookshop`, not root. What would have changed if it ran as
   root? (Hint: reserved blocks.)
2. Make the fix for Issue C structural: write a logrotate config for
   `trace-debug.log` that would have prevented the deleted-file problem. Which
   directive do you need, and why?
3. Add `RuntimeMaxSec=8h` to the tracer unit with a drop-in
   (`systemctl edit bookshop-tracer`). Where does systemd store it, and how do
   you see the merged result? (`systemctl cat`)
4. Use `strace -f -e trace=openat -p <PID>` on the backend while you load the
   page. Which files does it open per request?
5. Why does `curl http://<LAB_IP>/` *from inside the VM* succeed even with
   the firewall blocking port 80? Prove it with `ip route get <LAB_IP>`.
