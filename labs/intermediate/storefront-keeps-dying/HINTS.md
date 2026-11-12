# Hints: Something keeps killing it

Use these only when you're stuck. Each issue has numbered hints that go from
vague to specific. Open one, then go back and try again before opening the
next. The last hint for each issue is close to the answer.

The section titles describe **symptoms you'll see**, not causes, so it's safe to
scroll. Hints stay collapsed until you click them. (They render as collapsible
blocks on GitHub and in most Markdown previewers. In a plain text editor,
everything is visible.)

## Before you start: a method (no spoilers)

1. **Measure over time.** In a second terminal (`vagrant ssh` again), leave
   this running for 20 minutes and write down when the errors happen:

   ```bash
   while true; do printf '%s ' "$(date +%T)"; curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://localhost/book/1; sleep 1; done
   ```

2. **For every death, answer three questions.** *How* did the process end (an
   exit code, or a signal)? *Who* ended it? *Why then?* A process that crashes
   and a process that is killed leave different traces.
3. **Look at memory per service, not just per server.** `free -h` describes the
   whole machine. This server divides its memory between groups of services,
   and a group can run out while the machine still has plenty.
4. **Watch numbers change.** One reading of a process's memory tells you its
   size. Two readings ten minutes apart tell you whether it's growing.
5. **Check the ticket's claims.** Things people *believe* about a server are
   worth verifying.
6. **Change one thing at a time**, say what you expect, then measure again and
   run `sudo lab-check`.

Commands worth knowing for this lab: `systemctl status`, `systemctl show -p`,
`systemctl --failed`, `systemctl list-timers`, `journalctl -u`, `journalctl -k`,
`systemd-cgtop`, `systemd-cgls`, `ps -o pid,rss,vsz,comm`, `pidstat -r`, `top`
(press `M` to sort by memory), `free -h`, `swapon --show`, `du`.

**Memory units.** `ps` and `/proc/<pid>/status` count in kB. The task table in
a kernel OOM report counts in **pages**; a page is 4 kB on this server
(`getconf PAGESIZE`). `systemctl` and `systemd-cgtop` use K/M/G.

### Which hints do I need?

