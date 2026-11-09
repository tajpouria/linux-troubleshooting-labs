# Solutions: The storefront is crawling

> **Spoilers.** Try the lab and [HINTS.md](HINTS.md) first. You'll learn far
> more from fighting with it for a while.

## The big picture

Three independent root causes, each of which is enough to make the shop slow on
its own, plus one alarm that isn't a problem at all.

```text
  customers ---> nginx :80 ---> storefront app (127.0.0.1:8080)      one page = ~25 ms of CPU
                   ^                  |
                   |                  '-X- capped at 5% of one CPU: CPUQuota=5%,
                   |                       set by the night on-call ........................ Issue C
                   |
  loadgen.py (user dani) -X- 16 nonstop requests from the server itself,
                             restarted at every boot by an @reboot crontab line ............ Issue B

  catalog-reindex (1 worker per CPU) -X- Nice=-10 from a drop-in: beats the storefront
                                         for CPU time, nearly every time ................... Issue A

  free -h: almost no "free" memory -> page cache from the 1 GB catalog export. Harmless ... red herring
```

| # | Issue | Category | Visible symptom | Slowness on its own |
|---|---|---|---|---|
| A | Batch job outranks the storefront | process priority, systemd drop-ins | both CPUs at 100%, `NI -10` in `top` | ~250 ms per page |
| B | Forgotten load test | processes, process trees, cron | access log flooded by `pinewood-loadgen`, many connections from `127.0.0.1` | ~500 ms per page |
| C | CPU cap on the storefront | systemd resource control, cgroups | app never above ~5% CPU, even when the CPUs are idle | ~500 ms per page |
| - | "Free memory below 10%" | memory | `free` column low, `available` high | none |

Together they make a page take about 9 seconds. A healthy page takes 25–40 ms.

---

## Walkthrough: one efficient path

You might take a different route, and that's fine. Sample output is shortened.
PIDs, times and percentages will differ on your machine.

**1. Measure the symptom.**

```console
$ curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://localhost/
200 9.447900s
$ curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://localhost/healthz
200 8.283528s
```

Even `/healthz`, which does almost nothing, takes 8 seconds. So the app is
either starved of CPU or stuck behind a queue of other requests. A health
check that only alerts when the request *fails* will happily stay green.

**2. Is the server busy?**

```console
$ uptime
 10:48:31 up 19 min,  0 user,  load average: 4.88, 3.94, 2.92
$ nproc
2
```

A load of nearly 5 on 2 CPUs: on average about three processes are waiting
for a CPU at any moment.

**3. Busy with what?**

```console
$ ps -eo pid,user,ni,pcpu,stat,cmd --sort=-pcpu | head -6
    PID USER      NI %CPU STAT CMD
   2065 catalog  -10 95.8 R<   /usr/bin/python3 /usr/local/bin/catalog-reindex --workers auto
   2064 catalog  -10 95.5 R<   /usr/bin/python3 /usr/local/bin/catalog-reindex --workers auto
   1661 storefr+   0 11.0 Rsl  /usr/bin/python3 /opt/storefront/app.py --port 8080
   2045 catalog  -10  0.5 S<s  /usr/bin/python3 /usr/local/bin/catalog-reindex --workers auto
   1942 dani       0  0.2 Sl   /usr/bin/python3 /home/dani/loadtest/loadgen.py --url http://127.0.0.1/ ...
```

