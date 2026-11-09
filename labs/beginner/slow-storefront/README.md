# The storefront is crawling

**Level:** Beginner · **Time:** 45–90 minutes · **Host:** `web-02` at `<LAB_IP>`

`<LAB_IP>` is address `.12` on your computer's host-only network. On Windows
with VirtualBox that's `192.168.56.12`. On a Mac, Fusion's host-only network has
a different subnet on every machine (for example `172.16.129.12`).
`vagrant up` prints the address at the end.

Pinewood Books runs its storefront on web-02, and this morning it's crawling.
Nothing is down: every page loads eventually, and the health check is green.
You're the day-shift SRE. This is a performance incident. Your job is to find
out what the server is so busy with, and why the shop gets so little of it.
Several separate problems add up, much like a real incident. Fixing one makes
the next one easier to see.

**You'll practise:** measuring response times with `curl`, reading `uptime`
and the load average, `top` (CPU states, the process list, priorities),
process trees and parent processes, stopping processes properly, process
priority (`nice` and `renice`), how systemd services are configured (unit
files and drop-ins), reading `free` correctly, nginx access logs, and crontabs.

## What you should know before you start

This is a beginner lab, but it assumes you're comfortable on a Linux command
line. You don't need to be an expert in any of the areas below. You need to know
what each one *is*, so you know where to look. The lab teaches the rest.

- **Shell basics.** Moving around the filesystem, reading files with `cat`,
  `less`, `tail` and `grep`, piping commands together, and editing a root-owned
  file with `sudo` and an editor (`nano` or `vim`).
- **Processes.** What a process and a PID are, that every process has a
  *parent* that started it, listing processes with `ps` or `top`, and stopping
  one with `kill`.
- **CPU and memory, the basic idea.** A program uses CPU time while it computes.
  A server with 2 CPUs can run two things truly at the same time; everything
  else has to take turns. Memory (RAM) is where running programs keep their data.
- **systemd services.** That background programs run as *units*, how to start,
  stop, restart and check the status of one with `systemctl`, and that services
  write their logs to the systemd journal (`journalctl`).
- **Scheduled jobs.** That Linux can run commands automatically on a schedule,
  with cron or with systemd timers.
- **HTTP and web servers.** Fetching a page with `curl`, and the idea of a
  *reverse proxy*: a web server that takes requests on port 80 and passes them
  to an application on another port. (The [storefront-down](../storefront-down/)
  lab covers this.)

**Quick self-check.** If you can answer these without looking anything up,
you're ready:

1. How do you find out which process started process 1234?
2. What's the difference between `systemctl stop` and `systemctl disable`?
3. What does `kill 1234` do, and how is `kill -9 1234` different?
4. How would you measure how long a single `curl` request takes?

## Start

Do the one-time setup for [macOS](../../../docs/setup-macos.md) or
[Windows](../../../docs/setup-windows.md) first. Then, from the repository root
(the commands are the same in Terminal and PowerShell):

```bash
cd labs/beginner/slow-storefront
vagrant up                     # ~5 minutes the first time (downloads the box)
vagrant snapshot save broken   # reset point. Take it now, before you touch anything
vagrant ssh
```

Read the ticket in [TICKET.md](TICKET.md) (or run `cat /etc/lab/ticket.md` in the VM)
and start investigating.

## Rules of engagement

- Treat it like production. Fix root causes, not symptoms.
- Measure before and after every change. In a performance incident, "it feels
  faster" isn't evidence.
- The nightly catalog reindex must finish (see the ticket). Don't cancel it.
- Don't delete a colleague's account or files to make a problem go away.
- Your fix must survive a reboot. You can test that with `sudo reboot`.
- Check your progress with `sudo lab-check`. Done means **5/5 PASS**.

## The checks

```text
 slow-storefront  The storefront is crawling
 ------------------------------------------------------------
 [FAIL] 1. Storefront pages load quickly (median under 150 ms)
 [FAIL] 2. Traffic to the web server is back to normal levels
 [PASS] 3. Nightly catalog reindex is still running, or has finished
 [FAIL] 4. Fixes survive a reboot
 [PASS] 5. Nothing important was removed or weakened
```

Checks 3 and 5 start out passing. They're guards that fail if your fix breaks
something else.

Check 1 compares page times with what this VM measured when it was healthy,
during `vagrant up`. The limit is 150 ms or the healthy time plus 100 ms,
whichever is bigger, so the lab is fair on both fast and slow computers.

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
other commands.

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
