# Solutions: It's slow, then it's not

> **Spoilers.** Try the lab and [HINTS.md](HINTS.md) first. You'll learn far
> more from fighting with it for a while.

## The big picture

Three independent root causes, each one a piece of *housekeeping* that quietly
stopped working, plus one alarm that isn't a problem at all.

```text
  customers ---> nginx :80 ---> storefront app (127.0.0.1:8080)
                   |              |
                   |              |-- every page reads ------------> shop.db (SQLite)
                   |              |                                    ^  BEGIN EXCLUSIVE for the whole run:
                   |              |                                    |  every page waits ~15 s
                   |              |                      storefront-trending (cron, every 5 minutes)
                   v              |                      reads ALL of access.log: 2 weeks, ~1 million lines
              access.log -X- not rotated since CHG-0507: /etc/logrotate.d/nginx is owned by sam,
                             mode 664, so logrotate ignores it ................................ Issue A
                                  |
                                  |-- new carts --> /var/lib/storefront/sessions (512 MB volume)
                                  |                 -X- 100% of inodes used, 29% of space: the cleanup
                                  |                     timer's OnCalendar= is in cron syntax, so it
                                  |                     hasn't fired since CHG-0496 ................... Issue B
                                  |
                                  '-- log ------> app.log.1 -X- last night's rotation renamed app.log, and
                                                  the postrotate reloads nginx, not the app (CHG-0519) .. Issue C

  /wp-login.php, /.env in the access log -> internet background noise, 404 in ~1 ms ........ red herring
```

| # | Issue | Category | Visible symptom | Since |
|---|---|---|---|---|
| A | Pages freeze every 5 minutes | cron, log rotation, file ownership and permissions | every page hangs ~15 s at :00, :05, :10...; the Trending job's log says "in 14.2 s" | CHG-0507, two weeks ago, getting worse every day |
| B | New visitors can't save a cart | filesystems and inodes, systemd timers | HTTP 500 for new visitors only; `df -h` 29%, `df -i` 100% | CHG-0496, three weeks ago; failing since the weekend |
| C | The app's log is empty | log rotation, open files, signals | `app.log` is 0 bytes; the app writes to `app.log.1` | CHG-0519, last night |
| - | "Bot attack" | internet background noise | `/wp-login.php`, `/.env` requests in the access log | none |

None of these shows up when you look at the server once. A freezes for 15
seconds out of every 300. B only hits visitors without a cart. C is only
visible if you go looking for the log. That's why "it's fine when I look at it"
is the most common sentence in an incident like this.

---

## Walkthrough: one efficient path

You might take a different route, and that's fine. Sample output is shortened.
PIDs, times and sizes will differ on your machine.

**1. Measure over time.** One `curl` looks fine. A loop doesn't:

```console
$ while true; do printf '%s ' "$(date +%T)"; curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://localhost/; sleep 1; done
10:04:59 200 0.001317s
10:05:00 200 0.001432s
10:05:01 200 13.645068s          <- one request took 13.6 s...
10:05:16 200 0.001471s           <- ...and then everything is fast again
```

Leave it running for 10 minutes and the slow pages are always at :00, :05,
:10... seconds after a 5-minute mark. That's a schedule.

**2. Reproduce the cart problem** as a new visitor (no cookie):

```console
$ curl -s -i -d book=1 http://localhost/cart/add | sed -n '1p;/<h2>/p'
HTTP/1.1 500 Internal Server Error
<h2>Sorry, we couldn't save your cart</h2>
```

So it fails every time for a new visitor. Staff in the office already have a
cart cookie, which is why it "works for us".

**3. Read the app's log**, and find it empty. Issue C is in the way of
investigating everything else, so it's worth fixing first (quick, and safe):
the app is writing to `app.log.1`. Reload it, and the errors appear where
you'd expect.

**4. Follow the cart error:** `[Errno 28] No space left on device`, but
`df -h` shows 70% free, and `df -i` shows 100% of inodes used. The expired-cart
cleanup timer has no next run, because its schedule is in cron syntax. Fix the
timer, run the cleanup once: new carts work.

