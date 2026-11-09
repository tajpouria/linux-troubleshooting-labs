# Linux Troubleshooting Labs

Progressive, hands-on SRE incident labs. Each lab gives you a Linux server
that's broken in realistic ways, plus an incident ticket that describes only the
symptoms. Your job is to find the root causes, fix them properly, and prove it
with an automated check.

- **Format:** one folder per lab under `labs/<level>/`. Run `vagrant up`,
  troubleshoot, then run `sudo lab-check`.
- **Guest:** Ubuntu 24.04 LTS (`bento/ubuntu-24.04`)

## Supported setups

| Your computer | Hypervisor | Guest architecture | One-time setup |
|---|---|---|---|
| macOS on Apple Silicon | VMware Fusion | ARM64 | [docs/setup-macos.md](docs/setup-macos.md) |
| Windows 10 or 11 (x86-64) | VirtualBox | x86-64 | [docs/setup-windows.md](docs/setup-windows.md) |

The labs pick the hypervisor from your operating system. Other combinations,
such as VirtualBox on a Mac or VMware on Windows, aren't supported, and
`vagrant up` stops with a message saying so.

## Levels

Labs are grouped by level instead of being numbered, so a new lab can go
anywhere without renumbering the others. Within a level, the list below is the
suggested order.

| Level | What to expect |
|---|---|
| **Beginner** | One server and loud symptoms. The ticket points you in the right direction, the problems are independent, and each check maps to one outcome. Assumes Linux command-line basics. |
| **Beginner+** | Problems that come and go, or only show up on a schedule. Fewer clues in the ticket. |
| **Intermediate** | Networking and resource limits beyond a single service. Defects that interact, and red herrings in the logs. |
| **Intermediate+** | Storage and boot configuration, where a careless fix can take the whole server down. |
| **Advanced** | Faults that need the VM console, kernel-level tools, or reasoning about behaviour under load. |
| **Expert** | Several VMs, and incidents that combine everything above. |

## Labs

### Beginner

| Lab | Scenario | Skills |
|---|---|---|
| [storefront-down](labs/beginner/storefront-down/) | The storefront is down | disk space, systemd services, logs and journald, file permissions, processes, ports and host firewall |
| [slow-storefront](labs/beginner/slow-storefront/) | The storefront is crawling | measuring latency, load average and `top`, process trees, process priority (`nice`), systemd drop-ins and CPU limits, `free` vs `available`, cron |

### Beginner+

| Lab | Scenario | Skills |
|---|---|---|
| *planned* | "It's slow, then it's not" | DNS resolution, cron and systemd timers, log rotation, inode exhaustion, time sync |

### Intermediate

| Lab | Scenario | Skills |
|---|---|---|
| *planned* | "Can't connect" | routing, MTU, nftables, TLS certificate expiry, ephemeral ports, conntrack |
| *planned* | "Something keeps killing it" | memory pressure, the OOM killer, swap, cgroup memory limits, leaks |
| *planned* | "Too many open files" | kernel parameters (`sysctl`), ulimits, `somaxconn`, `file-max`, backlog drops |

### Intermediate+

| Lab | Scenario | Skills |
|---|---|---|
| *planned* | "Disk trouble" | LVM (extend, migrate, snapshots), fstab, read-only remounts, `fsck` |

### Advanced

| Lab | Scenario | Skills |
|---|---|---|
| *planned* | "It won't boot" | emergency mode, broken fstab, GRUB and kernel command line, initramfs, systemd targets |
| *planned* | "Everything is slow" | load vs CPU, iowait, `perf`, `strace`, slow disks (`dm-delay`), noisy neighbours |
| *planned* | "The container keeps dying" | containers, cgroups v2, namespaces, overlayfs, container OOM, bridge networking and NAT |

### Expert

| Lab | Scenario | Skills |
|---|---|---|
| *planned* | Capstone | a multi-VM incident that combines everything above |

## Getting started

1. **One-time setup.** Follow the guide for your computer:
   [macOS](docs/setup-macos.md) (VMware Fusion) or
   [Windows](docs/setup-windows.md) (VirtualBox).
2. **Check you're ready.** Each lab's README begins with *What you should know
   before you start*: the concepts it assumes and a short self-check. It
   contains no spoilers.
