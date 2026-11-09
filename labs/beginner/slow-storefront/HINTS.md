# Hints: The storefront is crawling

Use these only when you're stuck. Each issue has numbered hints that go from
vague to specific. Open one, then go back and try again before opening the
next. The last hint for each issue is close to the answer.

The section titles describe **symptoms you'll see**, not causes, so it's safe to
scroll. Hints stay collapsed until you click them. (They render as collapsible
blocks on GitHub and in most Markdown previewers. In a plain text editor,
everything is visible.)

## Before you start: a method (no spoilers)

1. **Measure the symptom yourself.** Time one page load, inside the VM:
   `curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://localhost/`.
   Write the number down. You'll measure again after every change.
2. **Is the server busy?** Compare the load average (`uptime`) with the number
   of CPUs (`nproc`). Then look at what's using the CPU: `top`.
3. **Busy with what, and on whose behalf?** For each process near the top of
   the list, answer three questions. What is it? Who or what started it? Should
   it be using this much CPU *right now*?
4. **Change one thing at a time**, then measure again.
5. Run `sudo lab-check` often. Each check tells you which outcome is still
   missing.

Commands worth knowing for this lab: `uptime`, `nproc`, `top`, `ps`,
`pstree`, `kill`, `renice`, `free`, `vmstat`, `ss`, `systemctl status`,
`systemctl cat`, `journalctl`, `crontab`.

**Reading `top`.** Press `1` to show each CPU separately, `c` to show full
command lines, and `q` to quit. The `NI` column is a process's *nice* value
(its priority). `%Cpu(s)` splits CPU time into `us` (programs), `sy` (the
kernel), `ni` (programs with a positive nice value), `id` (idle) and `wa`
(waiting for disk).

### Which hints do I need?

