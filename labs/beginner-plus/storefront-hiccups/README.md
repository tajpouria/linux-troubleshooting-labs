# It's slow, then it's not

**Level:** Beginner+ · **Time:** 60–120 minutes · **Host:** `web-03` at `<LAB_IP>`

`<LAB_IP>` is address `.13` on your computer's host-only network. On Windows
with VirtualBox that's `192.168.56.13`. On a Mac, Fusion's host-only network has
a different subnet on every machine (for example `172.16.129.13`).
`vagrant up` prints the address at the end.

Pinewood Books moved its storefront to web-03, and since the weekend customers
have been complaining. Every so often the shop freezes, then it's fast again.
Some customers can't add books to their cart, but it works for everyone in the
office. And nobody can check the app's own log, because it's empty. You're the
day-shift SRE.

This is the first lab where the problems **come and go**. When you look, things
may well look fine. You'll have to measure over time, notice *when* something
goes wrong, and connect that to what the server does on a schedule. Several
separate problems are involved, and the ticket gives fewer clues than in the
Beginner labs.

**You'll practise:** measuring a symptom over time with a `curl` loop,
correlating symptoms with the clock, cron and systemd timers
(`systemctl list-timers`, timer schedules), reading the journal, log rotation
with `logrotate`, file ownership and permissions, how a filesystem stores files
(space *and* inodes), and finding which file a process has open (`lsof`).

## What you should know before you start

This lab builds on the two Beginner labs. You don't need to be an expert in the
areas below. You need to know what each one *is*, so you know where to look.
The lab teaches the rest.

- **Shell basics.** Moving around the filesystem, reading files with `cat`,
  `less`, `tail` and `grep`, piping commands together, a simple `while` loop,
  and editing a root-owned file with `sudo` and an editor (`nano` or `vim`).
- **Files and permissions.** Reading `ls -l`: the owner, the group, and the
  `rwx` bits for the owner, the group and everyone else. Changing them with
  `chown` and `chmod`.
- **systemd services.** Starting, stopping, restarting and checking a unit with
  `systemctl`, and reading its log with `journalctl -u <unit>`. The
  [slow-storefront](../../beginner/slow-storefront/) lab covers unit files.
- **Scheduled jobs.** That Linux runs commands on a schedule with **cron**
  (crontabs, `/etc/cron.d`) or with **systemd timers**, and roughly what a
  crontab line looks like.
- **Log files.** That services write logs under `/var/log`, and that old logs
  are renamed and eventually deleted on a schedule, so they don't grow forever.
- **Filesystems.** What a mount point is, and checking free space with `df -h`.
- **HTTP and web servers.** Fetching a page with `curl`, sending a form with
  `curl -d`, and the idea of a reverse proxy (nginx passing requests to an app).
  The [storefront-down](../../beginner/storefront-down/) lab covers this.

**Quick self-check.** If you can answer these without looking anything up,
you're ready:

1. In `-rw-rw-r-- 1 sam sam 396 notes.txt`, who can change the file?
2. Where would you look to find every job that runs on a schedule on a server?
3. How would you load a page once a second for five minutes, and see which
   loads were slow and when?
4. A service ran from a timer at 03:00 and failed. How do you read what it
   printed?

You *don't* need to know `logrotate`, `systemd-analyze`, `lsof` or SQLite yet.
The hints introduce them when you need them.

## Start

Do the one-time setup for [macOS](../../../docs/setup-macos.md) or
[Windows](../../../docs/setup-windows.md) first. Then, from the repository root
(the commands are the same in Terminal and PowerShell):

```bash
cd labs/beginner-plus/storefront-hiccups
vagrant up                     # ~6 minutes the first time (downloads the box)
vagrant snapshot save broken   # reset point. Take it now, before you touch anything
vagrant ssh
```

Read the ticket in [TICKET.md](TICKET.md) (or run `cat /etc/lab/ticket.md` in the VM)
and start investigating.

## Rules of engagement

- Treat it like production. Fix root causes, not symptoms.
- Problems that come and go need patience. Watch for at least 10 minutes before
  you decide something is fine, and measure again after every change.
- Customers' carts are real orders in progress. Don't delete carts that are
  still in use.
- Marketing wants the Trending shelf and its 5-minute refresh. Don't switch the
  shelf or its job off.
- Don't fix a permission problem by opening things up to everyone.
- Your fix must survive a reboot and tonight's housekeeping. You can test a
  reboot with `sudo reboot`.
- Check your progress with `sudo lab-check`. Done means **7/7 PASS**.

## The checks

```text
 storefront-hiccups  It's slow, then it's not
 ------------------------------------------------------------
 [FAIL] 1. Pages load quickly, every time (no freezes)
 [FAIL] 2. New visitors can add books to their cart
 [FAIL] 3. Cart storage has room to spare, and expired carts are cleaned up
 [FAIL] 4. The storefront's log shows what's happening now
 [FAIL] 5. Web server logs are rotated
 [FAIL] 6. Fixes survive a reboot and tonight's housekeeping
 [PASS] 7. Nothing important was removed or weakened
```

Check 7 starts out passing. It's a guard that fails if your fix throws away
something that matters.

Check 1 doesn't wait for a freeze to happen by chance. It makes sure a freeze
*can't* happen, so it can fail while pages happen to be fast. lab-check can
take up to 10 seconds to run.

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