3. **Start a lab.** The commands are the same in macOS Terminal and Windows
   PowerShell:

   ```bash
   cd labs/beginner/storefront-down
   vagrant up                     # builds the server, then breaks it (~5 min)
   vagrant snapshot save broken   # your reset point. Do this right away!
   vagrant ssh
   cat /etc/lab/ticket.md         # the incident ticket (also in the lab's TICKET.md)
   ```

4. **Troubleshoot** inside the VM (you have `sudo`). Check your progress at any
   time:

   ```bash
   sudo lab-check                     # inside the VM
   vagrant ssh -c "sudo lab-check"    # or from your computer
   ```

   Each check prints PASS or FAIL. It tells you *what* is still wrong from the
   user's point of view, never *why*.

5. **Stuck?** Open the lab's `HINTS.md`. Every issue has hints that go from
   vague to specific. **Done?** Write your post-incident note, then compare it
   with `SOLUTIONS.md`.

> **Windows tip:** in PowerShell, `curl` is a different command. Type `curl.exe`
> when a lab asks you to run `curl` on your computer (inside the VM, `curl` is
> fine).

## Lab lifecycle

All commands run on your computer, from inside the lab's folder (for example
`labs/beginner/storefront-down`).

| Goal | Command |
|---|---|
| Build the lab and inject the incident | `vagrant up` |
| Save a reset point (right after the first `up`) | `vagrant snapshot save broken` |
| Open a shell | `vagrant ssh` |
| Check progress | `vagrant ssh -c "sudo lab-check"` |
| **Reset** to the freshly broken state (fast) | `vagrant snapshot restore --no-provision broken` |
| **Reset** by rebuilding from scratch (slow, always works) | `vagrant destroy -f`, then `vagrant up` |
| Pause and resume (keeps the exact running state) | `vagrant suspend` / `vagrant resume` |
| List snapshots | `vagrant snapshot list` |
| Power off | `vagrant halt` (see the note below) |
| **Tear down** (deletes the VM, its disks and snapshots) | `vagrant destroy -f` |
| Free the base box too (when you're done with all labs) | `vagrant box remove bento/ubuntu-24.04 --all` |
| Find VMs you forgot about | `vagrant global-status --prune` |

> **Suspend, don't halt.** Some incidents live partly in memory, such as a
> process holding a deleted file open. A reboot can make a problem *look* fixed
> or change its shape, just like in production. Use `suspend`/`resume` for
> breaks and snapshots for resets. Rebooting on purpose to test that your fix
> survives is a good idea, though.

> **Don't run `vagrant provision`** on a lab you've started. The provisioners
> notice that the lab is already set up and refuse, so they don't half-reset
> it. Use a snapshot restore or destroy/up instead.

### Optional switches

Set these before `vagrant up` or `vagrant reload`:

| Variable | Effect |
|---|---|
| `LAB_GUI=1` | Opens the VM's console window. Useful if boot hangs, or if you lock yourself out of SSH. |
| `LAB_PORT_FORWARD=1` | Also forwards the lab's web port to `http://localhost:<8000 + host octet>/`, for example `http://localhost:8011/` for storefront-down. A fallback for when the host-only network doesn't work. |

```bash
LAB_GUI=1 vagrant reload                     # macOS Terminal
```

```powershell
$env:LAB_GUI = "1"; vagrant reload           # Windows PowerShell
Remove-Item Env:LAB_GUI                      # turn it off again for this window
```

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
│   ├── setup-macos.md           one-time setup: Apple Silicon Mac + VMware Fusion
│   └── setup-windows.md         one-time setup: Windows + VirtualBox
├── common/                      shared by every lab
│   ├── vagrant/lab.rb           the VM plumbing: box, hypervisor, network, disks, provisioning
│   ├── lib/lab-common.sh        PASS/FAIL helpers for check scripts (-> /usr/local/lib/lab/)
│   └── provision/base.sh        architecture guard, toolbox, lab-check, login banner
└── labs/
    └── <level>/                 beginner, beginner-plus, intermediate, ...
        └── <lab>/               e.g. labs/beginner/storefront-down
            ├── Vagrantfile      the lab's settings: name, hostname, size, address
            ├── TICKET.md        the incident, symptoms only
            ├── HINTS.md         progressive hints per issue
            ├── SOLUTIONS.md     root causes, fixes, concepts (spoilers)
            ├── check.sh         installed in the VM as `lab-check`
            └── provision/
                ├── setup.sh     builds the healthy baseline and smoke-tests it
                └── break.sh     injects the incident (spoilers)
```

## Adding a new lab

Every lab follows the same contract, so the tooling and your habits carry over.

1. **Pick a level and a name.** The lab lives in `labs/<level>/<name>/`, with
   the level folders `beginner`, `beginner-plus`, `intermediate`,
   `intermediate-plus`, `advanced` and `expert`. The name is short kebab-case
   and describes the scenario as the *user* sees it (`slow-storefront`), never
   the cause (`deleted-open-file` would give the answer away). The folder name
   is the lab's ID.
2. **Copy a lab** from the same level and edit the `Lab.define` call in its
   Vagrantfile (see the top of [common/vagrant/lab.rb](common/vagrant/lab.rb)
   for every option):
   - `id`, `level`, `title`, `hostname` (fits the story: `db-01`, `k8s-node-2`, ...)
   - `host_octet`: a number no other lab uses, so labs can run side by side
     (`grep -rn host_octet labs/` lists the ones taken). The VM gets that
     address on the host-only network: `192.168.56.<octet>` on VirtualBox, and
     the same octet on Fusion's existing host-only network on a Mac. (Fusion
     on modern macOS can't create custom host-only subnets, so don't hard-code
     an address.)
   - `cpus` / `memory`: raise them for labs that need it (containers, performance)
   - `extra_disks`: blank disks for storage labs. They're attached on VMware
     Fusion only, so `setup.sh` must also work without them on VirtualBox (the
     storefront-down lab falls back to a loop-file volume).
   - multi-VM labs: extend `lab.rb` with `config.vm.define` when the first one arrives.
3. **List it in this README** under its level, at the position you suggest
   playing it. That's all it takes to insert a lab between two others.
4. **Provisioning order** is always: upload helpers, then `common/provision/base.sh`,
   then `provision/setup.sh`, then `provision/break.sh`.
   - `setup.sh` builds a *working* system and **fails provisioning if its smoke
     test fails**, so every incident starts from a known-good baseline.
   - `break.sh` keeps its terminal output neutral (`vagrant up` prints it),
     writes `/var/lib/lab/provisioned`, and deletes itself.
   - Both scripts exit early if that marker exists.
   - Scripts must work on both ARM64 and x86-64 guests, and must not assume
     device or network interface names, which differ between hypervisors.
5. **`check.sh`** sources `/usr/local/lib/lab/lab-common.sh` and checks
   **outcomes, not causes**: "site returns 200 from outside", not "port 80 is
   allowed in ufw". Add guard checks for bad fixes such as a disabled firewall,
   `chmod 777`, or running as root, and for persistence across reboots. For
   checks that depend on speed, measure a baseline in `setup.sh` and compare
   with it (see slow-storefront), because host computers vary a lot.
6. **Docs:** the lab's `README.md` has a **"What you should know before you
   start"** section. It lists the background concepts a player needs, a short
   self-check, and the tools they *don't* need to know yet. Describe areas of
   knowledge, never the defects: "Linux file permissions" is fine, but "a
   config file the service can't read" gives the answer away. `TICKET.md`
   gives symptoms only. `HINTS.md` uses collapsed `<details>` blocks from vague
   to specific. `SOLUTIONS.md` covers the root cause, diagnosis, fix, what
   *not* to do, prevention, and the concepts to learn.
7. **Difficulty knobs** for higher levels: fewer clues in the ticket, more
   interacting defects, red herrings in the logs, defects that only show up
   under load or after a reboot, and boot-level faults that need the VM console
   (`LAB_GUI=1`).

**Testing without a VM.** The provisioning scripts also run in a privileged
Ubuntu 24.04 container with systemd as PID 1. Copy the repo in, put
`lab-common.sh`, `check.sh` and `TICKET.md` where the file provisioners would
(`/tmp/lab-common.sh`, `/tmp/lab-check`, `/tmp/lab-ticket.md`), run `base.sh`
with the `LAB_*` variables, then `setup.sh` and `break.sh`, then `lab-check`.
`LAB_LOGVOL=loop` makes storefront-down's `setup.sh` use a loop-file volume, and
slow-storefront expects 2 CPUs (`docker run --cpuset-cpus=0,1`).

## License

[MIT](LICENSE)
