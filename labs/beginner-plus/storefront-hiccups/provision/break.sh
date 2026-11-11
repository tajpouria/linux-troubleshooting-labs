#!/usr/bin/env bash
#
#  ███  SPOILER WARNING  ███
#  This script injects the storefront-hiccups defects. Don't read it until you've
#  solved the lab (or given up and read SOLUTIONS.md).
#
# It replays the last three weeks on web-03:
#   1. CHG-0496, 3 weeks ago: the hourly expired-cart cleanup was changed to run
#      every 30 minutes, but written in cron syntax (OnCalendar=*/30 * * * *).
#      systemd can't parse that, so the timer has never fired since. Carts piled
#      up until the cart volume ran out of inodes, with plenty of space left:
#      new visitors can't get a cart, but returning visitors (and staff) can.
#   2. CHG-0507, 2 weeks ago: Sam edited a copy of nginx's logrotate file in
#      their home directory and `sudo mv`'d it into place. mv kept Sam as the
#      owner and mode 0664, so logrotate ignores the file, and nginx's logs
#      haven't rotated since. The Trending job (cron, every 5 minutes) reads
#      the whole access log inside an exclusive database lock. It now takes
#      ~15 s, and every page that touches the database freezes meanwhile.
#   3. CHG-0519, yesterday: the storefront's logrotate file was replaced with a
#      copy of nginx's, so after rotating it reloads nginx instead of the app.
#      Last night's rotation left the app writing to app.log.1.
#   Red herring: vulnerability scanners in the access log (/wp-login.php, /.env).
#
# Output is kept neutral on purpose, because `vagrant up` prints it on your
# terminal. The script deletes itself when it's done.

set -Eeuo pipefail

MARKER=/var/lib/lab/provisioned
if [[ -e $MARKER ]]; then
  echo "==> [break] The incident is already injected; not touching it."
  exit 0
fi

# Keep the host terminal spoiler-free, but surface errors if something breaks.
ERR_FILE=$(mktemp /run/lab-break.XXXXXX)
WORK=$(mktemp -d /run/lab-break-work.XXXXXX)
exec 3>&1 4>&2 1>/dev/null 2>"$ERR_FILE"
trap 'echo "ERROR: break.sh failed at line $LINENO:" >&4; cat "$ERR_FILE" >&4; rm -rf "$ERR_FILE" "$WORK"' ERR
say() { printf '==> [break] %s\n' "$*" >&3; }

SESSION_DIR=/var/lib/storefront/sessions
NGINX_LOGS=/var/log/nginx
APP_LOGS=/var/log/storefront
STORE=http://127.0.0.1
FREEZE_SECONDS=15 # how long the Trending job should take on this VM, once broken
DAY=86400
NOW=$(date +%s)
TODAY0=$((NOW - NOW % DAY))           # midnight UTC today
LAST_ROTATION=$((TODAY0 - 15 * DAY))  # nginx's logs last rotated at this midnight
CHG0507=$((LAST_ROTATION + 14 * 3600)) # that afternoon: Sam's change, and the Trending shelf launch
chmod 0755 "$WORK"

say "Replaying the last three weeks on web-03..."

# Nothing scheduled runs while history is rewritten. (On a fresh VM,
# logrotate.timer is Persistent=true, so a catch-up run may be in progress.)
systemctl stop cron logrotate.timer
for _ in $(seq 1 120); do
  [[ $(systemctl show -p ActiveState --value logrotate.service) == activating ]] || break
  sleep 1
done

# --- Defect 1: the expired-cart cleanup never runs, and carts pile up ---------------
cat >/etc/systemd/system/storefront-session-gc.timer <<'EOF'
[Unit]
Description=Remove expired shopping carts every 30 minutes

[Timer]
# CHG-0496: holiday traffic, so clean up twice an hour instead of hourly.
OnCalendar=*/30 * * * *

[Install]
WantedBy=timers.target
EOF
touch -d "@$((NOW - 21 * DAY))" /etc/systemd/system/storefront-session-gc.timer
systemctl daemon-reload
[[ $(systemctl show -p LoadState --value storefront-session-gc.timer) == bad-setting ]]

