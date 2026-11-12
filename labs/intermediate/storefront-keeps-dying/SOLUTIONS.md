# Solutions: Something keeps killing it

> **Spoilers.** Try the lab and [HINTS.md](HINTS.md) first. You'll learn far
> more from fighting with it for a while.

## The big picture

Three root causes, plus one alarm that isn't a problem at all. Two of the
causes share one memory budget, so they hide behind each other.

```text
  pinewood.slice: the shop's shared budget, MemoryMax=640M (Platform standard PS-12)
  +-----------------------------------------------------------------------------------+
  | pinewood-agent   ~500 MB and growing   oom_score_adj -1000: never killed          |
  |   metrics-01 offline (CHG-0601) + no queue limit (CHG-0577)                       |
  |   = five days of metrics batches in memory, reloaded from a spool on restart . A  |
  |                                                                                   |
  | storefront       ~100 MB, +75 MB while it rebuilds its page cache (every 10 min)  |
  |   -> the biggest process the kernel is *allowed* to kill: killed, 502s ....... A  |
  |                                                                                   |
  | search-reindex   needs ~230 MB since the holiday import (CHG-0596),               |
  |   own MemoryMax=160M (sized for 12,000 books): killed every hour ............ B  |
  |                                                                                   |
  | search-server    ~25 MB RES, ~4 GB VIRT (a mapped sparse file) ....... red herring |
  +-----------------------------------------------------------------------------------+

  /swapfile: "1 GB", made with dd count=0 seek=1024 (CHG-0588): a sparse file.
  swapon refuses files with holes, so there has never been any swap .............. C
```

| # | Issue | Category | Visible symptom | Since |
|---|---|---|---|---|
| A | The storefront is killed every few minutes | cgroup memory limits, OOM killer, OOM scores, unbounded memory growth | 502s for a few seconds at :00, :10, :20... (and :45); `status=9/KILL`, `oom-kill` | CHG-0601, five days ago; visible since this morning |
| B | Search can't find the holiday titles | cgroup memory limits, capacity | `search-reindex.service` fails with `oom-kill` every hour; the index has 12,000 books | CHG-0596, last week |
| C | No swap | swap, sparse files, fstab and `.swap` units | `free -h`: `Swap: 0B`; `swapfile.swap` failed | CHG-0588, two weeks ago |
| - | "search-server is the leak" | VIRT vs RES, memory-mapped files | `top`: VIRT ~4 GB | none |

---

## Walkthrough: one efficient path

You might take a different route, and that's fine. Sample output is shortened.
PIDs, times and sizes will differ on your machine.

**1. Measure over time.** The 502s come in bursts of a few seconds, on a
schedule:

```console
$ while true; do printf '%s ' "$(date +%T)"; curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://localhost/book/1; sleep 1; done
10:19:59 200 0.003s
10:20:00 200 0.004s
10:20:01 502 0.001s          <- dead...
10:20:04 502 0.001s
10:20:05 200 0.004s          <- ...and back
```

**2. How did it die?** Not a crash. Something sent it `SIGKILL`:

```console
$ journalctl -u storefront | grep -E 'OOM|code=killed|result'
Nov 12 08:39:40 web-04 systemd[1]: storefront.service: A process of this unit has been killed by the OOM killer.
Nov 12 08:39:40 web-04 systemd[1]: storefront.service: Main process exited, code=killed, status=9/KILL
Nov 12 08:39:40 web-04 systemd[1]: storefront.service: Failed with result 'oom-kill'.
Nov 12 08:50:00 web-04 systemd[1]: storefront.service: Main process exited, code=killed, status=9/KILL
Nov 12 08:50:00 web-04 systemd[1]: storefront.service: Failed with result 'signal'.
```

`status=9/KILL` every time. Most of the time systemd also notices the kernel's
OOM kill and says so. When it doesn't notice in time, it only reports
`'signal'`, so don't rely on that line: the kernel log has the full story. The
times line up with `storefront-refresh.timer` (every 10 minutes), and once an
hour with `search-reindex.timer` (:45).

**3. Read the kernel's OOM report.** It says which group ran out of memory, and
who was in it (shortened):

