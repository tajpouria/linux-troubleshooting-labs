# Hints: The storefront is down

Use these only when you're stuck. Each issue has numbered hints that go from
vague to specific. Open one, then go back and try again before opening the
next. The last hint for each issue is close to the answer.

The section titles describe **symptoms you'll see**, not causes, so it's safe to
scroll. Hints stay collapsed until you click them. (They render as collapsible
blocks on GitHub and in most Markdown previewers. In a plain text editor,
everything is visible.)

## Before you start: a method (no spoilers)

1. **Reproduce it yourself, from where the users are.** On your computer (the
   host, not the VM): `curl -v --max-time 5 http://<LAB_IP>/`. In Windows
   PowerShell, type `curl.exe`, because plain `curl` there is a different command.
2. **Work inward, one layer at a time:** network, then web server, then app,
   then the things the app depends on (config, disk, other services).
3. **At every layer, ask the same three questions.** Is it running? Is it
   listening? What do its logs say?
4. **Change one thing at a time** and re-test after each change.
5. Run `sudo lab-check` often. Each check tells you which outcome is still
   missing.

Commands worth knowing for this level: `systemctl`, `journalctl`, `ss`, `curl`,
`df`, `du`, `lsof`, `ps`, `ls -l`, `namei`, `ufw`, `nginx -t`.

### Which hints do I need?