**5. Follow the schedule:** the freezes match the Trending job in
`/etc/cron.d`. Its log shows each run taking 14 seconds, growing every day for
two weeks. It reads the whole access log, which is 210 MB because logrotate has
ignored nginx's config file since CHG-0507. Fix the file's owner and mode, run
logrotate: the next run takes 0.0 s and the freezes are gone.

| Fixed so far | What you measure |
|---|---|
| nothing | a ~14 s freeze every 5 minutes; new visitors get HTTP 500; `app.log` empty |
| C (log reopened) | errors now visible in `app.log`; nothing else changes |
| C + B (timer, cleanup) | new visitors' carts work; inodes 28% used |
| C + B + A (rotation) | no freezes: the Trending job runs in 0.0 s |

Any order works, as long as you measure after every change.

**6. Verify:** `sudo lab-check`, then `sudo reboot`, wait a minute, and check
again.

---

## Issue A: pages freeze every 5 minutes

**Root cause.** The "Trending now" shelf (CHG-0507) is rebuilt every 5 minutes
by a cron job, `storefront-trending`. It reads nginx's access log, scores the
books, and writes the top 5 to the shop's SQLite database, all inside **one
exclusive transaction**, so two runs can't overlap and the shop never shows a
half-built shelf. While that lock is held, every page that reads the database
(all of them except `/healthz`) has to wait.

That's harmless if the log is one day long: a run takes well under a second.
But the access log hasn't been rotated for two weeks. On the day of CHG-0507,
Sam edited a copy of `/etc/logrotate.d/nginx` in their home directory
(changing `rotate 14` to `rotate 30`) and moved it into place with
`sudo mv`. `mv` keeps a file's owner and mode, so the config file ended up
owned by `sam`, mode `664`. logrotate runs as root, and it refuses any config
file that someone other than root could modify, so since that day it has
skipped nginx's logs entirely. Every day the log grew, and every day each
Trending run took longer: 0.7 s on day one, 14 s today. The uptime monitor
only checks `/healthz`, which doesn't touch the database, so it stayed green.

**Diagnose.**

```console
$ grep -v '^#' /etc/cron.d/storefront-trending | grep .
*/5 * * * *  storefront  /usr/local/bin/storefront-trending >>/var/log/storefront/trending.log 2>&1

$ journalctl -u cron | grep CMD | tail -n 2
Nov 11 10:05:01 web-03 CRON[2331]: (root) CMD (command -v debian-sa1 > /dev/null && debian-sa1 1 1)
Nov 11 10:05:01 web-03 CRON[2332]: (storefront) CMD ( /usr/local/bin/storefront-trending >>/var/log/...)

$ sudo tail -n 1 /var/log/storefront/trending.log
2026-11-11T10:05:01Z trending: rebuilt from 1,138,135 log lines (569,092 book views) in 14.1 s
$ sudo zcat /var/log/storefront/trending.log.2.gz | head -n 1
2026-10-27T14:05:00Z trending: rebuilt from 43,317 log lines (20,383 book views) in 0.7 s

$ sudo lsof /var/lib/storefront/db/shop.db            # during a run
COMMAND  PID       USER   FD   TYPE DEVICE SIZE/OFF  NODE NAME
python3 2393 storefront    3uw  REG  0,523    24576 87269 /var/lib/storefront/db/shop.db
                                  ^ w: a write lock

$ ls -lh /var/log/nginx/
-rw-r----- 1 www-data adm 210M Nov 11 10:05 access.log      <- two weeks in one file
-rw-r----- 1 www-data adm  15M Oct 27 00:01 access.log.1    <- the last rotation
-rw-r----- 1 www-data adm 1.1M Oct 18 00:01 access.log.10.gz

$ journalctl -u logrotate | grep -E 'warning|error'
Nov 11 10:01:36 web-03 logrotate[2150]: warning: Potentially dangerous mode on nginx: 0664
Nov 11 10:01:36 web-03 logrotate[2150]: error: Ignoring nginx because it is writable by group or others.

$ ls -l /etc/logrotate.d/
-rw-r--r-- 1 root root 112 Feb  5  2024 dpkg
-rw-rw-r-- 1 sam  sam  396 Oct 27 14:00 nginx          <- the odd one out
-rw-r--r-- 1 root root 336 Nov 10 15:00 storefront
```