```console
$ sudo journalctl -k | grep -E 'invoked oom-killer|memory: usage|stats for|Tasks state|^.{20,40}kernel: \[|oom-kill:|Killed process'
storefront invoked oom-killer: gfp_mask=0xcc0(GFP_KERNEL), order=0, oom_score_adj=0
memory: usage 655360kB, limit 655360kB, failcnt 102
Memory cgroup stats for /pinewood.slice:
Tasks state (memory values in pages):
[  pid  ]   uid  tgid total_vm      rss rss_anon rss_file rss_shmem pgtables_bytes swapents oom_score_adj name
[    904]   995   904  1056000     5422     2496     2926         0   106496        0             0 search-server
[    907]   999   907    86253    35289    32293     2996         0   352256        0             0 storefront
[   1171]   994  1171   187770   130975   127988     2987         0  1118208        0         -1000 pinewood-agent
[   1226]   999  1226     5302     2671      320     2351         0    86016        0             0 curl
oom-kill:constraint=CONSTRAINT_MEMCG,nodemask=(null),cpuset=/,mems_allowed=0,oom_memcg=/pinewood.slice,task_memcg=/pinewood.slice/storefront.service,task=storefront,pid=907,uid=999
Memory cgroup out of memory: Killed process 907 (storefront) total-vm:345012kB, anon-rss:129172kB, file-rss:11984kB, shmem-rss:0kB, UID:999 pgtables:344kB oom_score_adj:0
```