# Three weeks of carts: 9000 from the last 6 days, then older ones (8.5 to 21
# days, so the 7-day cleanup would have removed them) until the volume runs out
# of inodes. 50 recent carts are recorded so lab-check can tell whether
# customers' active carts were kept.
python3 - "$SESSION_DIR" 9000 /var/lib/lab/active-carts.list "$WORK/returning" <<'PY'
import errno, json, os, pwd, random, sys, time
d, n_recent, sample_path, returning_path = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
pw = pwd.getpwnam("storefront")
rng = random.Random(496)
now = time.time()
day = 86400
made, sample, returning = 0, [], []
try:
    while True:
        recent = made < n_recent
        age = rng.uniform(0.05, 6) * day if recent else rng.uniform(8.5, 21) * day
        sid = rng.getrandbits(128).to_bytes(16, "big").hex()
        n_items = rng.choice([0, 1, 1, 1, 2, 2, 3])
        items = {}
        for _ in range(n_items):
            book = str(rng.randint(1, 12))
            items[book] = items.get(book, 0) + 1
        updated = int(now - age)
        body = json.dumps({"items": items, "created": updated - rng.randint(60, 3600), "updated": updated})
        path = f"{d}/sess_{sid}"
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(body)
        os.chown(path, pw.pw_uid, pw.pw_gid)
        os.utime(path, (updated, updated))
        made += 1
        if recent and 1 * day <= age <= 3 * day and len(sample) < 50:
            sample.append(f"sess_{sid} {updated}")
        elif recent and age <= 1 * day and items and len(returning) < 5:
            returning.append(sid)
except OSError as exc:
    if exc.errno != errno.ENOSPC:
        raise
with open(sample_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(sample) + "\n")
with open(returning_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(returning) + "\n")
print(made)
PY
chmod 0600 /var/lib/lab/active-carts.list
[[ $(df --output=iavail "$SESSION_DIR" | tail -n 1 | tr -d ' ') == 0 ]]