`sudo cat /home/sam/.bash_history` shows how it happened. Note that
`logrotate.service` still reports `status=0/SUCCESS`: logrotate logs the error
and carries on with the other files, so nothing ever turned red.

**Fix.**

```bash
sudo chmod 644 /etc/logrotate.d/nginx
sudo logrotate -d /etc/logrotate.conf 2>&1 | grep '^error'
#   error: Ignoring nginx because the file owner is wrong (should be root or user with uid 0).
sudo chown root:root /etc/logrotate.d/nginx
sudo logrotate -d /etc/logrotate.conf 2>&1 | grep '^error'     # nothing: clean
sudo systemctl start logrotate.service                         # run tonight's job now
ls -lh /var/log/nginx/                                         # access.log: 0 bytes, access.log.1: 210M
```

logrotate rotates nginx's logs because they're overdue, then its `postrotate`
script tells nginx to reopen them. The next Trending run reads an empty log:

```console
$ sudo -u storefront /usr/local/bin/storefront-trending
2026-11-11T10:05:59Z trending: rebuilt from 0 log lines (0 book views) in 0.0 s
```

The shelf starts fresh after a rotation, as it does every midnight. Keep Sam's
`rotate 30` if Marketing wants 30 days of logs: that part of the change was fine.

**Don't:** empty the log by hand (`sudo truncate -s 0 access.log`). The freezes
stop, but rotation is still broken, and in two weeks they're back (check 5
fails). Don't stop or remove the Trending job: Marketing wants it (check 7).
Don't "fix" the permissions with `chmod 666` or `777`: logrotate refuses
world-writable files too, and anyone on the box could then add a `postrotate`
script that runs as root.

**Concepts.**
- **Correlate with the clock.** Symptoms at regular intervals point to a
  schedule. `date` in your measuring loop, `journalctl -u cron`, and
  `systemctl list-timers` connect them. Match *every* time you wrote down:
  sysstat's collector (`/etc/cron.d/sysstat`) also runs at :05, :15, :25...,
  but not at :00 or :10, so it can't explain the freezes.
- **Where scheduled jobs live:** `/etc/crontab`, `/etc/cron.d/`,
  `/etc/cron.{hourly,daily,weekly}/`, per-user crontabs
  (`/var/spool/cron/crontabs/`, read with `crontab -l -u <user>`), and systemd
  timers (`systemctl list-timers --all`). Check all of them.
- **cron doesn't care if the last run is still going.** If a job takes longer
  than its interval, cron starts another copy. This job uses a database lock
  to avoid that. Other jobs use `flock -n`. A systemd timer never starts its
  service again while it's still running.
- **Log rotation.** `logrotate` (started daily by `logrotate.timer`) renames
  `access.log` to `access.log.1`, `.1` to `.2.gz`, and so on, deletes the
  oldest, and runs `postrotate` scripts so programs switch to the new file.
  `logrotate -d` is a dry run that shows what it would do and every error.
- **logrotate's safety rules.** Config files run commands as root, so logrotate
  ignores any config file not owned by root, or writable by group or others.
- **`mv` keeps owner and mode; creating a file doesn't.** Moving a file you
  edited as yourself into `/etc` brings your ownership with it. Use
  `sudo install -o root -g root -m 0644 myfile /etc/logrotate.d/nginx`, or
  edit in place with `sudoedit`.
- **Readers wait for writers.** An exclusive SQLite transaction blocks readers
  until it commits. The longer a job holds a lock, the longer everyone waits.