| What you're seeing | lab-check item | Go to |
|---|---|---|
| Page times out from your computer, but `curl` inside the VM gets *some* answer | 3 | [Issue A](#issue-a-it-times-out-from-my-computer) |
| `bookshop` service is failed or won't stay up | 1 | [Issue B](#issue-b-the-backend-service-wont-start), then [Issue C](#issue-c-the-backend-complains-about-space) |
| Errors mention space, or `df` and `du` disagree | 1, 4 | [Issue C](#issue-c-the-backend-complains-about-space) |
| `curl http://localhost/` inside the VM gives a 502 | 2 | [Issue D](#issue-d-502-bad-gateway-from-inside-the-server) |
| "Fixes survive a reboot" fails | 5 | [Guard checks](#guard-checks-5-and-6) |
| "No security regressions" fails | 6 | [Guard checks](#guard-checks-5-and-6) |

---

## Issue A: it times out from my computer

<details><summary>Hint A1</summary>

Compare two vantage points. What happens with `curl -v http://localhost/`
*inside* the VM, and with `curl -v --max-time 5 http://<LAB_IP>/` *on your
computer*? If they behave differently, the problem is somewhere between your
computer and the web server process.

</details>

<details><summary>Hint A2</summary>

A **timeout** and a **"connection refused"** mean different things. Refused
means the packet arrived and nothing was listening on that port. A timeout
usually means the packet was silently dropped. Check what's listening and on
which addresses: `sudo ss -tlnp`. Is the web server bound to all interfaces or
only to localhost?

</details>

<details><summary>Hint A3</summary>

If something is listening on `0.0.0.0:80` but packets from outside still vanish,
look at the server's own packet filter. Try `sudo ufw status verbose`, and look for
dropped packets in the kernel log right after you retry from your computer:
`sudo journalctl -k --since "-5min" | grep -i block`.

</details>

<details><summary>Hint A4 (nearly the answer)</summary>

The host firewall is on with a default-deny policy for incoming traffic, and
only SSH is allowed. Add an allow rule for HTTP (port 80/tcp) using the same
tool. **Don't** turn the firewall off. That would fail check 6.

</details>

---

## Issue B: the backend service won't start

<details><summary>Hint B1</summary>

nginx is only the front door. What does it forward to, and is that thing
running? `systemctl list-units --failed` is a quick way to see what's unhappy.

</details>

<details><summary>Hint B2</summary>

`systemctl status bookshop` tells you *that* it failed. The journal tells you
*why*: `sudo journalctl -u bookshop -n 50 --no-pager`. With a Python
traceback, the most useful line is usually the **last** one.

</details>

<details><summary>Hint B3</summary>

The error names a file. Who owns it, and what are its permission bits
(`ls -l`, `stat`)? Which user does the service run as
(`systemctl show -p User bookshop`)? Test access as that user:
`sudo -u bookshop cat /path/to/file`. `namei -l /path/to/file` shows the
permissions of every directory along the path.

</details>

<details><summary>Hint B4 (nearly the answer)</summary>

The config file is now `root:root` with mode `0600`, but the service runs as
`bookshop`. Give the service's **group** read access and keep everyone else out.
The file contains a secret, so world-readable isn't acceptable. Then
`sudo systemctl restart bookshop`. If systemd says "start request repeated too
quickly", read up on `systemctl reset-failed`.

</details>

---

## Issue C: the backend complains about space

<details><summary>Hint C1</summary>

Read the new error message carefully. Which path does it mention, and which
filesystem is that path on? Try `df -h`, and note that `/var/log/bookshop` is its
own volume.

</details>

<details><summary>Hint C2</summary>

`df` says the volume is full, but `sudo du -sh /var/log/bookshop/*` finds almost
nothing. Both tools are telling the truth. `du` counts files it can *see* in
directories, and `df` counts blocks that are *allocated*. When does a file
still use blocks after it no longer appears in any directory? Remember the
night on-call's note in the ticket.

</details>

<details><summary>Hint C3</summary>

A deleted file's space is only freed when the last process holding it open
closes it. List open files that have no name left: `sudo lsof +L1`. (No lsof?
Try `sudo find /proc/*/fd -lname '*(deleted)' -ls 2>/dev/null`.) Which process
is it? `ps -fp <PID>` shows the full command line.

</details>

<details><summary>Hint C4</summary>

You killed the process and it came straight back with a new PID? Something is
restarting it. Find out what owns it: `systemctl status <PID>` works with a PID.
Read that unit's description and its `Restart=` setting.

</details>

<details><summary>Hint C5 (nearly the answer)</summary>

A "temporary" debug tracer unit was left enabled with `Restart=always`. Stop it
**and** stop it from starting at boot, all in one command:
`systemctl disable --now <unit>`. Once its process exits, the space comes back.
If it had already re-created its log file, delete that too. Then restart the
backend.

</details>

---

## Issue D: 502 Bad Gateway from inside the server

<details><summary>Hint D1</summary>

A 502 comes from nginx. It means "I'm fine, but the thing I forward to didn't
answer properly". Is the backend running? If not, see Issue B first. If it *is*
running, why can't nginx reach it?

</details>

<details><summary>Hint D2</summary>

nginx writes down exactly what it tried: `sudo tail -n 20 /var/log/nginx/error.log`.
Look at the `upstream:` field. Now compare it with what's actually listening:
`sudo ss -tlnp`.

</details>

<details><summary>Hint D3</summary>

The site file in `/etc/nginx/sites-enabled/` refers to the upstream by **name**.
The name is defined in another file. `sudo nginx -T` prints the full,
merged config that nginx is really using, so you can search it for `upstream`.

</details>

<details><summary>Hint D4 (nearly the answer)</summary>

The upstream points at `127.0.0.1:8081`, but the backend listens on the port set
in `/etc/bookshop/bookshop.conf`. Make them agree (fixing nginx is the smaller
change), then run `sudo nginx -t && sudo systemctl reload nginx`.

</details>

---

## Guard checks (5 and 6)

These two start out *passing* or close to it. They're there to catch fixes
that work today but cause trouble tomorrow.

<details><summary>Hint G1: "Fixes survive a reboot" fails</summary>

Something you fixed only in the *running* system will come back after a reboot.
`systemctl start/stop` changes now, and `systemctl enable/disable` changes boot.
Firewall rules added with `ufw` are saved, and rules added with raw
`iptables`/`nft` are not. Try `systemctl list-unit-files --state=enabled | grep -i book`.

</details>

<details><summary>Hint G2: "No security regressions introduced" fails</summary>

Did you get things working by turning the firewall off, setting the default
incoming policy to allow, making the config file readable by everyone, or
running the service as root? Each of those would be called out in a
post-incident review. Undo it and use the narrower fix.

</details>
