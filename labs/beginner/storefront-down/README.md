# The storefront is down

**Level:** Beginner · **Time:** 45–90 minutes · **Host:** `web-01` at `<LAB_IP>`

`<LAB_IP>` is address `.11` on your computer's host-only network. On Windows
with VirtualBox that's `192.168.56.11`. On a Mac, Fusion's host-only network has
a different subnet on every machine (for example `172.16.129.11`).
`vagrant up` prints the address at the end.

Pinewood Books' online shop stopped working overnight, and you're the day-shift
SRE. Several separate problems interact, much like a real incident. Fixing one
can reveal the next.

**You'll practise:** reading `systemctl` and `journalctl`, disk usage (`df` vs
`du`), finding processes and the files they hold open, Linux file permissions,
nginx as a reverse proxy, ports and listening sockets, and the host firewall.

## What you should know before you start

This is a beginner level, but it assumes you're comfortable on a Linux command
line. You don't need to be an expert in any of the areas below. You need to know
what each one *is*, so you know where to look. The lab teaches the rest.

- **Shell basics.** Moving around the filesystem, reading files with `cat`,
  `less`, `tail` and `grep`, piping commands together, and editing a root-owned
  file with `sudo` and an editor (`nano` or `vim`).
- **Users, groups and permissions.** Reading `ls -l` output: owner, group, and
  the `rwx` bits for owner, group and others. What `chmod` and `chown` do, and
  why services usually run as their own unprivileged user instead of root.
- **Processes.** What a process and a PID are, listing them with `ps` or `top`,
  and stopping one with `kill`.
- **systemd services.** That background programs run as *units*, and how to
  start, stop, restart and check the status of one with `systemctl`. That
  services write their logs to the systemd journal.
- **Disks and mounts.** What a mount point is, that a directory can live on its
  own volume with its own free space, and how to read the output of `df -h`.
- **Networking basics.** IP addresses and ports, what it means for a program
  to *listen* on a port, the difference between `localhost` and the server's
  network address, and what a host firewall does in general.
- **HTTP and web servers.** Fetching a page with `curl`, the HTTP status code
  families (2xx, 4xx, 5xx), and the idea of a *reverse proxy*: a web server
  that takes requests on port 80 and passes them to an application running on
  another port.

**Quick self-check.** If you can answer these without looking anything up,
you're ready:

1. A file is listed as `-rw-r----- 1 root adm`. Who can read it, and who can
   change it?
2. How do you see whether a systemd service is running, and how do you see its
   most recent log lines?
3. A program "listens on `127.0.0.1:5000`". Can another machine connect to it?
4. What's the difference between an HTTP 404 and an HTTP 503?


## Start

Do the one-time setup for [macOS](../../../docs/setup-macos.md) or
[Windows](../../../docs/setup-windows.md) first. Then, from the repository root
(the commands are the same in Terminal and PowerShell):

```bash
cd labs/beginner/storefront-down
vagrant up                     # ~5 minutes the first time (downloads the box)
vagrant snapshot save broken   # reset point. Take it now, before you touch anything
vagrant ssh
```

Read the ticket in [TICKET.md](TICKET.md) (or run `cat /etc/lab/ticket.md` in the VM)
and start investigating.

## Rules of engagement

- Treat it like production. Fix root causes, not symptoms.
- Don't disable security controls to make things work.
- Your fix must survive a reboot. You can test that with `sudo reboot`.
- Check your progress with `sudo lab-check`. Done means **6/6 PASS**.
- One check needs a real request from your computer: open `http://<LAB_IP>/`
  in your browser once you think the site works.

## The checks

```text
 storefront-down  The storefront is down
 ------------------------------------------------------------
 [FAIL] 1. Backend application is running and healthy
 [FAIL] 2. Storefront loads through the web server (http://localhost/)
 [FAIL] 3. Storefront is reachable from outside the server
           Needs a successful page load from your computer: open http://<LAB_IP>/ and re-run.
 [FAIL] 4. Log storage has healthy free space and is stable
 [FAIL] 5. Fixes survive a reboot
 [PASS] 6. No security regressions introduced
```

Check 6 starts out passing. It's a guard that fails if your fix weakens
security.

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
| `Vagrantfile` | VM: Ubuntu 24.04, 2 vCPU, 2 GB RAM, private IP, 1 GB log volume (an extra disk on VMware Fusion, a loop file on VirtualBox) | no |
| `TICKET.md` | the incident ticket | no |
| `HINTS.md` | progressive hints | collapsed |
| `check.sh` | becomes `lab-check` in the VM | source only |
| `provision/setup.sh` | builds the healthy system | mostly no |
| `provision/break.sh` | injects the incident | **yes** |
| `SOLUTIONS.md` | full write-up | **yes** |