`limit 655360kB` is 640 MB, and `oom_memcg=/pinewood.slice` says the whole
shop's budget ran out, not the storefront's. The task table (in 4 kB pages)
shows the biggest process by far: the metrics agent, 130,975 pages (~510 MB),
with `oom_score_adj -1000`. The kernel isn't allowed to kill it, so it kills the
next biggest: the storefront (~140 MB), in the middle of its refresh. (The
`curl` is the refresh timer's job, asking the storefront to rebuild.)

**4. Why is the agent so big?** It's been unable to push anything for five
days, and it keeps everything:

```console
$ journalctl -u pinewood-agent -o cat | tail -n 3
pinewood-agent 2.3.1 starting: pushing to http://metrics-01.pinewood.example:8428/api/v1/import every 10 s; queue limit: none (queue_limit_mb = 0)
loaded 44,155 batches from /var/lib/pinewood-agent/queue.spool: 44,155 batches (485.6 MB) waiting
push failed: <urlopen error timed out>; 44,163 batches (485.6 MB) waiting, oldest from 2026-11-07T06:00:00Z
```

**5. Fix A:** give the queue a limit, take the shield off, restart. The
storefront survives its next refresh.

**6. Fix B:** the reindex now dies at **its own** limit
(`oom_memcg=/pinewood.slice/search-reindex.service`). Measure its peak (about
230 MB), give it `MemoryMax=320M`, run it: search finds the holiday titles.

**7. Fix C:** `free -h` shows no swap, `systemctl --failed` shows
`swapfile.swap`, and `swapon` says the file "appears to have holes". Recreate it
as a real file.

| Fixed so far | What you measure |
|---|---|
| nothing | 502s every 10 minutes; reindex killed by the *slice*; no swap |
| C only (swap) | the 502s stop: the agent's idle queue is swapped out. Check 3 still fails, and swap use keeps growing |
| A (agent) | no more 502s; the reindex is now killed by *its own* limit |
| A + B (reindex limit) | search finds the holiday titles |
| A + B + C | 6/6, after a reboot too |

Any order works, as long as you measure after every change. Fixing C first is
the most instructive trap: it makes the symptom go away without fixing anything.

---

## Issue A: the storefront keeps dying

**Root cause.** All of the shop's services run in one systemd slice,
`pinewood.slice`, with `MemoryMax=640M`. That's Platform standard PS-12: whatever
the shop does, the OS, sshd and your login keep the rest of the RAM. When the
processes in the slice need more than 640 MB, the kernel's **OOM killer** runs
*inside the slice* and kills one of them.

Three weeks ago, CHG-0577 ("metrics agent hardening") changed two things after
the agent's queue had dropped batches during an earlier incident:

- `queue_limit_mb = 0`: batches that can't be pushed are kept in memory, with
  no limit.
- `OOMScoreAdjust=-1000` (a drop-in): the kernel may never kill the agent.

Neither mattered while metrics-01 was up. Five days ago metrics-01 went offline
for a rebuild (CHG-0601). Since then the agent has collected a ~10 KB batch every
10 seconds, failed to push it, and kept it. By this morning that was ~490 MB of
the shop's 640 MB. The storefront still fits in what's left, but every 10
minutes it rebuilds its page cache next to the old one, which needs ~75 MB more
for a moment. The slice runs out, and the kernel picks a victim among the
processes it's *allowed* to kill. The biggest is the storefront, mid-refresh.
systemd restarts it after 2 seconds; it loads its cache and serves again until
the next refresh. The hourly reindex triggers the same thing at :45.

Two more details make the problem stubborn:

- **Restarting the agent doesn't help.** It saves its queue to a spool file on
  stop and loads it again at start. The night on-call's restarts were of the
  storefront, which isn't the problem at all.
- **The uptime monitor barely notices.** `/healthz` is down for the same few
  seconds as everything else, so a once-a-minute check usually misses it.

**Diagnose.**

```console
$ systemctl status pinewood.slice storefront search pinewood-agent | grep -E '●|Memory'
● pinewood.slice - Pinewood Books shop (shared memory budget)
     Memory: 594.5M (max: 640.0M available: 45.4M peak: 640.0M)
● storefront.service - Pinewood Books storefront
     Memory: 83.2M (peak: 83.5M)
● search.service - Pinewood Books search (search-server)
     Memory: 10.1M (peak: 19.0M)
● pinewood-agent.service - Pinewood Books metrics agent
     Memory: 501.0M (peak: 502.2M)

$ cat /sys/fs/cgroup/pinewood.slice/memory.events
low 0
high 0
max 322
oom 7               <- the shop's budget ran out 7 times...
oom_kill 7          <- ...and the kernel killed a process each time
oom_group_kill 0

$ for u in storefront search pinewood-agent; do choom -p "$(systemctl show -p MainPID --value $u)"; done
pid 2638's current OOM score: 712
pid 2638's current OOM score adjust value: 0
pid 1973's current OOM score: 676
pid 1973's current OOM score adjust value: 0
pid 2071's current OOM score: 0
pid 2071's current OOM score adjust value: -1000

$ systemctl cat pinewood-agent | grep -B3 OOMScore
# /etc/systemd/system/pinewood-agent.service.d/10-resilience.conf
# CHG-0577: the agent must survive memory trouble. ...
OOMScoreAdjust=-1000

$ curl -s localhost:8126/status | jq '{queue_limit_mb, queued_batches, queued_bytes, oldest_batch, last_push_error}'
{
  "queue_limit_mb": 0.0,
  "queued_batches": 44167,
  "queued_bytes": 509252869,
  "oldest_batch": "2026-11-07T06:00:00Z",
  "last_push_error": "2026-11-12T08:40:54Z <urlopen error timed out>"
}

$ pidstat -r -p "$(systemctl show -p MainPID --value pinewood-agent)" 60 3    # still growing
```

`systemd-cgtop -m` shows the same thing live. The slice's `memory.events` is
the place to count kills: each service's own counters start again from zero
every time systemd restarts it (a restart creates a new cgroup). Notice the
trap in the OOM report, too: the first line says `storefront invoked
oom-killer`. That names the process whose request for memory couldn't be met,
which isn't necessarily the culprit.

**Fix.**

```bash
sudo sed -i 's/^queue_limit_mb = 0$/queue_limit_mb = 16/' /etc/pinewood-agent/agent.conf
sudo systemctl edit pinewood-agent        # [Service]  OOMScoreAdjust=0
                                          # (or delete the 10-resilience.conf drop-in)
sudo systemctl daemon-reload
sudo systemctl restart pinewood-agent
journalctl -u pinewood-agent -o cat -n 3
#   stopping: saved 44,174 batches (485.8 MB) to /var/lib/pinewood-agent/queue.spool
#   pinewood-agent 2.3.1 starting: ... queue limit: 16 MB
#   loaded 44,174 batches from ...: 1,468 batches (16.0 MB) waiting; dropped the 42,706 oldest (queue limit 16 MB)
systemctl status pinewood-agent | grep Memory        # ~30M
sudo systemctl start storefront-refresh.service      # the refresh, now: the storefront keeps its PID
```

The agent keeps the newest ~16 MB of metrics (about 4 hours' worth) for when
metrics-01 is back, and drops the oldest. The ticket says that's acceptable.

Both halves matter. The **limit** stops the growth. Removing the **shield**
decides who pays if something in the shop grows out of control again: with the
shield, it's always someone else. A `MemoryMax=` on the agent's own unit is a
good extra (defense in depth): then a runaway agent hits *its own* limit and
the kernel kills it, not its neighbours. lab-check accepts either removing the
shield or boxing the agent in.

**Don't:**
- Restart the storefront, or anything else, on a schedule. The storefront is
  the victim. The night on-call restarted it twice; it died again each time.
- Restart the agent without a limit: it comes back from its spool at the same
  size.
- Raise the slice's `MemoryMax` or move the agent out of the slice. A bigger
  budget only buys a few more days before the queue fills that too, and takes
  memory the OS and your login were promised (check 6).
- Delete the spool and stop there: the queue starts again from zero and grows
  back in five days.
- Stop or disable the agent: Monitoring needs it (check 6).
- Fix it with swap (Issue C). The agent's idle queue moves to disk and the
  symptom goes away, but the queue keeps growing, now into swap.

**Concepts.**
- **The OOM killer.** When memory runs out and the kernel can't free enough
  (dropping file cache, writing to swap), it kills a process to save the rest.
  It doesn't pick the process that asked for the memory, nor the one that grew
  the most. It picks the one with the highest **OOM score**, roughly the share
  of memory it uses, shifted by `oom_score_adj`.
- **`oom_score_adj`** ranges from −1000 (never kill) to +1000 (kill first).
  systemd sets it with `OOMScoreAdjust=`. See it with `cat /proc/PID/oom_score`,
  `cat /proc/PID/oom_score_adj` or `choom -p PID`. (`oom_score` is shown on a
  scale where about 666 means "uses hardly any memory" and higher means "kill
  me sooner"; −1000 makes it 0.) Shielding a process doesn't free any memory.
  It only chooses a different victim.
- **systemd's `oom-kill` result is a courtesy.** systemd watches its units'
  cgroups and, when it notices that the kernel OOM-killed one of their
  processes, says so. When the process's exit wins the race, it only reports
  `signal`. `status=9/KILL` plus the kernel log is the reliable evidence.
- **Global OOM vs cgroup OOM.** `constraint=CONSTRAINT_NONE` means the whole
  machine ran out. `CONSTRAINT_MEMCG` means a memory cgroup hit its limit: only
  processes inside that cgroup are candidates. `oom_memcg` is the group that ran
  out; `task_memcg` is where the victim lived.
- **Slices.** A systemd slice is a cgroup that groups units, so they can share
  a limit. `systemd-cgls` shows the tree, `systemd-cgtop -m` shows memory per
  group, `systemctl status <unit>` shows `Memory:` with its peak, and
  `/sys/fs/cgroup/<slice>/memory.events` counts `oom` (hit its own limit) and
  `oom_kill` (processes killed in it, including below it).
- **"Leaks" that aren't bugs.** Nothing here forgot to free memory. A queue
  with no limit plus a dependency outage behaves exactly like a leak. Every
  buffer, queue and cache needs a bound, and a decision about what happens when
  it's full (drop the oldest, refuse new data, or spill to disk).
- **Who invoked it, who got killed, who's to blame** are three different
  questions.

**Prevention.** Alert on OOM kills (the kernel log, or `oom_kill` in a slice's
`memory.events`) and on service restarts (`NRestarts`), not just on the service
being down: a service that restarts in seconds looks healthy to a
once-a-minute probe. Alert on queue
size and on the age of the oldest unsent metric. Review any `OOMScoreAdjust=` below
zero: it moves the pain, it doesn't remove it. And test what each component does
when its dependency is down for a week.

---

## Issue B: search can't find the holiday titles

**Root cause.** The search index is rebuilt every hour by
`search-reindex.service`, a batch job. PS-12 says every batch job has its own
memory limit, sized from its measured peak, and doesn't swap. The job reads the
whole catalog into memory and builds the index there. With 12,000 books it
peaked at about 80 MB, so `MemoryMax=160M` was set: plenty of room. Last week
Merchandising imported 28,000 holiday titles (CHG-0596). The job's memory grows
with the catalog, and with 40,000 books it needs about 230 MB. Since the import,
the kernel has killed it at its 160 MB limit every hour, so search still answers
from the last index built before the import (12,000 books, no holiday titles).
Nobody noticed because the job doesn't page anyone, and the home page reads the
catalog directly, so the holiday titles *look* live.

While Issue A is unfixed, you'll mostly see a different death: the reindex
needs memory that the *slice* doesn't have, so the kernel picks a victim in the
slice. Sometimes that's the storefront (another 502 at :45), sometimes the
reindex itself. Fix A, and the reindex dies cleanly at its own limit instead.

**Diagnose.**

```console
$ curl -s 'localhost/search?q=midwinter+lanterns' | grep -o -e 'No books match' -e 'Search index built[^<]*'
No books match
Search index built 2026-11-04T13:45:02Z &middot; 12,000 books
$ curl -s localhost/ | grep -o '[0-9,]* books in the shop'
40,000 books in the shop

$ systemctl status search-reindex.service | grep -E 'Active|Process'
     Active: failed (Result: oom-kill) since Thu 2026-11-12 08:45:03 UTC; 3min ago
    Process: 2574 ExecStart=/opt/search/search-reindex (code=killed, signal=KILL)
$ sudo journalctl -k | grep 'oom-kill:' | grep -o 'oom_memcg=[^,]*,task_memcg=[^,]*' | sort | uniq -c
      1 oom_memcg=/pinewood.slice,task_memcg=/pinewood.slice/search-reindex.service
      5 oom_memcg=/pinewood.slice,task_memcg=/pinewood.slice/storefront.service
      1 oom_memcg=/pinewood.slice/search-reindex.service,task_memcg=/pinewood.slice/search-reindex.service

$ systemctl cat search-reindex.service | grep -A4 PS-12
# Platform standard PS-12: every batch job has its own memory limit, sized from
# its measured peak, and batch jobs don't swap.
# Measured peak with the 12,000-book catalog: about 80 MB.
MemoryMax=160M
MemorySwapMax=0
```

**Measure, then size.** With Issue A fixed, run a one-off copy of the job with
a generous limit, in the same slice:

```console
$ sudo systemd-run --scope --uid=search --gid=search -p Slice=pinewood.slice \
    -p MemoryMax=400M -p MemorySwapMax=0 /opt/search/search-reindex
Running as unit: run-r832ce0aaa16a48fa94c6fef768f851ea.scope; invocation ID: ...
reindex: read 40,000 books from the catalog
reindex: indexed 40,000 books (676 words) in 2.1 s, peak memory 231 MB
```

That run also rebuilt the index, so search works right now. The hourly runs
still have the old limit, though, and lab-check runs the real job.

**Fix.**

```bash
sudo systemctl edit search-reindex.service
#   [Service]
#   # Measured peak with the 40,000-book catalog: ~230 MB.
#   MemoryMax=320M
sudo systemctl start search-reindex.service       # don't wait for :45
journalctl -u search-reindex -o cat -n 2          # reindex: indexed 40,000 books ... peak memory 231 MB
curl -s 'localhost/search?q=midwinter+lanterns' | grep -o 'Midwinter Lanterns' | head -1
```

320 MB is the measured peak plus about a third, for a catalog that's still growing. It
also has to fit in the budget next to everything else: 640 MB minus the agent
(~30 MB), the storefront (~100 MB, ~175 MB during a refresh) and search-server
(~30 MB). That works only because Issue A is fixed.

**Don't:** remove the limit (`MemoryMax=infinity`) or set it to the size of the
whole slice. Inside the slice, a job without a limit of its own can push the
storefront out (check 6 requires a limit of 512 MB at most). Don't allow it to
swap: a batch job that swaps can run for hours instead of failing in seconds.
Don't make the change with `systemctl set-property --runtime`: it's gone after
a reboot (check 5).

**Concepts.**
- **`MemoryMax=`** is a hard limit: at the limit, the kernel first tries to
  reclaim memory from the group (file cache, and swap if allowed), then
  OOM-kills inside it. `MemoryHigh=` is a softer limit that slows the group down
  by reclaiming hard, without killing.
- **`MemorySwapMax=0`** stops the group from swapping. Without it, a group at its
  limit with swap available swaps instead of being killed: slow instead of
  dead, which for a batch job is often worse.
- **Limits come from measurements, and measurements expire.** Record what a
  limit was sized for (here: the catalog size), and re-measure when that
  changes. A program's own peak is its *maximum resident set size*
  (`ru_maxrss`, what this job prints); a cgroup's is in its `memory.peak` file
  while the cgroup exists.
- **A job that fails quietly.** A failed timer job doesn't page anyone unless
  you make it. `systemctl --failed` would have shown this one every day.

**Prevention.** Alert on failed units. Add "re-measure the batch jobs" to the
checklist for big catalog imports. Monitor how old the search index is.

---

## Issue C: there is no swap

**Root cause.** Two weeks ago Kai added a 1 GB swap file as a safety net
(CHG-0588), using a well-known shortcut:

```bash
sudo dd if=/dev/zero of=/swapfile bs=1M count=0 seek=1024
```

`count=0` copies nothing; `seek=1024` moves 1 GB into the file before writing
that nothing. The result is a **sparse file**: 1 GB long, but with no disk
blocks behind it. `mkswap` even warned ("/swapfile contains holes or other
unsupported extents. This swap file can be rejected by kernel on swap
activation!"), and `swapon` refuses it, because the
kernel writes to swap by going straight to disk blocks and a hole has none. Kai
added the fstab line, ran `daemon-reload` and expected swap after the next boot.
At every boot since, systemd has tried, failed and logged it, and the server
has had no swap at all.

**Diagnose.**

```console
$ free -h | grep Swap
Swap:             0B          0B          0B
$ systemctl --failed
  UNIT                     LOAD   ACTIVE SUB    DESCRIPTION
● search-reindex.service   loaded failed failed Rebuild the search index from the catalog
● storefront-refresh.service loaded failed failed Refresh the storefront's catalog cache
● swapfile.swap            loaded failed failed /swapfile
$ journalctl -u swapfile.swap -o cat | tail -n 4
swapon: /swapfile: skipping - it appears to have holes.
swapfile.swap: Swap process exited, code=exited, status=255/EXCEPTION
swapfile.swap: Failed with result 'exit-code'.
Failed to activate swap swapfile.swap - /swapfile.
$ ls -lhs /swapfile          # the first column is the space actually used
4.0K -rw------- 1 root root 1.0G Oct 29 11:00 /swapfile
```

**Fix.**

```bash
sudo rm /swapfile
sudo fallocate -l 1G /swapfile     # really allocates the blocks (or: dd if=/dev/zero of=/swapfile bs=1M count=1024)
sudo chmod 600 /swapfile           # swap holds copies of memory: passwords, keys, sessions
sudo mkswap /swapfile
sudo systemctl start swapfile.swap # what boot does; or: sudo swapon /swapfile
swapon --show
```

The fstab line is fine. After this, `swapfile.swap` turns on at every boot.

**Why swap matters here, and why it isn't the fix for A.** With swap, the
kernel can move memory that nobody is using (like five days of unsent metrics)
out of RAM, instead of killing a process. That's exactly what a safety net is
for. It also means that if you fix C first, the storefront stops dying: the
agent's idle queue is moved to swap whenever the slice is full. That's swap
*hiding* the problem: the queue keeps growing into swap, and in a few more days
it's full too. lab-check's check 3 still fails until A is fixed. (The reindex
has `MemorySwapMax=0`, so swap doesn't change Issue B.)

**Don't:** leave the swap file readable by other users (`fallocate` creates it
`0644`; `swapon` warns about "insecure permissions"; check 6 fails). Don't make
it a swap *partition* in the middle of an incident.

**Concepts.**
- **Sparse files.** A file's *size* (`ls -l`) and the *space it uses*
  (`du`, `ls -s`) can differ. Holes read back as zeros but take no disk space.
  The same idea makes `search-server`'s 4 GiB index cheap; see the red herring.
- **Swap files** must be fully allocated, owned by root, mode 0600, and
  initialised with `mkswap`. `swapon --show` and `free -h` show what's active.
- **fstab and systemd.** Each swap line in `/etc/fstab` becomes a `.swap` unit
  at boot (`systemctl list-units --type swap`). When it fails, it's a failed unit
  like any other: `systemctl --failed`, `journalctl -u`.
- **Verify the claims.** "We have 1 GB of swap" was in the ticket, in the change
  log and in everyone's head. One `free -h` disproves it.

**Prevention.** After a change, check its effect, not just its commands (`free
-h` after adding swap). Alert when the system is `degraded` (`systemctl
is-system-running`). Use `fallocate` (or `dd` without `seek`) for swap files, and
read `mkswap`'s warnings.

---

## The red herring: "search-server uses 4 GB"

```console
$ ps -o pid,vsz,rss,comm -C search-server,storefront,pinewood-agent
    PID    VSZ   RSS COMMAND
   1973 4297732 22372 search-server
   2071 750688 523820 pinewood-agent
   2638 224992 97084 storefront
$ sudo pmap -x 1973 | grep -E 'postings|total'
000071f47ad43000 4194304     832       0 r--s- postings.dat
total kB         4297732   22372   13780
$ ls -lhs /var/lib/search/current/postings.dat
6.0M -rw-r--r-- 1 search search 4.0G Nov  4 13:45 /var/lib/search/current/postings.dat
```

VSZ/VIRT counts every address range a process has mapped: code, libraries,
heap, and whole files mapped with `mmap`, whether or not they've been read.
search-server maps its 4 GiB postings file, which is sparse: only 6 MB of it
holds data, and the kernel only reads in the pages that queries touch (832 kB
here). RSS/RES is memory actually in RAM, and search-server's is ~22 MB and
flat. The agent's RSS is ~510 MB and growing. Compare the *same* column across
processes, and watch it over time.

Restarting search-server every hour would change nothing. The kernel's own
choice agrees: its OOM score is low, and it has never been killed.

---

## Verifying the fix

```bash
sudo lab-check                                        # expect 6/6 PASS
sudo systemctl start storefront-refresh.service       # the storefront keeps its PID
systemctl show -p NRestarts storefront                # stays the same from now on
sudo systemd-cgtop -m -n 1 | head                     # pinewood.slice well below 640M
free -h                                               # Swap: 1.0Gi
sudo reboot                                           # then vagrant ssh again and: sudo lab-check
```

---

## Example post-incident note

> **INC-2531: Storefront killed repeatedly, and holiday titles missing from
> search, on web-04 (SEV-2)**
>
> **Impact:** From early Thursday until <time fixed>, the storefront returned
> 502 for 3–5 seconds every 10 minutes and at :45 each hour. Since the holiday
> import eight days earlier, search couldn't find any of the 28,000 new titles.
> The uptime monitor caught only a few of the outages.
>
> **Root causes:**
> 1. CHG-0577 removed the metrics agent's queue limit and shielded it from the
>    OOM killer. When metrics-01 went offline (CHG-0601), the agent kept every
>    batch in memory: ~490 MB of the shop's 640 MB budget after five days. Each
>    catalog refresh then ran the budget out, and the kernel killed the
>    storefront, because it wasn't allowed to kill the agent.
> 2. The hourly reindex's memory limit was sized for the 12,000-book catalog. After
>    the import (40,000 books) the job needs ~230 MB and was killed at its 160 MB
>    limit every hour, so the index stayed at last week's catalog.
> 3. The 1 GB swap file from CHG-0588 was a sparse file, which `swapon` refuses,
>    so the server never had swap.
>
> **Resolution:** Restored a 16 MB queue limit on the agent and removed its OOM
> shield (it kept the newest 16 MB of metrics). Measured the reindex's peak
> (231 MB) and raised its limit to 320 MB; reran it. Recreated the swap file
> with `fallocate`. Verified with lab-check, a forced refresh, a reindex and a
> reboot.
>
> **What went well:** The shared memory budget did its job: the OS, SSH and
> nginx were never affected, and the kernel's reports named the group that ran
> out.
>
> **Action items:**
> - Alert on OOM kills and restarts, on failed units, and on the agent's queue
>   size and oldest batch.
> - Policy: no `OOMScoreAdjust` below 0 for non-critical services; every queue
>   and buffer has a bound.
> - Re-measure batch jobs' memory after catalog imports; record what each limit
>   was sized for.
> - Check a change's effect, not just its commands (`free -h` after adding swap).
> - Monitor a database-backed page and the search index age, not only `/healthz`.

Write it **blameless**: describe how the system and process let it happen, not
who typed what.

---

## Cheat sheet: commands from this lab

| Task | Command |
|---|---|
| How did it end? | `systemctl status <unit>` · `journalctl -u <unit>` (look for `code=killed, status=9/KILL`, `oom-kill`) · `systemctl show -p NRestarts,Result <unit>` |
| OOM-killer reports | `sudo journalctl -k \| grep -E 'invoked oom-killer\|oom-kill:\|Killed process'` · `sudo dmesg -T` |
| Memory per group | `systemd-cgtop -m` · `systemd-cgls` · `systemctl status <unit>` (`Memory:` and its peak) |
| A group's limit and events | `systemctl show -p MemoryMax,MemoryCurrent,MemoryPeak <unit>` · `cat /sys/fs/cgroup/<path>/memory.events` |
| Memory per process | `ps -o pid,rss,vsz,comm --sort=-rss` · `top` (press `M`) · `pidstat -r -p <PID> 30` · `sudo pmap -x <PID>` |
| OOM scores | `cat /proc/<PID>/oom_score` · `choom -p <PID>` · `OOMScoreAdjust=` in the unit |
| Change a unit for good | `sudo systemctl edit <unit>` (drop-in in `/etc`) · `sudo systemctl daemon-reload` |
| Measure a job's peak | `sudo systemd-run --wait -p MemoryMax=... <command>` (prints `Memory peak`) |
| Swap | `free -h` · `swapon --show` · `systemctl --failed` · `journalctl -u swapfile.swap` |
| Size vs space used | `ls -lhs FILE` · `du -h FILE` · `stat FILE` |
| Make a swap file | `fallocate -l 1G F && chmod 600 F && mkswap F && swapon F` |

## Extra credit

1. Watch the slice from the inside: `watch -n1 cat /sys/fs/cgroup/pinewood.slice/memory.current`
   while you run `sudo systemctl start storefront-refresh.service`. Then set
   `MemoryHigh=600M` on the slice (with `--runtime`, on a snapshot) and repeat
   with the agent's limit removed. What changes? What does `memory.events`
   `high` count?
2. Give the agent its own `MemoryMax=64M` and *keep* `OOMScoreAdjust=-1000`,
   with no queue limit. What happens when its queue reaches 64 MB? (Hint: who is
   left in that cgroup that the kernel may kill?)
3. Read `man 5 systemd.resource-control` for `ManagedOOMMemoryPressure=`. Ubuntu
   desktops run `systemd-oomd`, a userspace killer that acts on memory
   *pressure* before the kernel's OOM killer would. How would you find out
   whether it killed something?
4. `cat /proc/pressure/memory` and `/sys/fs/cgroup/pinewood.slice/memory.pressure`:
   what do the `some` and `full` lines measure? Compare them before and after
   the fix.
5. Make a 100 MB sparse file and a 100 MB real one. Compare `ls -l`, `du`, and
   how long `cp` takes for each. What does `cp --sparse=always` do?
