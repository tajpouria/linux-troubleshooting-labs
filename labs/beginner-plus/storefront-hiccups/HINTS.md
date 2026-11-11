# Hints: It's slow, then it's not

Use these only when you're stuck. Each issue has numbered hints that go from
vague to specific. Open one, then go back and try again before opening the
next. The last hint for each issue is close to the answer.

The section titles describe **symptoms you'll see**, not causes, so it's safe to
scroll. Hints stay collapsed until you click them. (They render as collapsible
blocks on GitHub and in most Markdown previewers. In a plain text editor,
everything is visible.)

## Before you start: a method (no spoilers)

1. **Measure over time, not once.** A problem that comes and goes hides from a
   single `curl`. In a second terminal (`vagrant ssh` again), leave this
   running and watch it for 10 minutes:

   ```bash
   while true; do printf '%s ' "$(date +%T)"; curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://localhost/; sleep 1; done
   ```

2. **Write down *when*.** Exact times, to the second. A pattern in the times
   is a clue in itself.
3. **Reproduce each symptom yourself.** The ticket says carts fail for
   customers but work for staff. What's the difference between them, from the
   server's point of view?
4. **Find every log.** This app has logs in the journal, in `/var/log/nginx`
   and in `/var/log/storefront`. Read them before you change anything.
5. **Change one thing at a time**, then measure again and run `sudo lab-check`.

Commands worth knowing for this lab: `date`, `curl`, `systemctl list-timers`,
`systemctl status`, `systemctl cat`, `journalctl`, `ls -l`, `df`, `find`,
`lsof`, `zcat`, `logrotate -d`, `systemd-analyze calendar`.

**Reading the access log.** Each line is
`client - [time] "METHOD /path HTTP/1.1" status bytes rt=… urt=… "user agent"`.
`rt=` is how long the whole request took, and `urt=` how long nginx waited for
the app. With `awk`, the path is field `$6` and the status is `$8`.

### Which hints do I need?

