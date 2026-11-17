# Out of sync with the warehouse

**Level:** Beginner+ · **Time:** 90–150 minutes · **Host:** `web-05` at `<LAB_IP>`

`<LAB_IP>` is address `.15` on your computer's host-only network. On Windows
with VirtualBox that's `192.168.56.15`. On a Mac, Fusion's host-only network has
a different subnet on every machine (for example `172.16.129.15`).
`vagrant up` prints the address at the end.

Pinewood Books ships its orders through Larch Logistics, and Larch's agent runs
on web-05 next to the storefront. Since yesterday the shop and the warehouse
disagree about everything: stock levels are out of date, orders aren't arriving,
and book pages are slow now and then. The agent's log says almost nothing, and
the agent is a closed-source binary, so there's no code to read. You're the
day-shift SRE.

This is the lab where you stop guessing what a program does and **watch it**.
Every time a program opens a file, sleeps, waits for a lock, or talks to another
process, it asks the kernel to do it with a **system call**. `strace` shows you
those requests and the kernel's answers, for any program, with or without its
source code. Around it is a toolbox that answers "what is this process doing
right now?": the files under `/proc/<pid>`, `lsof`, and a few others. Several
separate problems are involved, and the ticket's clues are thin.

**You'll practise:** running a command under `strace` and reading its output,
following child processes and threads (`-f`), filtering by kind of system call,
attaching to a running process (`-p`), timing system calls (`-T`, `-tt`, `-c`),
reading error codes (`errno`), file descriptors, what a process is waiting for
(`/proc/<pid>/wchan`, `/proc/<pid>/stack`, `ps` states), who holds a file lock
(`/proc/locks`, `lsof`), checking every directory on a path (`namei`), a
process's environment (`/proc/<pid>/environ`), and running a command exactly as
a service runs it.

## What you should know before you start

This lab builds on the Beginner labs. You don't need to know the areas below in
depth. You need to know what each one *is*, so you know where to look. The lab
teaches the rest.

- **Shell basics.** Moving around the filesystem, reading files with `cat`,
  `less`, `tail` and `grep`, piping commands together, redirecting output to a
  file (`> file`, `2>&1`), and editing a root-owned file with `sudo` and an
  editor (`nano` or `vim`).
- **Users, files and permissions.** Reading `ls -l`: the owner, the group, and
  the `rwx` bits for the owner, the group and everyone else. Changing them with
  `chown` and `chmod`. Running a command as another user with `sudo -u`.
- **Processes.** What a PID is, listing processes with `ps` and `pstree`,
  parent and child processes, and that `kill` sends a *signal* (`SIGTERM` asks a
  process to stop).
- **systemd services and timers.** `systemctl status`, `start`, `restart` and
  `cat`, `systemctl list-timers`, and reading a unit's log with
  `journalctl -u <unit>`. The [storefront-hiccups](../storefront-hiccups/) lab
  covers timers.
- **Standard input and output.** That every process starts with stdin, stdout
  and stderr, and that they can be a terminal, a file, or a pipe.
- **Environment variables.** What `$HOME` and `$PATH` are, and that each process
  has its own copy of its environment.

**Quick self-check.** If you can answer these without looking anything up,
you're ready:

1. In `-rw-r----- 1 root audit 812 report.txt`, which users can read the file?
2. A service runs as user `larch`. How would you run the same command yourself,
   as `larch`, to see what it prints?
3. What's the difference between `systemctl status larch-ship` saying
   `active (running)` and the service actually doing its job?
4. You run `env` in your shell and a service runs `env`. Why might the output be
   different?

You *don't* need to know `strace`, `/proc`, `lsof`, `namei`, file locks, or any
C. The hints introduce them when you need them, and start with a short warm-up.

## Start

Do the one-time setup for [macOS](../../../docs/setup-macos.md) or
[Windows](../../../docs/setup-windows.md) first. Then, from the repository root
(the commands are the same in Terminal and PowerShell):

```bash
cd labs/beginner-plus/storefront-out-of-sync
vagrant up                     # ~7 minutes the first time (downloads the box)
vagrant snapshot save broken   # reset point. Take it now, before you touch anything
vagrant ssh
```

Read the ticket in [TICKET.md](TICKET.md) (or run `cat /etc/lab/ticket.md` in the VM)
and start investigating.

## Rules of engagement

- Treat it like production. Fix root causes, not symptoms.
- `larch` is a vendor's binary. Don't change it, don't run it as root, and don't
  replace the warehouse key Security issued.
- The warehouse on the other side of the file drop (`/srv/warehouse`) is
  simulated by `warehouse-sim.timer`. It's scenery, not part of the incident.
  Leave it alone.
- Every order must reach the warehouse exactly once. Don't delete orders, and
  don't send any twice.
- Don't fix a permission problem by opening things up to everyone.
- **Don't reboot until you've found every cause.** Some of the evidence lives in
  memory, and a reboot destroys it. Once you've fixed everything, rebooting to
  prove your fixes last is a good idea (`sudo reboot`).
- Your fixes must survive a reboot.
- Check your progress with `sudo lab-check`. Done means **6/6 PASS**.

## The checks

```text
 storefront-out-of-sync  Out of sync with the warehouse
 ------------------------------------------------------------
 [FAIL] 1. The shop shows the warehouse's current stock levels
 [FAIL] 2. New orders reach the warehouse within seconds
 [FAIL] 3. Every order placed so far reached the warehouse, exactly once
 [FAIL] 4. Book pages load quickly, with a real delivery estimate
 [FAIL] 5. Fixes survive a reboot
 [PASS] 6. Nothing important was removed or weakened
```

Check 6 starts out passing. It's a guard that fails if your fix throws away or
weakens something that matters.

lab-check acts like the world around web-05: it has the warehouse publish new
stock levels, places a real order, and empties the delivery-estimate cache
before it loads book pages. It can take up to 20 seconds to run.

## When you're stuck, and when you're done

- [HINTS.md](HINTS.md) starts with a short `strace` warm-up, then has
  progressive hints per issue, from vague to specific.
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
| `HINTS.md` | an `strace` warm-up, then progressive hints | collapsed |
| `check.sh` | becomes `lab-check` in the VM | source only |
| `provision/setup.sh` | builds the healthy system, including the source of the "closed-source" agent | **yes**, in section 3 |
| `provision/break.sh` | injects the incident | **yes** |
| `SOLUTIONS.md` | full write-up | **yes** |