| What you're seeing | lab-check item | Go to |
|---|---|---|
| "502 Bad Gateway" for a few seconds, over and over | 1 | [Issue A](#issue-a-the-storefront-keeps-dying) |
| `code=killed, status=9/KILL`, or `Failed with result 'oom-kill'` | 1, 2 | [Issue A](#issue-a-the-storefront-keeps-dying) for the storefront, [Issue B](#issue-b-search-cant-find-the-holiday-titles) for the reindex |
| Search can't find the holiday titles | 2 | [Issue B](#issue-b-search-cant-find-the-holiday-titles) |
| The storefront stopped dying, but the reindex is still killed | 2 | [Issue B](#issue-b-search-cant-find-the-holiday-titles), hint B3 |
| The storefront stopped dying, but check 3 fails | 3 | [Issue A](#issue-a-the-storefront-keeps-dying), hints A5 to A7 |
| `free -h` shows no swap, or `systemctl --failed` lists a `.swap` unit | 4 | [Issue C](#issue-c-the-safety-net) |
| `top` says search-server uses about 4 GB | none | [Is search-server the leak?](#is-search-server-the-leak) |
| "Fixes survive a reboot" fails | 5 | [Guard checks](#guard-checks-5-and-6) |
| "Nothing important was removed or weakened" fails | 6 | [Guard checks](#guard-checks-5-and-6) |

---

## Issue A: the storefront keeps dying

<details><summary>Hint A1</summary>

Run the loop from the method above and note the time of every 502. Then ask
systemd how the storefront ended each time: `journalctl -u storefront` (look at
the lines just before each `Started`), and `systemctl show -p NRestarts
storefront`. Did it exit with an error, or was it ended by a signal? Which
signal?

</details>

<details><summary>Hint A2</summary>

Something sends the storefront `SIGKILL`. Usually systemd adds who did it: "A
process of this unit has been killed by the OOM killer", and the result
`oom-kill`. (When systemd doesn't notice in time, it only says `signal`. The
kernel always knows.) The OOM (out-of-memory) killer is part of the kernel, so
its reports are in the kernel log:
`sudo journalctl -k | grep -E 'invoked oom-killer|Killed process'`. Line the
times up with your 502s. Then with the schedule: `systemctl list-timers`. What
runs at those times, and what does it make the storefront do?

</details>

<details><summary>Hint A3</summary>

Read one whole OOM report, slowly: `sudo journalctl -k | less`, then type
`/invoked oom-killer`. Find these lines:

- `... invoked oom-killer`: the process whose request for memory couldn't be
  met. Not necessarily the one that gets killed.
- `memory: usage ..., limit ...`: whose memory ran out?
- `oom-kill:constraint=CONSTRAINT_MEMCG,...,oom_memcg=...,task_memcg=...`:
  `oom_memcg` is the group that hit its limit. `task_memcg` is the group the
  victim lived in. Are they the same?

A *memory cgroup* (memcg) is a group of processes with a memory limit. Find out
which one ran out: `systemctl cat pinewood.slice` and
`systemctl status pinewood.slice`.

</details>

<details><summary>Hint A4</summary>

The storefront was killed because the whole shop ran out of memory, not because
of its own size. So who is using the shop's 640 MB? Try `sudo systemd-cgtop -m`
(the shop's services are under `pinewood.slice`), or
`systemctl status storefront search pinewood-agent | grep -E '●|Memory'`. The OOM
report also lists every process in the group: the `rss` column (in pages) and
`oom_score_adj`. Which process is biggest? Why didn't the kernel kill *that* one?

</details>

<details><summary>Hint A5</summary>

The kernel gives every process an OOM score and kills the highest:
`cat /proc/<PID>/oom_score`. The score grows with how much memory the process
uses (on this scale, about 666 means "hardly any"), and `oom_score_adj` (from
−1000 to 1000) shifts it. `choom -p <PID>` shows both. An adjustment of −1000
turns the score into 0: "never kill this one". Who set that, and when?
`systemctl cat pinewood-agent`, and the ticket's change calendar.

</details>

<details><summary>Hint A6</summary>

Now the real question: why is the agent so big, and is it still growing? Watch
it for a few minutes:
`pidstat -r -p $(systemctl show -p MainPID --value pinewood-agent) 30`. Read
what it says about itself: `journalctl -u pinewood-agent`,
`curl -s http://localhost:8126/status`, `/etc/pinewood-agent/agent.conf`, and the
comment at the top of `/opt/pinewood-agent/pinewood-agent`. The ticket says why
it can't deliver anything this week. What does it do with what it can't
deliver? And what happens if you just restart it?

</details>

<details><summary>Hint A7 (nearly the answer)</summary>

Since metrics-01 went offline (CHG-0601), the agent has kept every batch in
memory, and CHG-0577 removed its queue limit (`queue_limit_mb = 0`) and shielded
it from the OOM killer (`OOMScoreAdjust=-1000`). A plain restart doesn't help:
it saves its queue to a spool file on stop and loads it back at start.

1. Put the limit back in `/etc/pinewood-agent/agent.conf`. 16 MB was the
   original value.
2. Remove the shield: delete the CHG-0577 drop-in, or override it with
   `sudo systemctl edit pinewood-agent` and `OOMScoreAdjust=0` under `[Service]`.
   Then `sudo systemctl daemon-reload`.
3. `sudo systemctl restart pinewood-agent`. Then read its log: it saves the
   long queue, then loads only the newest batches that fit the new limit.

Then prove it. Check the agent's memory, and run the refresh the way the timer
does: `sudo systemctl start storefront-refresh.service`. Does the storefront
keep its PID? Taking the shield off without a limit would only change *which*
process dies. A limit without taking the shield off leaves the next leak with
the same victim.

</details>

---

## Issue B: search can't find the holiday titles

<details><summary>Hint B1</summary>

Reproduce it: `curl -s 'http://localhost/search?q=midwinter+lanterns' | grep -i -e result -e match -e built`.
Read the footer of the search page: when was the index built, and how many books
does it know? How many books does the shop have (the home page says)? What is
supposed to keep the index up to date? (`systemctl list-timers`)

</details>

<details><summary>Hint B2</summary>

`systemctl status search-reindex.service` and `journalctl -u search-reindex`:
how do the runs end? Compare with how the storefront ends. You can run the job
yourself at any time, exactly as the timer does:
`sudo systemctl start search-reindex.service`.

</details>

<details><summary>Hint B3</summary>

The reindex can be killed for two different reasons, and the kernel log tells
them apart. Find the report for a reindex kill and read `oom_memcg`:

- `oom_memcg=/pinewood.slice`: the whole shop ran out. That's
  [Issue A](#issue-a-the-storefront-keeps-dying). Fix it, then run the reindex
  again.
- `oom_memcg=/pinewood.slice/search-reindex.service`: the job hit **its own**
  limit. `systemctl cat search-reindex.service`.

Which one you see depends on what you've fixed so far. You may see both.

</details>

<details><summary>Hint B4</summary>

The job's limit has a comment saying what it was sized for. What has changed
since then? Measure what it needs now. Once Issue A is fixed, run a one-off copy
of the job with a generous limit, in the same budget, and watch its output:

```bash
sudo systemd-run --scope --uid=search --gid=search -p Slice=pinewood.slice \
  -p MemoryMax=400M -p MemorySwapMax=0 /opt/search/search-reindex
```

When it finishes, it prints its peak memory. (This one-off run also rebuilds
the index, so search works for now. The next hourly run still has the old
limit.)

</details>

<details><summary>Hint B5 (nearly the answer)</summary>

The limit (`MemoryMax=160M`) was sized for the 12,000-book catalog. Since the
holiday import (CHG-0596) the catalog has 40,000 books, and the job needs about
three times as much (~230 MB). Give it a limit that fits its new peak with room to grow,
for example `MemoryMax=320M`: `sudo systemctl edit search-reindex.service`, then
under `[Service]` add `MemoryMax=320M`. Keep a limit, and keep
`MemorySwapMax=0` (PS-12). Then `sudo systemctl start search-reindex.service`
and search again. The new limit only fits because the shop's budget has room
again, once Issue A is fixed.

</details>

---

## Issue C: the safety net

<details><summary>Hint C1</summary>

The ticket says web-04 has a 1 GB swap file. Does it? `free -h`,
`swapon --show`. Then: where is swap supposed to come from at boot?

</details>

<details><summary>Hint C2</summary>

Swap that should be on at boot is listed in `/etc/fstab`, and systemd turns
each swap line into a `.swap` unit. `systemctl --failed`, then
`systemctl status <that unit>` and `journalctl -u <that unit>`. What did
`swapon` say?

</details>

<details><summary>Hint C3</summary>

"It appears to have holes." Compare the size a file *claims* with the disk
space it *uses*: `ls -lh /swapfile` and `du -h /swapfile` (or `ls -ls`). A file
with holes (a *sparse* file) claims a size, but its unwritten parts take no
space on disk. How was this one made? `sudo cat /home/kai/.bash_history`. What
does `dd ... count=0 seek=1024` actually write?

</details>

<details><summary>Hint C4 (nearly the answer)</summary>

The kernel can only swap to blocks that really exist on disk, so a sparse file
can't be swap. Recreate it as a real 1 GB file:

```bash
sudo rm /swapfile
sudo fallocate -l 1G /swapfile        # or: sudo dd if=/dev/zero of=/swapfile bs=1M count=1024
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo systemctl start swapfile.swap    # or: sudo swapon /swapfile
swapon --show
```

The line in `/etc/fstab` was fine. Why `chmod 600`? Think about what ends up in
swap.

</details>

---

## Is search-server the leak?

<details><summary>Hint H1</summary>

Look at two columns, not one: `top` (VIRT and RES), or
`ps -o pid,vsz,rss,comm -C search-server`. Which one is memory that's really in
use? Watch RES for a few minutes: does it grow? Then see what makes VIRT so big:
`sudo pmap -x $(systemctl show -p MainPID --value search)` and look for the
biggest mapping.

</details>

<details><summary>Hint H2</summary>

VIRT counts every address range a process has *mapped*, including files it
mapped and never read. RES counts the pages actually in RAM. search-server maps
its 4 GiB postings file, which is sparse (`ls -lh` versus `du -h`), and the
kernel only reads in the pages that queries touch. It's not a leak, and
restarting it every hour would change nothing. Compare the *same* column across
processes, and watch it over time.

</details>

---

## Guard checks (5 and 6)

<details><summary>Hint G1: "Fixes survive a reboot" fails</summary>

Something is fixed only in the *running* system. Ask yourself:

- Did you change units with `--runtime`, or by writing to `/proc` (for example
  `/proc/<PID>/oom_score_adj`)? Both are gone after a reboot. Use
  `systemctl edit`, which writes a drop-in under `/etc/systemd/system/`.
- Did you run `sudo systemctl daemon-reload` after editing unit files?
- Is the agent's queue limit in its config file, and is the agent's unit still
  shielded with no memory limit of its own?
- Will `/etc/fstab` turn on a working swap file at boot?

Then `sudo reboot`, `vagrant ssh` again, and run `sudo lab-check`.

</details>

<details><summary>Hint G2: "Nothing important was removed or weakened" fails</summary>

Did you raise or remove the shop's budget (`pinewood.slice`), or move a service
out of it? Remove the reindex's own memory limit, or set it above 512 MB? Stop,
disable or reschedule the refresh, the reindex or the agent? Run a service as
root? Leave the swap file readable by other users (`chmod 600 /swapfile`)?
Undo it and use the narrower fix.

</details>
