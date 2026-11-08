# Lab 01: The storefront is down

**Difficulty:** Beginner · **Time:** 45–90 minutes · **Host:** `web-01` at `<LAB_IP>`

`<LAB_IP>` is address `.11` on Fusion's host-only network, which has a
different subnet on every Mac (for example `172.16.129.11`). `vagrant up` prints
it at the end.

Pinewood Books' online shop stopped working overnight, and you're the day-shift
SRE. Several separate problems interact, much like a real incident. Fixing one
can reveal the next.

**You'll practise:** reading `systemctl` and `journalctl`, disk usage (`df` vs
`du`), finding processes and the files they hold open, Linux file permissions,
nginx as a reverse proxy, ports and listening sockets, and the host firewall.

## Start

Do the [one-time setup](../docs/setup-macos.md) first, then:

```bash
cd lab-01
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
- One check needs a real request from your Mac: open `http://<LAB_IP>/` in
  your browser once you think the site works.

## The checks

```text
 lab-01  The storefront is down
 ------------------------------------------------------------
 [FAIL] 1. Backend application is running and healthy
 [FAIL] 2. Storefront loads through the web server (http://localhost/)
 [FAIL] 3. Storefront is reachable from outside the server
           Needs a successful page load from your Mac: open http://<LAB_IP>/ and re-run.
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
vagrant destroy -f && vagrant up                  # full rebuild
vagrant destroy -f                                # remove the lab completely
```

See the [lab lifecycle](../README.md#lab-lifecycle) for suspend/resume and
other commands.

## What's in this folder

| File | Purpose | Spoilers? |
|---|---|---|
| `Vagrantfile` | VM: Ubuntu 24.04 ARM64, 2 vCPU, 2 GB RAM, private IP, extra 1 GB disk | no |
| `TICKET.md` | the incident ticket | no |
| `HINTS.md` | progressive hints | collapsed |
| `check.sh` | becomes `lab-check` in the VM | source only |
| `provision/setup.sh` | builds the healthy system | mostly no |
| `provision/break.sh` | injects the incident | **yes** |
| `SOLUTIONS.md` | full write-up | **yes** |