# --- Defect 3 (yesterday): the storefront's log rotation, copied from nginx's -------
cat >/etc/logrotate.d/storefront <<'EOF'
/var/log/storefront/*.log {
	daily
	missingok
	rotate 14
	compress
	delaycompress
	notifempty
	create 0640 storefront adm
	sharedscripts
	prerotate
		if [ -d /etc/logrotate.d/httpd-prerotate ]; then \
			run-parts /etc/logrotate.d/httpd-prerotate; \
		fi \
	endscript
	postrotate
		invoke-rc.d nginx rotate >/dev/null 2>&1
	endscript
}
EOF
chmod 0644 /etc/logrotate.d/storefront
touch -d "@$((TODAY0 - DAY + 15 * 3600))" /etc/logrotate.d/storefront

# --- Defect 2: nginx's logrotate file, edited in a home directory and mv'd in ------
# Sam's shell had umask 002, so the new file was rw-rw-r--, owned by sam.
runuser -u sam -- /bin/sh -c '
  umask 002
  cat /etc/logrotate.d/nginx >~/nginx.logrotate
  sed -i -e "s/^\trotate 14$/\trotate 30/" \
    -e "1i # CHG-0507: keep 30 days of access logs for the Trending analysis." ~/nginx.logrotate'
grep -q 'rotate 30' /home/sam/nginx.logrotate
mv /home/sam/nginx.logrotate /etc/logrotate.d/nginx
touch -d "@$CHG0507" /etc/logrotate.d/nginx
[[ $(stat -c '%U %a' /etc/logrotate.d/nginx) == "sam 664" ]]

cat >/home/sam/.bash_history <<'EOF'
cd ~
cat /etc/logrotate.d/nginx > nginx.logrotate
vim nginx.logrotate
diff /etc/logrotate.d/nginx nginx.logrotate
sudo mv nginx.logrotate /etc/logrotate.d/nginx
ls /etc/logrotate.d/
sudo -u storefront /usr/local/bin/storefront-trending
sudo tail -n 3 /var/log/storefront/trending.log
curl -s localhost | grep -A3 Trending
exit
EOF
chown sam:sam /home/sam/.bash_history
chmod 0600 /home/sam/.bash_history
touch -d "@$((CHG0507 + 1800))" /home/sam/.bash_history

# --- logrotate's memory: nginx's logs last rotated 15 days ago; the storefront's
#     at their last weekly rotation, 6 days ago (so last night's run rotates them)
python3 - "$LAST_ROTATION" "$((TODAY0 - 6 * DAY))" <<'PY'
import os, sys, time
nginx_at, store_at = int(sys.argv[1]), int(sys.argv[2])
path = "/var/lib/logrotate/status"
stamp = lambda t: time.strftime("%Y-%m-%d-%H:%M:%S", time.gmtime(t))
want = {
    "/var/log/nginx/access.log": nginx_at, "/var/log/nginx/error.log": nginx_at,
    "/var/log/storefront/app.log": store_at, "/var/log/storefront/trending.log": store_at,
}
lines = []
if os.path.exists(path):
    with open(path, encoding="utf-8") as fh:
        lines = [l.rstrip("\n") for l in fh if l.strip()]
if not lines or not lines[0].startswith("logrotate state"):
    lines.insert(0, "logrotate state -- version 2")
lines = [l for l in lines if not any(l.startswith(f'"{p}"') for p in want)]
lines += [f'"{p}" {stamp(t)}' for p, t in want.items()]
with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
os.chmod(path, 0o640)  # what logrotate itself uses
PY

# --- Two weeks of web traffic that was never rotated ----------------------------------
cat >"$WORK/traffic.py" <<'PY'
"""Write synthetic nginx access logs in the storefront's "timed" format.

traffic.py sample <file> <lines>
traffic.py history <dir> <lines> <trending lines/s> <last rotation> <chg0507> <now>
"""
import gzip, os, random, sys, time

DAY = 86400
rng = random.Random(507)
BOOK_WEIGHTS = [9, 4, 7, 3, 5, 4, 8, 3, 2, 2, 3, 6]
BROWSERS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.1 Safari/605.1.15",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 19_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
    "Mozilla/5.0 (X11; Linux x86_64; rv:144.0) Gecko/20100101 Firefox/144.0",
    "Mozilla/5.0 (Linux; Android 16; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Mobile Safari/537.36",
]
CRAWLERS = [
    "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
    "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)",
]
SCANNERS = [("203.0.113.66", "Mozilla/5.0 zgrab/0.x"), ("198.51.100.201", "python-requests/2.32.3"),
            ("192.0.2.144", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/96.0 Safari/537.36")]
PROBES = ["/wp-login.php", "/xmlrpc.php", "/.env", "/.git/config", "/wp-admin/setup-config.php",
          "/phpmyadmin/index.php", "/admin.php", "/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php",
          "/.aws/credentials", "/cgi-bin/luci"]
MONITOR = ("192.0.2.10", "uptime-monitor/2.1 (+https://status.pinewood.example)")
_stamp = [None, None]


def stamp(t):
    sec = int(t)
    if _stamp[0] != sec:
        _stamp[0], _stamp[1] = sec, time.strftime("%d/%b/%Y:%H:%M:%S +0000", time.gmtime(sec))
    return _stamp[1]


def customer():
    return f"{rng.choice(('198.51.100', '203.0.113', '192.0.2'))}.{rng.randint(11, 250)}"


def request(t, now):
    """One request: (ip, method, path, status, bytes, agent, touches_db)."""
    roll = rng.random()
    book = rng.choices(range(1, 13), BOOK_WEIGHTS)[0]
    if roll < 0.50:
        return customer(), "GET", f"/book/{book}", 200, rng.randint(2150, 2350), rng.choice(BROWSERS), True
    if roll < 0.70:
        return customer(), "GET", "/", 200, rng.randint(3700, 4100), rng.choice(BROWSERS), True
    if roll < 0.76:
        failing = t > now - 2.5 * DAY and rng.random() < 0.6  # new visitors since the weekend
        status, size = (500, 512) if failing else (303, 88)
        return customer(), "POST", "/cart/add", status, size, rng.choice(BROWSERS), True
    if roll < 0.81:
        return customer(), "GET", "/cart", 200, rng.randint(900, 1400), rng.choice(BROWSERS), True
    if roll < 0.84:
        return customer(), "GET", "/favicon.ico", 404, 1544, rng.choice(BROWSERS), False
    if roll < 0.90:
        return f"66.249.66.{rng.randint(1, 200)}", "GET", f"/book/{book}", 200, 2240, rng.choice(CRAWLERS), True
    if roll < 0.94:
        ip, agent = rng.choice(SCANNERS)
        return ip, "GET", rng.choice(PROBES), 404, 1544, agent, False
    return MONITOR[0], "GET", "/healthz", 200, 39, MONITOR[1], False


def write(fh, start, end, n, now, freeze=None):
    """n requests between start and end. freeze=(rate, since, rotated): pages wait
    for the Trending job, which takes (log lines so far / rate) seconds every 5 min."""
    span = end - start
    for i in range(n):
        t = start + (i + rng.random() * 0.9) * span / n
        ip, method, path, status, size, agent, touches_db = request(t, now)
        rt = rng.uniform(0.002, 0.030) if touches_db else rng.uniform(0.0, 0.002)
        if freeze and touches_db and t >= freeze[1]:
            rate, _, rotated = freeze
            job = (i * 1.0) / rate          # lines in the log right now / job speed
            phase = (t % 300) - 0.3         # cron starts the job on each 5-minute mark
            if 0 <= phase < job:
                rt += job - phase
        urt = max(rt - 0.001, 0.0)
        fh.write(f'{ip} - [{stamp(t)}] "{method} {path} HTTP/1.1" {status} {size} '
                 f'rt={rt:.3f} urt={urt:.3f} "{agent}"\n')


def main():
    mode = sys.argv[1]
    if mode == "sample":
        now = time.time()
        with open(sys.argv[2], "w", encoding="utf-8") as fh:
            write(fh, now - DAY, now, int(sys.argv[3]), now)
        return
    out, n, rate = sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
    last_rotation, chg0507, now = (int(x) for x in sys.argv[5:8])
    per_second = n / (now - last_rotation)
    with open(os.path.join(out, "access.log"), "w", encoding="utf-8") as fh:
        write(fh, last_rotation, now, n, now, freeze=(rate, chg0507, last_rotation))
    # The 14 days before that rotated normally: access.log.1, then .2.gz to .14.gz.
    for k in range(1, 15):
        start, end = last_rotation - k * DAY, last_rotation - (k - 1) * DAY
        name = os.path.join(out, f"access.log.{k}" + ("" if k == 1 else ".gz"))
        opener = open if k == 1 else (lambda p, m, **kw: gzip.open(p, m, compresslevel=6, **kw))
        with opener(name, "wt", encoding="utf-8") as fh:
            write(fh, start, end, int(per_second * DAY * rng.uniform(0.9, 1.1)), now)
        os.utime(name, (end + 60, end + 60))


main()
PY

# How fast does the Trending job read logs on this VM? Size the log so a run
# takes about FREEZE_SECONDS, whether the host is fast or slow.
python3 "$WORK/traffic.py" sample "$WORK/sample.log" 100000
chmod 0644 "$WORK/sample.log"
t0=$(date +%s%N)
runuser -u storefront -- /usr/local/bin/storefront-trending --log "$WORK/sample.log"
t1=$(date +%s%N)
rate=$((100000 * 1000000000 / (t1 - t0 + 1))) # lines per second
lines=$((rate * FREEZE_SECONDS))
((lines < 200000)) && lines=200000
((lines > 4000000)) && lines=4000000

systemctl stop nginx
rm -f "$NGINX_LOGS"/access.log*
python3 "$WORK/traffic.py" history "$NGINX_LOGS" "$lines" "$rate" "$LAST_ROTATION" "$CHG0507" "$NOW"
chown www-data:adm "$NGINX_LOGS"/access.log*
chmod 0640 "$NGINX_LOGS"/access.log*
systemctl start nginx

# --- Last night's housekeeping: logrotate.service, as logrotate.timer runs it -------
systemctl start logrotate.service
dry_run=$(logrotate -d /etc/logrotate.conf 2>&1 || true)
grep -q '^error: Ignoring nginx' <<<"$dry_run"
[[ -e $APP_LOGS/app.log.1 ]]

# The Trending job's own log since the shelf launched: weekly rotation until
# yesterday (trending.log.2.gz, then trending.log.1), daily from last night.
python3 - "$APP_LOGS" "$lines" "$rate" "$LAST_ROTATION" "$CHG0507" "$NOW" <<'PY'
import gzip, os, random, sys, time
out, n, rate, last_rotation, chg0507, now = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), *map(int, sys.argv[4:7])
rng = random.Random(519)
day = 86400
per_second = n / (now - last_rotation)
weekly = now - now % day - 6 * day  # the last weekly rotation, before yesterday's change


def runs(start, end):
    t = start - start % 300 + 300
    while t < end:
        lines = int((t - last_rotation) * per_second)
        took = lines / rate + rng.uniform(0.0, 0.2)
        views = int(lines * rng.uniform(0.47, 0.49))
        yield (f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(t))} trending: rebuilt from {lines:,} "
               f"log lines ({views:,} book views) in {took:.1f} s\n")
        t += 300


with gzip.open(os.path.join(out, "trending.log.2.gz"), "wt", encoding="utf-8") as fh:
    fh.writelines(runs(chg0507, weekly))
with open(os.path.join(out, "trending.log.1"), "w", encoding="utf-8") as fh:
    fh.writelines(runs(weekly, now - 120))
os.utime(os.path.join(out, "trending.log.2.gz"), (weekly + 30, weekly + 30))
PY
chown storefront:adm "$APP_LOGS"/trending.log.1 "$APP_LOGS"/trending.log.2.gz
chmod 0640 "$APP_LOGS"/trending.log.1 "$APP_LOGS"/trending.log.2.gz

# --- This morning: cron is back, the shelf rebuilds, customers shop ---------------------
systemctl start cron logrotate.timer
runuser -u storefront -- /bin/sh -c \
  '/usr/local/bin/storefront-trending >>/var/log/storefront/trending.log 2>&1' &
trending=$!
sleep 1
for path in / /book/7 /cart /book/3; do
  curl -s -o /dev/null -m 60 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" "$STORE$path" &
done
wait "$trending"
wait

for _ in 1 2 3; do # new visitors
  curl -s -o /dev/null -m 10 -d "book=$((RANDOM % 12 + 1))" "$STORE/cart/add" || true
done
while read -r sid; do # returning visitors
  [[ -n $sid ]] || continue
  curl -s -o /dev/null -m 10 -b "pb_session=$sid" -d "book=$((RANDOM % 12 + 1))" "$STORE/cart/add" || true
done <"$WORK/returning"

# --- Sanity: the incident is live -----------------------------------------------------
[[ $(curl -s -o /dev/null -m 10 -w '%{http_code}' -d book=1 "$STORE/cart/add") == 500 ]]
[[ ! -s $APP_LOGS/app.log ]]
grep -q 'could not save the cart for a new visitor' "$APP_LOGS/app.log.1"
grep -q 'slow request' "$APP_LOGS/app.log.1"
(($(stat -c %s "$NGINX_LOGS/access.log") > 20 * 1024 * 1024))

install -d -m 0755 /var/lib/lab
date -u +%FT%TZ >"$MARKER"
rm -rf "$ERR_FILE" "$WORK" "${BASH_SOURCE[0]}"

say "Done. The incident is live on web-03."
say "Next: 'vagrant snapshot save broken' (your reset point), then 'vagrant ssh'."
