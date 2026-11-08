#!/usr/bin/env bash
#
#  ███  SPOILER WARNING  ███
#  This script injects the lab-01 defects. Don't read it until you've solved
#  the lab (or given up and read SOLUTIONS.md).
#
# It replays a bad night on web-01:
#   1. A "temporary" debug tracer was left running. It filled the log volume,
#      and the night on-call deleted its log file while it was still open, so
#      the space was never freed.
#   2. The backend config was edited as root and put back with 0600 root:root,
#      so the service account can no longer read it.
#   3. Prep for a backend port move pointed nginx at a port nothing listens on.
#   4. "Security hardening" turned on the host firewall without allowing HTTP.
#
# Output is kept neutral on purpose, because `vagrant up` prints it on your
# terminal. The script deletes itself when it's done.

set -Eeuo pipefail

MARKER=/var/lib/lab/provisioned
if [[ -e $MARKER ]]; then
  echo "==> [break] lab-01 incident already injected; not touching it."
  exit 0
fi

# Keep the host terminal spoiler-free, but surface errors if something breaks.
ERR_FILE=$(mktemp /run/lab-break.XXXXXX)
exec 3>&1 4>&2 1>/dev/null 2>"$ERR_FILE"
trap 'echo "ERROR: break.sh failed at line $LINENO:" >&4; cat "$ERR_FILE" >&4; rm -f "$ERR_FILE"' ERR
say() { printf '==> [break] %s\n' "$*" >&3; }

APP_UNIT=bookshop.service
APP_CONF=/etc/bookshop/bookshop.conf
LOG_MNT=/var/log/bookshop
TRACE_FILE=$LOG_MNT/trace-debug.log
UPSTREAM_CONF=/etc/nginx/conf.d/bookshop-upstream.conf

say "Replaying last night's change window on web-01..."

avail_bytes() { df --output=avail -B1 "$LOG_MNT" | awk 'NR == 2 { print $1 }'; }

# --- Defect 1: runaway debug tracer + deleted-but-open log file --------------
cat >/usr/local/bin/bookshop-tracer <<'PY'
#!/usr/bin/env python3
"""bookshop-tracer: verbose request tracing for the bookshop backend.

TEMPORARY debugging aid for INC-4471 ("checkout is sometimes slow").
Samples request/response traces and appends them to TRACE_FILE.
TODO(platform): remove once INC-4471 is closed!
"""
import datetime
import errno
import os
import random
import time

TRACE_FILE = "/var/log/bookshop/trace-debug.log"
BYTES_PER_SECOND = 1024 * 1024
LINES_PER_BATCH = 400

PATHS = ["/", "/", "/books/9780000000017", "/books/9780000000024", "/cart",
         "/checkout", "/checkout/confirm", "/search?q=rivers", "/healthz"]
AGENTS = ["Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15",
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0",
          "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X)",
          "curl/8.5.0"]


def trace_line(rng):
    now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="microseconds")
    path = rng.choice(PATHS)
    status = 200 if rng.random() > 0.03 else rng.choice([302, 404, 500])
    return (
        f"{now} TRACE rid={rng.getrandbits(64):016x} span={rng.getrandbits(32):08x} "
        f"method=GET path={path} status={status} dur_ms={rng.uniform(2, 900):.1f} "
        f"upstream=127.0.0.1:8080 db.queries={rng.randint(1, 14)} cache.hit={rng.random() > 0.4} "
        f'ua="{rng.choice(AGENTS)}" session={rng.getrandbits(96):024x}\n'
    )


def main():
    rng = random.Random()
    fd = os.open(TRACE_FILE, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o640)
    print(f"bookshop-tracer: tracing to {TRACE_FILE} (verbose)", flush=True)
    failing = False
    while True:
        batch = "".join(trace_line(rng) for _ in range(LINES_PER_BATCH)).encode()
        try:
            os.write(fd, batch)
        except OSError as exc:
            if exc.errno != errno.ENOSPC:
                raise
            if not failing:
                print(f"bookshop-tracer: WARN trace write failed: {exc}; retrying", flush=True)
                failing = True
            time.sleep(5)
            continue
        if failing:
            print("bookshop-tracer: trace writes recovered", flush=True)
            failing = False
        time.sleep(len(batch) / BYTES_PER_SECOND)