| What you're seeing | lab-check item | Go to |
|---|---|---|
| Now and then a page takes several seconds, then everything is fast again | 1 | [Issue A](#issue-a-pages-freeze-now-and-then) |
| "Sorry, we couldn't save your cart" | 2, 3 | [Issue B](#issue-b-some-visitors-cant-save-a-cart) |
| `df -h` says there's plenty of space, but something says "No space left on device" | 2, 3 | [Issue B](#issue-b-some-visitors-cant-save-a-cart), hint B3 |
| `/var/log/storefront/app.log` is empty | 4 | [Issue C](#issue-c-the-storefronts-log-is-empty) |
| "Web server logs are rotated" fails | 5 | [Issue A](#issue-a-pages-freeze-now-and-then), hints A4 to A6 |
| The access log is full of `/wp-login.php` and `/.env` | none | [Is it a bot attack?](#is-it-a-bot-attack) |
| You fixed the cart errors, but check 3 still fails | 3 | [Issue B](#issue-b-some-visitors-cant-save-a-cart), hint B6 |
| "Fixes survive a reboot" fails | 6 | [Guard checks](#guard-checks-6-and-7) |
| "Nothing important was removed or weakened" fails | 7 | [Guard checks](#guard-checks-6-and-7) |

---

## Issue A: pages freeze now and then

<details><summary>Hint A1</summary>

Run the loop from the method above for 10 minutes and note the time of every
slow page. Look only at the minutes and seconds. What do the times have in
common?

</details>

<details><summary>Hint A2</summary>

Something that happens at the same times every hour is almost always a
scheduled job. List them all: `systemctl list-timers --all` for systemd timers,
and for cron, `cat /etc/crontab`, `ls /etc/cron.d/` and `sudo ls
/var/spool/cron/crontabs/` (one file per user). Which one runs at the times you
wrote down? `journalctl -u cron` shows a line every time cron starts a job.
More than one job may match *some* of your times. Which one matches all of
them?

</details>

<details><summary>Hint A3</summary>

Catch the job in the act: during a freeze, run `ps -ef | grep [t]rending` or
watch `top`. Then find the job's own log: the cron line shows where its output
goes. How long does each run take? Has it always taken that long? Older copies
of a log are often compressed: `zcat` and `zgrep` read `.gz` files directly.

</details>

<details><summary>Hint A4</summary>

Why would a slow background job make *pages* slow? Read what the job does: the
comment at the top of `/usr/local/bin/storefront-trending`. While a run is in
progress, `sudo lsof /var/lib/storefront/db/shop.db` shows who has the database
open (a `w` after the file descriptor number means a write lock). Then look at
how much the job has to read: `ls -lh /var/log/nginx/`. Look at the dates as
well as the sizes. When were these logs last rotated?

</details>

<details><summary>Hint A5</summary>

On Ubuntu, logs are rotated by `logrotate`, which a systemd timer starts every
night (`systemctl list-timers logrotate.timer`). Did last night's run do its
job? `systemctl status logrotate` shows the last lines it logged, and
`journalctl -u logrotate` shows more. You can also ask logrotate what it
*would* do, without changing anything:
`sudo logrotate -d /etc/logrotate.conf 2>&1 | grep -E '^(error|warning)'`.

</details>

<details><summary>Hint A6 (nearly the answer)</summary>

logrotate runs as root, so it refuses to use a config file that anyone other
than root could change: `ls -l /etc/logrotate.d/`. The `nginx` file was edited
in someone's home directory and moved into place, which kept its owner and its
mode. Fix both: `sudo chown root:root /etc/logrotate.d/nginx` and
`sudo chmod 644 /etc/logrotate.d/nginx`. Repeat the dry run until it reports
no errors. Then don't wait for tonight: run the nightly job now with
`sudo systemctl start logrotate.service` and check `ls -lh /var/log/nginx/`.
Measure again at the next 5-minute mark. Emptying the log by hand would hide
the problem for a few days, but rotation would still be broken, and check 5
knows.

</details>

---

## Issue B: some visitors can't save a cart

<details><summary>Hint B1</summary>

Reproduce it. A new visitor has no cookie:
`curl -s -i -d book=1 http://localhost/cart/add | head -5`. Staff in the office
have been shopping here for days. What does their browser send that `curl`
doesn't? Does the problem depend on time, or on *who* you are?

</details>

<details><summary>Hint B2</summary>

What does the app say when the cart can't be saved? It writes errors to its
own log (if `app.log` is empty, see [Issue C](#issue-c-the-storefronts-log-is-empty)
first: the errors are still being written *somewhere*). The error names the
exact problem and the exact path. Read the top of `/opt/storefront/app.py`
too: where are carts stored, and for how long?

</details>

<details><summary>Hint B3</summary>

"No space left on device", but `df -h /var/lib/storefront/sessions` says
there's plenty of room? A filesystem can run out of something other than
bytes. Every file, however small, needs an *inode*, and a filesystem has a
fixed number of them: `df -i`.

</details>

<details><summary>Hint B4</summary>

What's using all the inodes? `sudo ls /var/lib/storefront/sessions | wc -l`
counts the files, and `sudo find /var/lib/storefront/sessions -name 'sess_*' -mtime +7 | wc -l`
counts the ones nobody has touched for more than 7 days. Carts are meant to
expire after 7 days. What's supposed to remove them, and when did it last run?
(`systemctl list-timers --all` shows the last and next run of every timer.)

</details>

<details><summary>Hint B5</summary>

A timer with no next run will never fire. Ask systemd what's wrong with it:
`systemctl status storefront-session-gc.timer` (read the `Loaded:` line, and
the log lines underneath), and `systemctl cat storefront-session-gc.timer`.
You can test any schedule expression on its own:
`systemd-analyze calendar '<expression>'`.

</details>

<details><summary>Hint B6 (nearly the answer)</summary>

`OnCalendar=` was written in cron syntax, which systemd can't parse, so the
timer has never fired since that change. In systemd's syntax, "every 30
minutes" is `OnCalendar=*:00/30` (check it with `systemd-analyze calendar
'*:00/30'`). Fix the line (`sudo systemctl edit --full
storefront-session-gc.timer`), then `sudo systemctl daemon-reload` and
`sudo systemctl restart storefront-session-gc.timer`. `systemctl list-timers`
should now show a next run. Then don't wait for it: run the cleanup now with
`sudo systemctl start storefront-session-gc.service`, read its result in
`journalctl -u storefront-session-gc`, and check `df -i` again. Don't delete
all the carts: customers who are shopping right now would lose theirs.

</details>

---

## Issue C: the storefront's log is empty

<details><summary>Hint C1</summary>

The app is clearly running and doing things, so it's writing its log
*somewhere*. `ls -l /var/log/storefront/`: which file changed most recently?

</details>

<details><summary>Hint C2</summary>

Ask the process which files it has open:
`sudo lsof -p $(systemctl show -p MainPID --value storefront)`, or
`sudo ls -l /proc/<PID>/fd`. A program that keeps a file open keeps writing
to *that file*, even after someone renames it.

</details>

<details><summary>Hint C3</summary>

Who renamed `app.log` last night? Log rotation does exactly that, then creates
a new, empty file. After that, the program has to be told to switch to the new
file. Read `/etc/logrotate.d/storefront`: the commands between `postrotate`
and `endscript` run after rotating. Then read `systemctl cat storefront`: how
does *this* app expect to be told?

</details>

<details><summary>Hint C4 (nearly the answer)</summary>

The storefront's logrotate file was copied from nginx's, and its `postrotate`
still tells **nginx** to reopen its logs. Make it tell the storefront instead:
`systemctl reload storefront.service >/dev/null 2>&1 || true` (the unit's
`ExecReload` sends the app a SIGHUP, which makes it reopen its log). Or
replace `create …` and the `postrotate` block with `copytruncate`. Then fix
the running app once: `sudo systemctl reload storefront`, and check that new
lines appear in `app.log`. Bonus question: why does `trending.log` not have
this problem?

</details>

---

## Is it a bot attack?

<details><summary>Hint H1</summary>

Count before you conclude:
`sudo awk '{ print $6 }' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -15`.
Then look at what those requests got back, and how long they took:
`sudo grep wp-login /var/log/nginx/access.log | tail -n 3`.

</details>

<details><summary>Hint H2</summary>

Every server on the internet is probed for WordPress logins, `.env` files and
`.git` folders, all day, by automated scanners. Here they get a 404 in about a
millisecond, without touching the database. That's background noise, not the
cause of the freezes, and the freezes don't line up with them. Blocking them is
fine as separate hardening, but it won't fix anything in this ticket.

</details>

---

## Guard checks (6 and 7)

<details><summary>Hint G1: "Fixes survive a reboot and tonight's housekeeping" fails</summary>

Something is fixed only in the *running* system, or tonight's run would undo
it. Ask yourself: does the expired-cart timer show a next run in
`systemctl list-timers`? After tonight's rotation, will the storefront be told
to reopen its log? (Try it: `sudo logrotate -f /etc/logrotate.d/storefront`,
add a book to a cart, and look at `app.log`.) After editing unit files, run
`sudo systemctl daemon-reload`. Then `sudo reboot` and run `lab-check` again.
Note that a reboot makes the empty `app.log` look fixed, because the app opens
the file fresh when it starts. That's not a fix.

</details>

<details><summary>Hint G2: "Nothing important was removed or weakened" fails</summary>

Did you delete carts that were still in use (anything changed in the last 7
days)? Did you remove, disable or break the Trending job
(`tail /var/log/storefront/trending.log`)? Did you make a log file, a log
directory, a logrotate file or the cart directory writable by everyone? Undo it
and use the narrower fix. If you just booted or resumed the VM after a long
pause, give cron 5 minutes to run the Trending job, then check again.

</details>
