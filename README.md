# Linux Troubleshooting Labs

Progressive, hands-on SRE incident labs. Each level gives you a Linux server
that's broken in realistic ways, plus an incident ticket that describes only the
symptoms. Your job is to find the root causes, fix them properly, and prove it
with an automated check.

- **Runs on:** Apple Silicon Macs with VMware Fusion + Vagrant
- **Guest:** Ubuntu 24.04 LTS, ARM64 (`bento/ubuntu-24.04`)
- **Format:** one folder per level. Run `vagrant up`, troubleshoot, then run
  `sudo lab-check`.
 
## Levels

| Level | Scenario | Difficulty | Skills |
|---|---|---|---|
| [lab-01](lab-01/) | The storefront is down | Beginner | disk space, systemd services, logs and journald, file permissions, processes, ports and host firewall |
| lab-02 | *planned:* "It's slow, then it's not" | Beginner+ | DNS resolution, cron and systemd timers, log rotation, inode exhaustion, time sync |
| lab-03 | *planned:* "Can't connect" | Intermediate | routing, MTU, nftables, TLS certificate expiry, ephemeral ports, conntrack |
| lab-04 | *planned:* "Something keeps killing it" | Intermediate | memory pressure, the OOM killer, swap, cgroup memory limits, leaks |
| lab-05 | *planned:* "Too many open files" | Intermediate | kernel parameters (`sysctl`), ulimits, `somaxconn`, `file-max`, backlog drops |
| lab-06 | *planned:* "Disk trouble" | Intermediate+ | LVM (extend, migrate, snapshots), fstab, read-only remounts, `fsck` |
| lab-07 | *planned:* "It won't boot" | Advanced | emergency mode, broken fstab, GRUB and kernel command line, initramfs, systemd targets |
| lab-08 | *planned:* "Everything is slow" | Advanced | load vs CPU, iowait, `perf`, `strace`, slow disks (`dm-delay`), noisy neighbours |
| lab-09 | *planned:* "The container keeps dying" | Advanced | containers, cgroups v2, namespaces, overlayfs, container OOM, bridge networking and NAT |
| lab-10 | *planned:* capstone | Expert | a multi-VM incident that combines everything above |

## Getting started

1. **One-time setup.** Install Homebrew, VMware Fusion, Vagrant, the Vagrant
   VMware Utility and the plugin by following [docs/setup-macos.md](docs/setup-macos.md).
2. **Check you're ready.** Each level's README begins with *What you should
   know before you start*: the concepts it assumes and a short self-check. It
   contains no spoilers.
3. **Start a level:**

   ```bash
   cd lab-01
   vagrant up                     # builds the server, then breaks it (~5 min)
   vagrant snapshot save broken   # your reset point. Do this right away!
   vagrant ssh
   cat /etc/lab/ticket.md         # the incident ticket (also in lab-01/TICKET.md)
   ```

4. **Troubleshoot** inside the VM (you have `sudo`). Check your progress at any
   time:

   ```bash
   sudo lab-check                     # inside the VM
   vagrant ssh -c 'sudo lab-check'    # or from your Mac
   ```

   Each check prints PASS or FAIL. It tells you *what* is still wrong from the
   user's point of view, never *why*.

5. **Stuck?** Open the level's `HINTS.md`. Every issue has hints that go from
   vague to specific. **Done?** Write your post-incident note, then compare it
   with `SOLUTIONS.md`.

## Lab lifecycle

All commands run on your Mac, from inside the level's folder (for example `lab-01/`).