| What you're seeing | lab-check item | Go to |
|---|---|---|
| Both CPUs are at or near 100%, and the load average is above 2 | 1 | [Issue A](#issue-a-the-cpus-are-maxed-out) |
| The access log fills up faster than customers could explain | 2 | [Issue B](#issue-b-the-web-server-is-busier-than-customers-could-explain) |
| You stopped a process and it came straight back | 2 | [Issue B](#issue-b-the-web-server-is-busier-than-customers-could-explain), hint B3 |
| The CPUs have room (or are only busy in `ni`), but pages are still slow | 1 | [Issue C](#issue-c-pages-are-slow-even-though-the-cpu-has-room) |
| You fixed something real, but page times didn't change at all | 1 | Keep the fix. Something else is the bottleneck right now: watch the storefront's own CPU in `top`, then see [Issue C](#issue-c-pages-are-slow-even-though-the-cpu-has-room) |
| `free` says there's almost no free memory | none | [Memory looks almost full](#memory-looks-almost-full) |
| "Fixes survive a reboot" fails | 4 | [Guard checks](#guard-checks-3-4-and-5) |
| Check 3 or check 5 fails | 3, 5 | [Guard checks](#guard-checks-3-4-and-5) |

---

## Issue A: the CPUs are maxed out

<details><summary>Hint A1</summary>

The load average counts the processes that want a CPU, averaged over 1, 5 and
15 minutes. With 2 CPUs, a load of 2 means "fully busy". Anything above that
means processes are waiting in line. Which processes use the most CPU in `top`?
Look at the `USER` and `COMMAND` columns (press `c` for full command lines).

</details>

<details><summary>Hint A2</summary>

Find out what the busiest processes belong to: `systemctl status <PID>` works
with a PID and tells you the unit. Then reread the ticket. Is this something
you're allowed to stop? If not, the question isn't *whether* it runs. It's
*who goes first* when it and the storefront both want a CPU.

</details>

<details><summary>Hint A3</summary>

Look at the `NI` column in `top`, or run `ps -o pid,ni,cmd -u <user>`. Nice
values go from -20 (most favoured) to 19 (least). Normal processes run at 0.
What does a negative value on a batch job mean for the storefront? Where does
that value come from? `systemctl cat <unit>` shows the unit file **and** every
drop-in file that changes it.

</details>

<details><summary>Hint A4 (nearly the answer)</summary>

A drop-in sets `Nice=-10`, which overrides the unit's own `Nice=10`. Batch work
should have a *high* nice value, so it only gets CPU time the storefront isn't
using. Fix the configuration: remove the drop-in, or change it to `Nice=19`
(`sudo systemctl edit catalog-reindex` opens the drop-in for you), then
`sudo systemctl daemon-reload`. A unit's nice value applies when it starts, so
also either restart the job (it resumes from its checkpoint) or renice every
one of its running processes: `sudo renice -n 19 -p $(pgrep -u catalog)`.
Renicing only one PID isn't enough, because each worker is a separate process.

</details>

---

## Issue B: the web server is busier than customers could explain

<details><summary>Hint B1</summary>

Who's sending all these requests? Watch the access log for a few seconds:
`sudo tail -f /var/log/nginx/access.log` (Ctrl-C to stop). The first field is
the client's address, and the last one is its *user agent* (the program that
says it's making the request). Count requests per client:
`sudo awk '{ print $1 }' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head`.

</details>

<details><summary>Hint B2</summary>

`127.0.0.1` means the requests come from the server itself. Which process makes
them? `sudo ss -tnp state established '( dport = :80 )'` lists the *client*
side of each connection to port 80, with the process that owns it.

</details>

<details><summary>Hint B3</summary>

Several processes look identical, and killing one makes a new one appear? Look
at the family tree: `ps -ef --forest` or `pstree -p`. Find the process that
*starts* the others (their parent), and then the parent's parent. A
`/bin/sh -c ...` line is just the shell that launched the command; killing it
doesn't stop its children. `systemctl status <PID>` tells you which unit or
service a process belongs to.

</details>

<details><summary>Hint B4</summary>

The tree leads up to cron. cron keeps one *crontab* per user:
`sudo crontab -l -u <user>`. A line starting with `@reboot` runs every time the
server boots. Also have a look in the owner's home directory for notes about
the test.

</details>

<details><summary>Hint B5 (nearly the answer)</summary>

A capacity test (CHG-0420) was never stopped. Stop it by stopping its **parent**
Python process: `kill <parent PID>`, and its workers exit too. Then make sure it
doesn't come back at the next boot: `sudo crontab -e -u dani` and comment out
the `@reboot` line with a `#`. Don't delete Dani's account or files. Leave
them a note instead.

</details>

---

## Issue C: pages are slow even though the CPU has room

<details><summary>Hint C1</summary>

Make the site busy and watch the storefront app in `top`. In a second terminal
(`vagrant ssh` again), run:
`for i in $(seq 200); do curl -s -o /dev/null http://localhost/; done`.
How much CPU does the storefront's `python3` process get? Does it ever go above
a certain number, even when the CPUs are idle?

</details>

<details><summary>Hint C2</summary>

A process that is never allowed more than a fixed slice of CPU, even when the
CPU is free, isn't losing a competition. It's being *limited*. systemd can
limit how much CPU or memory a service may use. Read every line of
`systemctl status storefront`. Is there a line you didn't expect? Reread the
night on-call's note in the ticket, too.

</details>

<details><summary>Hint C3</summary>

`systemctl cat storefront` shows the unit and every drop-in that changes it.
To see the limit the kernel is enforcing:
`systemctl show -p CPUQuotaPerSecUSec storefront`, and the cgroup files
`/sys/fs/cgroup/system.slice/storefront.service/cpu.max` and `cpu.stat`. In
`cpu.stat`, `nr_throttled` counts how often the service was paused for using
up its share.

</details>

<details><summary>Hint C4 (nearly the answer)</summary>

The night on-call capped the storefront at `CPUQuota=5%` with
`systemctl set-property`, which writes a drop-in under
`/etc/systemd/system.control/`. 5% means 5 ms of CPU every 100 ms, and one page
needs about 25 ms of CPU. Remove the cap the same way it was set:
`sudo systemctl set-property storefront.service CPUQuota=` (an empty value
removes it). Check with `systemctl show -p CPUQuotaPerSecUSec storefront`, which
should say `infinity`.

</details>

---

## Memory looks almost full

<details><summary>Hint M1</summary>

Run `free -h` and read **every** column, not just `free`. Which column tells
you how much memory programs could still get if they asked for it?

</details>

<details><summary>Hint M2</summary>

Linux uses memory that nobody needs right now as a cache for files it has read
(`buff/cache`), and gives it back the moment a program needs it. That's what
`available` counts. Low `free` with high `available` is healthy. If memory
really ran out, you'd see swapping: run `vmstat 1` and watch the `si` and `so`
columns. Nothing to fix here. Don't clear the cache, which only makes disk
reads slower.

</details>

---

## Guard checks (3, 4 and 5)

<details><summary>Hint G1: "Fixes survive a reboot" fails</summary>

Something you fixed only in the *running* system comes back after a reboot.
`renice` and `kill` change only processes that are running now. Ask yourself
three things. Does anything start the load test again at boot? What nice value
will the reindex get the next time it starts (`systemctl show -p Nice
catalog-reindex`)? Is the storefront still capped
(`systemctl show -p CPUQuotaPerSecUSec storefront`)? After editing unit files,
run `sudo systemctl daemon-reload`. Then `sudo reboot` and run `lab-check` again.

</details>

<details><summary>Hint G2: "Nightly catalog reindex is still running" fails</summary>

The reindex was stopped or killed. Merchandising needs it, so start it again:
`sudo systemctl start catalog-reindex`. It picks up from its last checkpoint
(`journalctl -u catalog-reindex` shows how far it got). If systemd says "start
request repeated too quickly", run `sudo systemctl reset-failed catalog-reindex`
first.

</details>

<details><summary>Hint G3: "Nothing important was removed or weakened" fails</summary>

Did you disable the nightly reindex timer, delete Dani's account, or make the
storefront run as root? Each of those would be called out in a post-incident
review. Undo it and use the narrower fix.

</details>