if __name__ == "__main__":
    main()
PY
chmod 0755 /usr/local/bin/bookshop-tracer

cat >/etc/systemd/system/bookshop-tracer.service <<EOF
[Unit]
Description=Bookshop request tracer (TEMPORARY - debugging INC-4471)
After=local-fs.target
RequiresMountsFor=$LOG_MNT

[Service]
User=bookshop
Group=bookshop
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 /usr/local/bin/bookshop-tracer
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Backfill the trace log as if the tracer had run all night, leaving ~4 MiB
# for the live tracer to use up.
backfill=$(($(avail_bytes) - 4 * 1024 * 1024))
python3 - "$TRACE_FILE" "$backfill" <<'PY'
import datetime, random, sys
path, target = sys.argv[1], int(sys.argv[2])
rng = random.Random(4471)
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=9)
lines = []
for _ in range(14000):
    t += datetime.timedelta(milliseconds=rng.randint(1, 4))
    lines.append(
        f"{t.isoformat(timespec='microseconds')} TRACE rid={rng.getrandbits(64):016x} "
        f"span={rng.getrandbits(32):08x} method=GET path={rng.choice(['/', '/cart', '/checkout', '/healthz'])} "
        f"status=200 dur_ms={rng.uniform(2, 900):.1f} upstream=127.0.0.1:8080 "
        f"db.queries={rng.randint(1, 14)} cache.hit={rng.random() > 0.4} "
        f"ua=\"Mozilla/5.0\" session={rng.getrandbits(96):024x}\n")
block = "".join(lines).encode()
written = 0
with open(path, "ab") as fh:
    while written < target:
        chunk = block[: min(len(block), target - written)]
        fh.write(chunk)
        written += len(chunk)
PY
chown bookshop:bookshop "$TRACE_FILE"
chmod 0640 "$TRACE_FILE"

systemctl daemon-reload
systemctl enable --now bookshop-tracer.service

# Wait until the tracer holds the file open and the volume is full for non-root users.
for _ in $(seq 1 60); do
  pid=$(systemctl show -p MainPID --value bookshop-tracer.service)
  if [[ $pid != 0 && $(readlink "/proc/$pid/fd/"* 2>/dev/null) == *"$TRACE_FILE"* ]] &&
    (($(avail_bytes) < 1024 * 1024)); then
    break
  fi
  sleep 1
done

# Customers hit the site while the disk was full.
for _ in 1 2 3 4 5; do curl -s -o /dev/null http://127.0.0.1/ || true; done

# 02:40, the night on-call: "cleaned up some old logs".
rm -f "$TRACE_FILE"

# --- Defect 2: config file no longer readable by the service account ---------
tmp=$(mktemp)
cp "$APP_CONF" "$tmp"
sed -i '2a # Reviewed during CHG-0311 maintenance window.' "$tmp"
install -m 0600 -o root -g root "$tmp" "$APP_CONF"
rm -f "$tmp"

# --- Defect 3: nginx upstream points at the wrong port -----------------------
sed -i 's/server 127\.0\.0\.1:8080;/server 127.0.0.1:8081;/' "$UPSTREAM_CONF"
grep -q '127.0.0.1:8081;' "$UPSTREAM_CONF"
nginx -t -q
systemctl reload nginx

# --- Defect 4: host firewall enabled without allowing HTTP --------------------
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw logging low
ufw --force enable

# Someone restarted the backend to "fix the 503s". It never came back.
systemctl restart "$APP_UNIT" || true
for _ in $(seq 1 30); do
  systemctl is-failed --quiet "$APP_UNIT" && break
  sleep 1
done

# Start the access log fresh: only requests after this point count for lab-check.
truncate -s 0 /var/log/nginx/access.log
rm -f /var/log/nginx/access.log.[0-9]*

# The uptime monitor's local probe keeps failing.
for _ in 1 2 3; do curl -s -o /dev/null http://127.0.0.1/ || true; done

install -d -m 0755 /var/lib/lab
date -u +%FT%TZ >"$MARKER"
rm -f "$ERR_FILE" "${BASH_SOURCE[0]}"

say "Done. The incident is live on web-01."
say "Next: 'vagrant snapshot save broken' (your reset point), then 'vagrant ssh'."