| Goal | Command |
|---|---|
| Build the lab and inject the incident | `vagrant up` |
| Save a reset point (right after the first `up`) | `vagrant snapshot save broken` |
| Open a shell | `vagrant ssh` |
| Check progress | `vagrant ssh -c 'sudo lab-check'` |
| **Reset** to the freshly broken state (fast) | `vagrant snapshot restore --no-provision broken` |
| **Reset** by rebuilding from scratch (slow, always works) | `vagrant destroy -f && vagrant up` |
| Pause and resume (keeps the exact running state) | `vagrant suspend` / `vagrant resume` |
| List snapshots | `vagrant snapshot list` |
| Power off | `vagrant halt` (see the note below) |
| **Tear down** (deletes the VM, its disks and snapshots) | `vagrant destroy -f` |
| Free the base box too (when you're done with all levels) | `vagrant box remove bento/ubuntu-24.04 --all` |
| Find VMs you forgot about | `vagrant global-status --prune` |

> **Suspend, don't halt.** Some incidents live partly in memory, such as a
> process holding a deleted file open. A reboot can make a problem *look* fixed
> or change its shape, just like in production. Use `suspend`/`resume` for
> breaks and snapshots for resets. Rebooting on purpose to test that your fix
> survives is a good idea, though.

> **Don't run `vagrant provision`** on a lab you've started. The provisioners
> notice that the lab is already set up and refuse, so they don't half-reset
> it. Use a snapshot restore or destroy/up instead.

## Spoiler policy

| File | Safe to read? |
|---|---|
| `TICKET.md` | Yes, start here |
| `README.md`, `Vagrantfile` | Yes |
| `HINTS.md` | Yes. Hints are collapsed, and headings describe symptoms only |
| `check.sh` | The **output** is spoiler-free, but the **source** gives hints away |
| `provision/break.sh`, `SOLUTIONS.md` | No, spoilers! |
| `provision/setup.sh` | Mostly harmless. It builds the *healthy* system |

The repo isn't mounted inside the VM, so you won't find the answers by poking
around the server. Only the evidence is there.

## Repository layout

```text
.
├── README.md                    you are here
├── docs/
│   └── setup-macos.md           one-time host setup + toolchain troubleshooting
├── common/                      shared by every level
│   ├── lib/lab-common.sh        PASS/FAIL helpers for check scripts (-> /usr/local/lib/lab/)
│   └── provision/base.sh        ARM64 guard, toolbox, lab-check, login banner
└── lab-01/
    ├── Vagrantfile              the VM: 2 vCPU, 2 GB RAM, private IP, extra 1 GB disk
    ├── TICKET.md                the incident, symptoms only
    ├── HINTS.md                 progressive hints per issue
    ├── SOLUTIONS.md             root causes, fixes, concepts (spoilers)
    ├── check.sh                 installed in the VM as `lab-check`
    └── provision/
        ├── setup.sh             builds the healthy baseline and smoke-tests it
        └── break.sh             injects the incident (spoilers)
```

## Adding a new level

Every level follows the same contract, so the tooling and your habits carry over.

1. **Copy `lab-01/`** to `lab-NN/` and edit the `LAB` hash in the Vagrantfile:
   - `host_octet`: `10 + NN`. The VM gets that address on Fusion's existing
     host-only network, so levels can run side by side. (Fusion on modern macOS
     can't create custom host-only subnets, so don't hard-code something like
     `192.168.56.x`.)
   - `hostname`: fits the story (`db-01`, `k8s-node-2`, ...)
   - `cpus` / `memory`: raise them for levels that need it (containers, performance)
   - extra disks: one entry each in `EXTRA_DISKS` (LVM levels will want
     several). Don't use `config.vm.disk`, which crashes with this box and plugin.
   - multi-VM levels: wrap the machines in `config.vm.define`
2. **Provisioning order** is always: upload helpers, then `common/provision/base.sh`,
   then `provision/setup.sh`, then `provision/break.sh`.
   - `setup.sh` builds a *working* system and **fails provisioning if its smoke
     test fails**, so every incident starts from a known-good baseline.
   - `break.sh` keeps its terminal output neutral (`vagrant up` prints it),
     writes `/var/lib/lab/provisioned`, and deletes itself.
   - Both scripts exit early if that marker exists.
3. **`check.sh`** sources `/usr/local/lib/lab/lab-common.sh` and checks
   **outcomes, not causes**: "site returns 200 from outside", not "port 80 is
   allowed in ufw". Add guard checks for bad fixes such as a disabled firewall,
   `chmod 777`, or running as root, and for persistence across reboots.
4. **Docs:** the level's `README.md` has a **"What you should know before you
   start"** section. It lists the background concepts a player needs, a short
   self-check, and the tools they *don't* need to know yet. Describe areas of
   knowledge, never the defects: "Linux file permissions" is fine, but "a
   config file the service can't read" gives the answer away. `TICKET.md`
   gives symptoms only. `HINTS.md` uses collapsed
   `<details>` blocks from vague to specific. `SOLUTIONS.md` covers the root
   cause, diagnosis, fix, what *not* to do, prevention, and the concepts to learn.
5. **Difficulty knobs** for later levels: fewer clues in the ticket, more
   interacting defects, red herrings in the logs, defects that only show up
   under load or after a reboot, and boot-level faults that need the VM console
   (`vmware.gui = true`).

Testing tip: `LAB_LOGVOL=loop` (lab-01) is a test hook that makes `setup.sh`
use a loop-file volume, so you can exercise the scripts in a privileged systemd
container without a spare disk.

## License

[MIT](LICENSE)