Two reindex workers own the CPUs, at nice `-10` (`<` in `STAT` means "high
priority"). That's Issue A. Further down there's something from user `dani`
with a URL on its command line. Hold that thought.

**4. Fix the priority (Issue A) and remeasure: 9.5 seconds. No change at all.**
This is the most useful moment in the lab. The fix is right, but it didn't
help, so something *else* is the bottleneck. Look at the storefront itself in
`top`: it sits at about 5% of a CPU and never goes higher, even though
thousands of requests are waiting and the reindex now steps aside. A process
that can't use more than a fixed, round amount of CPU is being limited.
`systemctl status storefront` shows an unexpected drop-in. That's Issue C.

**5. Remove the cap (Issue C) and remeasure: about 0.5 seconds.** Much better,
but still about 20 times slower than normal, and the access log is scrolling
non-stop:

```console
$ sudo tail -n 2 /var/log/nginx/access.log
127.0.0.1 - [...] "GET / HTTP/1.1" 200 1727 rt=10.500 urt=10.500 "pinewood-loadgen/0.3 (CHG-0420)"
127.0.0.1 - [...] "GET / HTTP/1.1" 200 1710 rt=9.396 urt=9.396 "pinewood-loadgen/0.3 (CHG-0420)"
```

**6. Stop the load test (Issue B) and remeasure: about 0.03 seconds.** Back to
normal.

| Fixed so far | Median page time |
|---|---|
| nothing | 9.7 s |
| A (priority) | 9.5 s |
| A + C (priority, cap) | 0.49 s |
| A + C + B (everything) | 0.027 s |

Fixing C first works too (9.7 s, then 3.1 s, then 0.47 s, then 0.03 s). Whatever
the order, measure after every change.

**7. Verify:** `sudo lab-check`, then `sudo reboot`, wait a minute, and check again.

---

## Issue A: the batch job outranks the storefront

**Root cause.** The nightly catalog reindex is CPU-heavy by design: it runs one
worker process per CPU. Its unit sets `Nice=10` so it only uses CPU time the
storefront doesn't need. Last week CHG-0398 added a drop-in with `Nice=-10`
"so it finishes before business hours". That was harmless while the reindex
finished overnight. This week the catalog doubled, the reindex ran into the
morning, and every customer request now competes with two workers that the
scheduler strongly prefers.

**Diagnose.**

```console
$ systemctl status 2065 | head -4                # which unit owns the busy PID?
● catalog-reindex.service - Nightly catalog reindex (search index for the storefront)
     Loaded: loaded (/etc/systemd/system/catalog-reindex.service; static)
    Drop-In: /etc/systemd/system/catalog-reindex.service.d
             └─override.conf

$ systemctl cat catalog-reindex
# /etc/systemd/system/catalog-reindex.service
...
# Batch work: always let the storefront go first when both want the CPU.
Nice=10

# /etc/systemd/system/catalog-reindex.service.d/override.conf
# CHG-0398: the reindex has to be done before business hours.
# Give it a bigger share of the CPU so it finishes sooner.
[Service]
Nice=-10
```

**Fix.** Fix the configuration, then the running processes.

```bash
sudo systemctl edit catalog-reindex     # change Nice=-10 to Nice=19 (or delete the override file)
sudo systemctl daemon-reload            # `systemctl edit` does this for you; harmless to repeat
sudo systemctl restart catalog-reindex  # resumes from its checkpoint
```

Or, without restarting, renice every process of the job now and rely on the
fixed unit for the next start:

```bash
sudo renice -n 19 -p $(pgrep -u catalog)
```

`renice -p <one PID>` changes only that process. The workers are separate
processes, so renicing only the main PID changes nothing that matters.

**Don't:** stop or kill the reindex. The business needs it today, and check 3
fails if you do. Don't renice the processes and stop there either. The next
time the job starts (tonight at 01:00, or after a reboot), it's at -10 again,
and check 4 fails.

**Concepts.**
- **Load average** counts processes that are running or waiting to run (plus
  those stuck waiting for disk), averaged over 1, 5 and 15 minutes. Compare it
  with `nproc`: a load of 2.0 on 2 CPUs is "full", 5.0 means a queue.
- **Nice values** go from -20 (most favoured) to 19 (least). The scheduler
  shares CPU time by *weight*: nice 0 weighs 1024, nice -10 weighs 9548, and
  nice 19 weighs 15. When the storefront (0) shares a CPU with a worker at -10,
  it gets about 1024 / (1024 + 9548) ≈ 10% of it, so a page that needs 25 ms
  of CPU takes about 250 ms. Against a worker at 19, it gets about 98%.
- **Low priority doesn't mean slow when the CPU is free.** After the fix the
  reindex still uses both CPUs and finishes in about the same time. It just
  steps aside whenever the storefront needs a CPU. The load average stays near
  2, and that's fine: the users are happy. Load alone isn't a problem.
- In `top`, CPU time of processes with a *positive* nice value is counted as
  `ni`, not `us`. After the fix, the `%Cpu(s)` line moves from mostly `us` to
  mostly `ni`, which is an easy way to see that the busy work is low-priority.
- **Drop-ins.** systemd merges a unit file with every `*.conf` file in
  `<unit>.d/` directories. `systemctl status` lists them under `Drop-In:` and
  `systemctl cat` prints them all. A later setting wins.
- `ps` and `top` show the nice value in the `NI` column. In `ps` `STAT`, `<`
  means high priority and `N` means low priority.

**Prevention.** Give batch jobs low priority by default (`Nice=19`; for
I/O-heavy jobs also `IOSchedulingClass=idle`) or a lower `CPUWeight=`. If a job
has to finish by a deadline, fix the job (more efficient code, an earlier
start, a bigger server) instead of letting it outrank customers. Alert when
nightly jobs run into business hours.

---

## Issue B: a load test nobody stopped

**Root cause.** For CHG-0420, Dani ran a capacity test against the storefront
*from web-02 itself*: `loadgen.py`, 4 worker processes with 4 threads each,
requesting the home page non-stop. To keep it running across reboots it was
started from an `@reboot` line in Dani's crontab. The test window ended on
Wednesday, but nobody stopped it. 16 fake clients take turns with real
customers for the storefront's CPU.

**Diagnose.**

```console
$ sudo awk '{ print $1 }' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -3
    181 127.0.0.1                                   <- almost every request comes from the server itself

$ sudo ss -tnp state established '( dport = :80 )' | head -3
Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
0      0          127.0.0.1:34924     127.0.0.1:80  users:(("python3",pid=1944,fd=6))
0      0          127.0.0.1:34964     127.0.0.1:80  users:(("python3",pid=1942,fd=6))

$ ps -ef --forest | grep -B3 -A5 '[l]oadgen'
root        1933       1  /usr/sbin/cron -f -P
root        1936    1933   \_ /usr/sbin/CRON -f -P
dani        1939    1936       \_ /bin/sh -c /usr/bin/python3 /home/dani/loadtest/loadgen.py ... >> .../loadgen.log 2>&1
dani        1941    1939           \_ /usr/bin/python3 /home/dani/loadtest/loadgen.py --url http://127.0.0.1/ ...
dani        1942    1941               \_ /usr/bin/python3 /home/dani/loadtest/loadgen.py ...
dani        1943    1941               \_ /usr/bin/python3 /home/dani/loadtest/loadgen.py ...
dani        1944    1941               \_ /usr/bin/python3 /home/dani/loadtest/loadgen.py ...
dani        1946    1941               \_ /usr/bin/python3 /home/dani/loadtest/loadgen.py ...

$ sudo crontab -l -u dani
# CHG-0420: holiday capacity test. Keep the load going if web-02 reboots.
@reboot /usr/bin/python3 /home/dani/loadtest/loadgen.py --url http://127.0.0.1/ --workers 4 --threads 4 >> /home/dani/loadtest/loadgen.log 2>&1
```

`cat /home/dani/loadtest/NOTES.txt` confirms the plan and the forgotten TODO.
`journalctl -u cron` shows cron starting the command at boot.

**Fix.**

```bash
kill 1941                        # the loadgen parent (yours will differ); it stops its workers
pgrep -af loadgen.py             # nothing left?
sudo crontab -e -u dani          # put a # in front of the @reboot line
```

Then tell Dani (and the CHG-0420 owner) what you did and why.

**Don't:** kill only the workers. The parent starts new ones within a second
(`loadgen.log` says so). Don't kill only the `/bin/sh -c` line either: that's
the shell cron used to launch the command, and killing it leaves Python
running. Don't `userdel dani` or delete their files to make it stop. That's
someone else's work and evidence for the review, and check 5 fails if the
account is gone. Be careful with `sudo pkill -f loadgen`: `-f` matches whole
command lines, and the `sudo` process running it contains "loadgen" too.
`pgrep -af` first, then `kill`, is safer.

**Concepts.**
- **Every process has a parent** (`PPID`). `ps -ef --forest` and `pstree -p`
  show the tree. To stop something that restarts its children, stop whatever
  restarts them.
- `kill PID` sends SIGTERM, which asks the process to exit and lets it clean up.
  Here the parent stops its workers on the way out. `kill -9` (SIGKILL) can't
  be caught: the process gets no chance to clean up, so keep it for when
  SIGTERM doesn't work.
- **Who starts things at boot?** systemd units, timers, cron (`@reboot` in a
  user's crontab, `/etc/crontab`, `/etc/cron.d/`). `systemctl status <PID>`
  showed `cron.service` as this process's home.
- **Per-user crontabs** live in `/var/spool/cron/crontabs/`. Read and edit them
  with `crontab -l -u <user>` and `crontab -e -u <user>`, not by editing the
  files directly.
- **Access logs answer "who is asking?"** This nginx log also records timings:
  `rt=` is the whole request and `urt=` is the time spent waiting for the app.

**Prevention.** Run load tests from a separate machine against a non-production
target, or at least with a hard time limit (`timeout 8h loadgen.py ...`, or a
systemd unit with `RuntimeMaxSec=`). Close a change only after its cleanup
steps are done. Alert on unusual request rates and on traffic from unexpected
sources.

---

## Issue C: a CPU cap on the storefront

**Root cause.** At 01:35 the night on-call saw the storefront high in `top`. It
was actually busy serving the load test while it fought the reindex for CPU.
To "keep the box responsive" they ran
`systemctl set-property storefront.service CPUQuota=5%`. That caps the whole
service at 5 ms of CPU time every 100 ms. One page needs about 25 ms of CPU, so
even on an idle server it takes 5 periods, roughly half a second. The limit was
meant to be temporary, but `set-property` makes it permanent unless you add
`--runtime`.

**Diagnose.**

```console
$ systemctl status storefront | head -4
● storefront.service - Pinewood Books storefront
     Loaded: loaded (/etc/systemd/system/storefront.service; enabled; preset: enabled)
    Drop-In: /etc/systemd/system.control/storefront.service.d
             └─50-CPUQuota.conf

$ systemctl cat storefront | tail -4
# /etc/systemd/system.control/storefront.service.d/50-CPUQuota.conf
# This is a drop-in unit file extension, created via "systemctl set-property"
# or an equivalent operation. Do not edit.
[Service]
CPUQuota=5%

$ systemctl show -p CPUQuotaPerSecUSec storefront
CPUQuotaPerSecUSec=50ms

$ cat /sys/fs/cgroup/system.slice/storefront.service/cpu.max
5000 100000                                     <- 5,000 µs allowed per 100,000 µs period

$ grep throttled /sys/fs/cgroup/system.slice/storefront.service/cpu.stat
nr_throttled 382                                <- paused for running out of quota, 382 times
throttled_usec 40697087                         <- ...for 40 seconds in total
```

You can also watch it: `systemd-cgtop` shows `storefront.service` stuck at
about 5% while you load the page in a loop.

**Fix.**

```bash
sudo systemctl set-property storefront.service CPUQuota=   # an empty value removes the cap
systemctl show -p CPUQuotaPerSecUSec storefront            # infinity
```

Deleting `/etc/systemd/system.control/storefront.service.d/50-CPUQuota.conf`
and then running `sudo systemctl daemon-reload` and
`sudo systemctl restart storefront` also works.

**Don't:** "fix" it by raising the storefront's own priority (`Nice=-20`). The
cap isn't about priority: a capped service is paused even when the CPU is idle.
A cap of 100% or more is fine (check 4 accepts it); 5% isn't.

**Concepts.**
- **cgroups** (control groups) are how the kernel limits groups of processes.
  Every systemd service has its own cgroup under `/sys/fs/cgroup/system.slice/`.
- **`CPUQuota=`** sets a hard ceiling: `cpu.max` is "quota per period". 100%
  equals one full CPU. Once the quota is used up, the service is *throttled*
  (paused) until the next period, whatever else the CPU is doing.
- **Quota vs priority.** Nice values and `CPUWeight=` only matter when there's
  contention: they decide who goes first. A quota limits a service even when
  nobody else wants the CPU.
- `systemctl set-property` writes drop-ins under `/etc/systemd/system.control/`,
  or under `/run/...` with `--runtime`, which is gone after a reboot. Know which
  one you're making.
- **Symptoms that point to a limit, not a shortage:** a process that plateaus at
  a suspiciously round number (5%, 50%, 100%), while `top` shows idle CPU.

**Prevention.** Make emergency limits temporary on purpose
(`set-property --runtime`, or a ticket to remove them), write them down in the
incident channel, and hand them over to the day shift. Better still, find out
*why* a service uses CPU before you limit it: here it was busy with the load test.

---

## The red herring: "free memory below 10%"

```console
$ free -h
               total        used        free      shared  buff/cache   available
Mem:           1.4Gi       330Mi        78Mi       1.2Mi       1.0Gi       1.0Gi
```

(Example from a 1.5 GB VM.) `free` is low because the reindex read last night's
~1 GB catalog export, and Linux keeps recently read files in memory as a cache
(`buff/cache`). The kernel gives that memory back instantly when a program needs
it, which is what `available` shows: about 1 GB. `vmstat 1` shows `si`/`so`
(swap in and out) at 0, so nothing is short of memory.

**Don't** run `echo 3 > /proc/sys/vm/drop_caches` to make the alert go away. It
only throws away a useful cache and makes the next disk reads slower. **Fix the
alert instead:** alert on `MemAvailable`, swap activity, or OOM kills, not on
"free".

---

## Verifying the fix

```bash
curl -s -o /dev/null -w '%{time_total}s\n' http://localhost/   # ~0.03 s again
sudo lab-check                                                 # expect 5/5 PASS
sudo reboot                        # then vagrant ssh again and: sudo lab-check  (still 5/5)
```

After the reboot, the reindex resumes on its own (`catalog-reindex-resume.service`
starts it if a run was interrupted), so you can see that your priority fix
holds.

---

## Example post-incident note

> **INC-2318: Storefront slow on web-02 (SEV-3)**
>
> **Impact:** Storefront pages took 5–15 seconds instead of ~30 ms from about
> 01:00 until <time fixed>. Customers abandoned checkouts. The site never went
> fully down, so the uptime monitor stayed green.
>
> **Root causes:**
> 1. The nightly catalog reindex ran into business hours (the catalog doubled
>    this week) at `Nice=-10` (CHG-0398), so it beat the storefront for CPU.
> 2. The CHG-0420 load test was still running on web-02 two days after its
>    window ended, sending 16 nonstop requests. It was restarted at every boot by
>    an `@reboot` crontab entry.
> 3. During the night, the storefront was capped at `CPUQuota=5%` as a
>    temporary mitigation. That cap was itself enough to make every page take
>    about half a second.
>
> **Resolution:** Set the reindex back to low priority (`Nice=19`) without
> stopping it. Stopped the load test and disabled its `@reboot` entry. Removed the
> CPU cap. Verified page times and a reboot.
>
> **What went well:** The reindex checkpoints its progress, so it could be
> restarted safely. The access log's timing fields made the slowness measurable.
>
> **Action items:**
> - Batch jobs run at `Nice=19` by default. Deadlines are met by scheduling or
>   capacity, not priority.
> - Load tests run from a separate host, with an end time built in.
> - Emergency limits use `--runtime` and are handed over at shift change.
> - Monitor page latency (not just `/healthz`) and alert on `MemAvailable`, not "free".

Write it **blameless**: describe how the system and process let it happen, not
who typed what.

---

## Cheat sheet: commands from this lab

| Task | Command |
|---|---|
| Time a request | `curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' URL` |
| How busy is the server? | `uptime` · `nproc` · `top` (`1` per-CPU, `c` command lines, `P` sort by CPU, `M` sort by memory) |
| Top CPU users | `ps -eo pid,user,ni,pcpu,stat,cmd --sort=-pcpu \| head` |
| Process tree | `ps -ef --forest` · `pstree -p` · `ps -o pid,ppid,cmd -p <PID>` |
| Which unit owns a PID? | `systemctl status <PID>` |
| Stop a process | `kill <PID>` (SIGTERM) · `kill -9 <PID>` (last resort) · `pgrep -af <pattern>` first |
| Priority | `ps -o pid,ni,cmd` · `renice -n 19 -p <PIDs>` · `Nice=` in the unit |
| Unit config and drop-ins | `systemctl cat <unit>` · `systemctl edit <unit>` · `systemctl daemon-reload` |
| A service's properties | `systemctl show -p Nice,CPUQuotaPerSecUSec <unit>` |
| CPU limits | `systemctl set-property <unit> CPUQuota=` · `/sys/fs/cgroup/system.slice/<unit>/cpu.max` and `cpu.stat` · `systemd-cgtop` |
| Memory | `free -h` (read `available`) · `vmstat 1` (`si`/`so`) |
| Who's connecting? | `ss -tnp state established '( dport = :80 )'` · nginx access log |
| Scheduled jobs | `crontab -l -u <user>` · `crontab -e -u <user>` · `systemctl list-timers` · `journalctl -u cron` |

## Extra credit

1. With the reindex at `Nice=19`, time it: does it finish noticeably later than
   at -10? Watch its progress lines in `journalctl -u catalog-reindex -f`.
2. Replace `Nice=` with `CPUWeight=` in a drop-in. What's the difference
   between a process's nice value and a cgroup's CPU weight?
3. Put the cap back with `--runtime`, look for its drop-in under `/run`, then
   reboot. Where did it go?
4. Run the load test yourself as Dani for 30 seconds, with an end time built in:
   `sudo -u dani timeout 30 python3 /home/dani/loadtest/loadgen.py --url http://127.0.0.1/`.
   How many requests per second can the storefront serve, and why does the
   number stop growing when you add more threads? (Hint: one Python process.)
5. `top` shows a process's CPU as a percentage of *one* CPU. Why can a process
   show more than 100%?