**Prevention.** Alert when a log file grows past a sane size, and when
logrotate prints `error:` (it doesn't fail its unit). Watch the duration of
recurring jobs, not just whether they succeed. Monitor a page that touches the
database, not only `/healthz`. In the job itself, do the slow parsing *before*
taking the lock, and hold the lock only to swap in the results.

---

## Issue B: new visitors can't save a cart

**Root cause.** Carts are small files, one per visitor, on a dedicated 512 MB
volume, `/var/lib/storefront/sessions`. The app's docstring says carts expire
after 7 days, and an hourly systemd timer, `storefront-session-gc.timer`,
deletes the expired ones. Three weeks ago, CHG-0496 changed the timer to "every
30 minutes", written as a **cron** expression: `OnCalendar=*/30 * * * *`.
systemd can't parse it, ignores the setting, and refuses a timer with no
schedule. It hasn't fired since. Carts piled up until, over the weekend, the
filesystem ran out of **inodes**: 32,768 files on a volume that's still 70%
empty. Creating a new file fails with `ENOSPC` ("No space left on device"), so
new visitors can't get a cart. A returning visitor's cart file already exists,
and rewriting a file doesn't need a new inode, so it works for anyone with a
cart cookie, like the office staff.

**Diagnose.**

```console
$ sudo grep ERROR /var/log/storefront/app.log.1 | tail -n 1
2026-11-11T09:54:00Z ERROR cart: could not save the cart for a new visitor: [Errno 28] No space left on
device: '/var/lib/storefront/sessions/sess_f8709e5ad63d288ef3ebad324dd68a6e'

$ df -h /var/lib/storefront/sessions
Filesystem      Size  Used Avail Use% Mounted on
/dev/loop3      488M  131M  322M  29% /var/lib/storefront/sessions
$ df -i /var/lib/storefront/sessions
Filesystem     Inodes IUsed IFree IUse% Mounted on
/dev/loop3      32768 32768     0  100% /var/lib/storefront/sessions

$ sudo find /var/lib/storefront/sessions -name 'sess_*' -mtime +7 | wc -l
23756                                                   <- three in four carts have expired

$ systemctl list-timers --all | grep -E 'NEXT|session'
NEXT  LEFT  LAST  PASSED  UNIT                         ACTIVATES
-        -  -          -  storefront-session-gc.timer  storefront-session-gc.service

$ systemctl status storefront-session-gc.timer
● storefront-session-gc.timer - Remove expired shopping carts every 30 minutes
     Loaded: bad-setting (Reason: Unit storefront-session-gc.timer has a bad unit file setting.)
     Active: active (elapsed) since Wed 2026-11-11 09:53:13 UTC; 57s ago
    Trigger: n/a
... /etc/systemd/system/storefront-session-gc.timer:6: Failed to parse calendar specification, ignoring: */30 * * * *

$ journalctl | grep 'lacks value'
... storefront-session-gc.timer: Timer unit lacks value setting. Refusing.

$ systemd-analyze calendar '*/30 * * * *'
Failed to parse calendar specification '*/30 * * * *': Invalid argument
```

`Active: active` looks fine at a glance. The `Loaded: bad-setting` and
`Trigger: n/a` lines tell the truth. (After a reboot it says
`inactive (dead)` instead.)

**Fix.**

```bash
systemd-analyze calendar '*:00/30'             # every 30 minutes, systemd style: Next elapse ...
sudo systemctl edit --full storefront-session-gc.timer    # OnCalendar=*:00/30
sudo systemctl daemon-reload
sudo systemctl restart storefront-session-gc.timer
systemctl list-timers storefront-session-gc.timer        # a NEXT time again
sudo systemctl start storefront-session-gc.service       # don't wait: clean up now
journalctl -u storefront-session-gc -n 3                 # removed 23756 expired carts, kept 9001
df -i /var/lib/storefront/sessions                       # IUse% 28%
```

`OnCalendar=hourly` (the original schedule) is fine too. So is a drop-in from
`sudo systemctl edit storefront-session-gc.timer` with an empty
`OnCalendar=` line (which clears the list) followed by a valid one.

**Don't:** `rm` every cart. About 9,000 belong to customers who shopped this
week, and check 7 notices. Don't recreate the filesystem with more inodes to
"make room": that deletes every cart too, and the next three weeks without
cleanup would fill it again. Don't delete only some old carts by hand and
leave the timer broken: check 3 wants the expired ones gone, and check 6 wants
the cleanup scheduled.

**Concepts.**
- **Inodes.** On ext4, every file and directory needs one inode, which holds
  its owner, permissions, timestamps and where its data is. The number of
  inodes is fixed when the filesystem is created (by default one per 16 KB of
  space). Millions of tiny files can use them all up while most of the space
  is still free. `df -i` shows inode use, and `df -h` doesn't.
- **"No space left on device"** (`ENOSPC`) means out of space **or** out of
  inodes. Check both.
- **Systemd timer syntax isn't cron syntax.** `OnCalendar=` takes calendar
  expressions like `hourly`, `*:00/30`, `Mon..Fri 09:00`, or
  `*-*-* 01:00:00`. Always test one with `systemd-analyze calendar`, and after
  a change, confirm the timer has a NEXT time in `systemctl list-timers`.
- **`systemctl daemon-reload` doesn't print unit file errors.** They go to the
  journal. `systemctl status <unit>` shows them right under the status.
- **A silent failure.** The timer never ran, so it never *failed*, so nothing
  alerted. Monitoring "did the job fail?" misses "did the job run at all?".

**Prevention.** Monitor inode use alongside disk space. Alert when a
housekeeping timer has no next run, or hasn't run successfully for longer than
its interval. Review schedule changes with `systemd-analyze calendar` (or
`systemd-analyze verify <unit>`) before reloading.

---

## Issue C: the storefront's log is empty

**Root cause.** The app opens `/var/log/storefront/app.log` when it starts and
keeps it open. Yesterday's CHG-0519 ("logging tidy-up") replaced the
storefront's logrotate file with a copy of nginx's and changed the path, but
not the `postrotate` script, which still runs `invoke-rc.d nginx rotate`. Last
night logrotate renamed `app.log` to `app.log.1`, created a new empty
`app.log`, and told **nginx** to reopen its logs. Nobody told the app, so it
kept writing into the renamed file. Renaming a file doesn't change the file
the app has open (the inode is the same), so every new line lands in
`app.log.1`. Tonight, `delaycompress` would compress `app.log.1` and delete it,
and from then on the app would be writing into a deleted file that nobody can
read.

**Diagnose.**

```console
$ ls -l /var/log/storefront/
-rw-r----- 1 storefront adm             0 Nov 11 10:01 app.log       <- empty since the rotation
-rw-r--r-- 1 storefront storefront   2394 Nov 11 10:05 app.log.1     <- still growing
-rw-r----- 1 storefront adm           190 Nov 11 10:05 trending.log  <- fine

$ sudo lsof -p $(systemctl show -p MainPID --value storefront) | grep log
python3 1872 storefront    3w   REG  0,523     2394  91354 /var/log/storefront/app.log.1

$ sed -n '/postrotate/,/endscript/p' /etc/logrotate.d/storefront
	postrotate
		invoke-rc.d nginx rotate >/dev/null 2>&1      <- nginx, not the storefront
	endscript

$ systemctl cat storefront | grep ExecReload
ExecReload=/bin/kill -HUP $MAINPID                    <- how this app wants to be told
```

**Fix.** Make the rotation tell the right program, then tell it once by hand:

```text
# /etc/logrotate.d/storefront
	postrotate
		systemctl reload storefront.service >/dev/null 2>&1 || true
	endscript
```

```bash
sudo systemctl reload storefront          # reopens app.log now
tail -n 1 /var/log/storefront/app.log     # ... INFO reopened /var/log/storefront/app.log (SIGHUP)
```

Alternatively, replace the `create …` line and the `postrotate` block with
`copytruncate`: logrotate then copies the log and empties the original in
place, so the app never needs to know. It's simpler, but any lines written
between the copy and the truncate are lost.

**Why is `trending.log` fine?** Its writer is cron's `>>` redirection, which
opens the file fresh on every run. Only programs that keep a file open for a
long time need to be told about a rotation.

**Don't:** stop at restarting the app. It fixes today, but tonight's rotation
breaks it again (check 6). And don't treat a reboot as proof: the app opens
the file fresh when it starts, so a reboot makes the problem disappear until
the next rotation.

**Concepts.**
- **An open file is an inode, not a name.** `mv` and rename keep the inode, so
  a program keeps writing to the renamed file. `rm` only removes the name: a
  program can keep writing to a deleted file, and the space is only freed when
  it closes it (the [storefront-down](../../beginner/storefront-down/) lab).
- **Finding a process's open files:** `lsof -p <PID>`, `ls -l /proc/<PID>/fd`.
- **Two ways to rotate a log a program keeps open:** rename + `create` + a
  signal so it reopens (nginx uses `USR1`, many daemons `HUP`), or
  `copytruncate`.
- **`systemctl reload`** runs the unit's `ExecReload=`. What reload *means* is
  up to each program.

**Prevention.** When you copy a config file, review every line, not just the
one you came to change. Test rotation before closing the change:
`sudo logrotate -f /etc/logrotate.d/storefront`, then check the app still logs
to `app.log`. Alert when an important log stops growing.

---

## The red herring: "a bot attack"

```console
$ sudo grep -c wp-login /var/log/nginx/access.log
4666
$ sudo grep wp-login /var/log/nginx/access.log | tail -n 1
198.51.100.201 - [11/Nov/2026:09:58:20 +0000] "GET /wp-login.php HTTP/1.1" 404 1544 rt=0.001 urt=0.000 "python-requests/2.32.3"
```

Every server on the internet is scanned for WordPress logins, `.env` files,
`.git` folders and old admin pages, all day. This shop doesn't run WordPress,
so every probe gets a 404 in about a millisecond, without touching the
database. The scans are spread evenly through the day and don't line up with
the freezes. Blocking them (a rate limit, fail2ban, a WAF) is reasonable
hardening for another day, but it would fix nothing in this ticket. The lesson
is to **check a theory against the data** (timing, status codes, durations)
before you act on it.

---

## Verifying the fix

```bash
# the measuring loop: no freeze at the next 5-minute mark
while true; do printf '%s ' "$(date +%T)"; curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://localhost/; sleep 1; done
sudo lab-check                                       # expect 7/7 PASS
sudo logrotate -f /etc/logrotate.conf                # tonight's housekeeping, now
curl -s -o /dev/null -d book=1 http://localhost/cart/add; tail -n 1 /var/log/storefront/app.log
sudo reboot                                          # then vagrant ssh again and: sudo lab-check
```

---

## Example post-incident note

> **INC-2453: Storefront freezes and failing carts on web-03 (SEV-3)**
>
> **Impact:** For about two weeks, every page froze for a few seconds every 5
> minutes, growing to ~15 seconds by Monday. From Saturday until <time fixed>,
> new visitors could not create a cart (HTTP 500). The uptime monitor stayed
> green throughout, because `/healthz` was not affected.
>
> **Root causes:**
> 1. Since CHG-0507, `/etc/logrotate.d/nginx` was owned by a user account with
>    mode 664 (it was edited in a home directory and moved into place).
>    logrotate ignores such files, so nginx's access log stopped rotating. The
>    Trending job reads the whole log every 5 minutes while holding an exclusive
>    lock on the shop database, so each run blocked all pages for longer every
>    day.
> 2. CHG-0496 rewrote the expired-cart timer's schedule in cron syntax, which
>    systemd rejects. The cleanup never ran again, and cart files used up all
>    inodes on the cart volume while 70% of its space was still free.
> 3. CHG-0519 copied nginx's logrotate config for the storefront without
>    changing its `postrotate` step, so after last night's rotation the app
>    kept writing to `app.log.1` and `app.log` stayed empty.
>
> **Resolution:** Restored root ownership and mode 644 on the nginx logrotate
> file and ran logrotate. Fixed the timer schedule (`*:00/30`) and ran the
> cleanup once (23,756 expired carts removed, 9,001 active carts kept). Made
> the storefront's rotation reload the storefront, and reloaded it once.
> Verified with a forced rotation and a reboot.
>
> **What went well:** The Trending job logs its run time, which showed the
> trend over two weeks. Returning customers were never affected.
>
> **Action items:**
> - Alert on: logrotate `error:` lines, log files over a size limit, inode use,
>   timers with no next run, and recurring jobs that take longer than usual.
> - Monitor a database-backed page, not only `/healthz`.
> - Move config files into place with `install -o root -g root -m 0644`, and
>   validate schedules with `systemd-analyze calendar` before reloading.
> - Trending job: parse outside the transaction; hold the lock only to swap in
>   the new shelf.
> - Change review: test the rotation, and check every line of copied config.

Write it **blameless**: describe how the system and process let it happen, not
who typed what.

---

## Cheat sheet: commands from this lab

| Task | Command |
|---|---|
| Measure over time | `while true; do printf '%s ' "$(date +%T)"; curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' URL; sleep 1; done` |
| Every scheduled job | `systemctl list-timers --all` · `cat /etc/crontab` · `ls /etc/cron.d/` · `sudo crontab -l -u <user>` |
| When did cron run what? | `journalctl -u cron` |
| A timer's state and errors | `systemctl status <name>.timer` (read `Loaded:` and `Trigger:`) · `systemctl cat <name>.timer` |
| Test a schedule | `systemd-analyze calendar '*:00/30'` |
| Run a timer's job now | `sudo systemctl start <name>.service`, then `journalctl -u <name>.service` |
| Space vs inodes | `df -h` · `df -i` · `sudo find DIR -type f \| wc -l` |
| Files by age | `find DIR -mtime +7` (not modified for more than 7 days) |
| Read rotated logs | `zcat file.gz` · `zgrep pattern file.gz` |
| logrotate dry run | `sudo logrotate -d /etc/logrotate.conf 2>&1 \| grep -E '^(error\|warning)'` |
| Rotate now | `sudo systemctl start logrotate.service` (only what's due) · `sudo logrotate -f <config>` (forced) |
| Who has a file open? | `sudo lsof <file>` · `sudo lsof -p <PID>` · `sudo ls -l /proc/<PID>/fd` |
| Owner and mode | `ls -l` · `stat FILE` · `sudo chown root:root FILE` · `sudo chmod 644 FILE` |
| Put a config file in place safely | `sudo install -o root -g root -m 0644 SRC DEST` · `sudoedit FILE` |

## Extra credit

1. Sketch a version of `storefront-trending` that parses the log *before*
   `BEGIN EXCLUSIVE`, and only takes the lock to replace the shelf. How long
   would pages wait then, even with a two-week log?
2. Make a cron job overlap with itself: `* * * * * sleep 90` in a test
   crontab, then `pgrep -a sleep` after three minutes. Then wrap it in
   `flock -n /run/lock/test.lock`. What does a systemd timer do instead?
3. Run `sudo tune2fs -l /var/lib/lab/storefront-sessions.img | grep -i inode`.
   How many bytes of space per inode did `mkfs.ext4` choose? How would you
   create a filesystem meant for millions of tiny files (`mkfs.ext4 -i` or
   `-N`)? Why can't you add inodes to an existing ext4 filesystem?
4. `logrotate.timer` has `Persistent=true`. What happens if the server was
   powered off at midnight? (`systemctl cat logrotate.timer`, and
   `man systemd.timer`.)
5. As yourself, create a file in your home directory, then `sudo mv` one copy
   and `sudo cp` another into `/tmp`. Compare their owners and modes with
   `ls -l`. Why are they different?
