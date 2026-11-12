# Something keeps killing it

**Level:** Intermediate · **Time:** 90–150 minutes · **Host:** `web-04` at `<LAB_IP>`

`<LAB_IP>` is address `.14` on your computer's host-only network. On Windows
with VirtualBox that's `192.168.56.14`. On a Mac, Fusion's host-only network has
a different subnet on every machine (for example `172.16.129.14`).
`vagrant up` prints the address at the end.

Pinewood Books runs its storefront on web-04, and this morning the storefront
keeps dying. Nobody is stopping it, and nothing in its own log explains it: the
process is simply gone, and a few seconds later systemd starts it again. Search
has a problem too: the holiday titles that Merchandising imported last week
can't be found. You're the day-shift SRE.

This is the first lab where the problems come from **memory**. Something is
killing processes on purpose, and you'll have to work out *who* does it, *why*
it picks the process it picks, and what is really using up the memory. The
defects interact: fixing one changes how the others look, and the process that
dies isn't the one that caused it. The ticket also contains a theory that
sounds convincing and is wrong.

**You'll practise:** reading the kernel's OOM-killer reports
(`journalctl -k`), telling a process that crashed from one that was killed, cgroup
v2 memory limits and systemd slices (`MemoryMax`, `systemd-cgtop`,
`memory.events`), OOM scores (`oom_score`, `oom_score_adj`, `OOMScoreAdjust=`),
watching a process's memory over time, the difference between VIRT and RES,
sparse files, and swap (`swapon`, `/etc/fstab`, `.swap` units).

## What you should know before you start

This lab builds on the Beginner and Beginner+ labs. You don't need to know the
areas below in depth. You need to know what each one *is*, so you know where to
look. The lab teaches the rest.

- **Shell basics.** Reading files and logs with `cat`, `less`, `tail` and
  `grep`, piping commands together, a simple `while` loop, and editing a
  root-owned file with `sudo` and an editor (`nano` or `vim`).
- **Processes and signals.** What a PID is, listing processes with `ps` and
  `top`, and that `kill` sends a *signal*: `SIGTERM` asks a process to stop,
  and `SIGKILL` (9) ends it on the spot.
- **systemd services.** `systemctl status`, `start`, `restart` and `cat`,
  reading a unit's log with `journalctl -u`, and changing a unit with a drop-in
  (`systemctl edit`) followed by `systemctl daemon-reload`. The
  [slow-storefront](../../beginner/slow-storefront/) lab covers drop-ins.
- **Scheduled jobs.** systemd timers and `systemctl list-timers`. The
  [storefront-hiccups](../../beginner-plus/storefront-hiccups/) lab covers
  matching symptoms with schedules.
- **Memory, the basic idea.** RAM is shared by every program, the kernel keeps
  recently used files in memory as cache, and `free -h` shows how much is
  *available*, not just *free*. Swap is disk space the kernel can move memory
  to when RAM runs short.
- **Files and disks.** `ls -l`, `df -h`, and that `/etc/fstab` lists what's
  mounted at boot.

**Quick self-check.** If you can answer these without looking anything up,
you're ready:

1. A service's process is gone, and `systemctl status` says
   `code=killed, status=9/KILL`. Did it crash, or did something end it?
2. In `free -h`, why can "available" be much bigger than "free"?
3. How do you see the log of a service that ran from a timer an hour ago?
4. You change a unit file. What do you run before restarting the service, and
   why?

You *don't* need to know cgroups, the OOM killer, `pmap`, `choom` or
`mkswap` yet. The hints introduce them when you need them.

## Start

Do the one-time setup for [macOS](../../../docs/setup-macos.md) or
[Windows](../../../docs/setup-windows.md) first. Then, from the repository root
(the commands are the same in Terminal and PowerShell):

```bash
cd labs/intermediate/storefront-keeps-dying
vagrant up                     # ~7 minutes the first time (downloads the box)
vagrant snapshot save broken   # reset point. Take it now, before you touch anything
vagrant ssh
```

Read the ticket in [TICKET.md](TICKET.md) (or run `cat /etc/lab/ticket.md` in the VM)
and start investigating.

## Rules of engagement

- Treat it like production. Fix root causes, not symptoms.
- Before every change, say what you expect it to do. After it, measure.
- Platform standard PS-12 stays: the shop's services share one 640 MB budget
  (`pinewood.slice`), and every batch job has a memory limit of its own. Don't
  raise the budget, and don't move anything out of it.
- Keep the 10-minute catalog refresh, the hourly search reindex, and the
  metrics agent. Losing the agent's oldest queued metrics is acceptable.
- Restarting something on a schedule isn't a fix.
- Your fix must survive a reboot. You can test that with `sudo reboot`.
- Check your progress with `sudo lab-check`. Done means **6/6 PASS**.

## The checks

```text
 storefront-keeps-dying  Something keeps killing it
 ------------------------------------------------------------
 [FAIL] 1. The storefront survives its 10-minute catalog refresh
 [FAIL] 2. Search finds the holiday titles
 [FAIL] 3. A runaway metrics agent can't take the shop down with it
 [FAIL] 4. The 1 GB swap safety net is active
 [FAIL] 5. Fixes survive a reboot
 [PASS] 6. Nothing important was removed or weakened
```

Check 6 starts out passing. It's a guard that fails if your fix throws away
something that matters.

Checks 1 and 2 don't wait for the timers. They run the catalog refresh and the
search reindex right away, the way the timers would, so lab-check takes up to a
minute. While the problems are still there, running lab-check can take the
storefront down for a few seconds, just as the timers do.

## When you're stuck, and when you're done

- [HINTS.md](HINTS.md) has progressive hints per issue, from vague to specific.
- [SOLUTIONS.md](SOLUTIONS.md) has root causes, fixes, and concepts. **Spoilers.**

## Reset and tear down

```bash
vagrant snapshot restore --no-provision broken   # back to the freshly broken state
vagrant destroy -f                                # remove the lab completely...
vagrant up                                        # ...and rebuild it from scratch
```

See the [lab lifecycle](../../../README.md#lab-lifecycle) for suspend/resume and
other commands. One note for this lab: something on web-04 keeps growing while
the VM runs. Use `vagrant suspend` for breaks rather than leaving the VM running
overnight.

## What's in this folder

| File | Purpose | Spoilers? |
|---|---|---|
| `Vagrantfile` | VM: Ubuntu 24.04, 2 vCPU, 1.5 GB RAM, private IP | no |
| `TICKET.md` | the incident ticket | no |
| `HINTS.md` | progressive hints | collapsed |
| `check.sh` | becomes `lab-check` in the VM | source only |
| `provision/setup.sh` | builds the healthy system | mostly no |
| `provision/break.sh` | injects the incident | **yes** |
| `SOLUTIONS.md` | full write-up | **yes** |
