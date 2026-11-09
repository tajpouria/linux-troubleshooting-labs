#!/usr/bin/env bash
#
#  ███  SPOILER WARNING  ███
#  This script injects the slow-storefront defects. Don't read it until you've
#  solved the lab (or given up and read SOLUTIONS.md).
#
# It replays the last few days on web-02:
#   1. Last week (CHG-0398): to make the nightly catalog reindex finish sooner, a
#      drop-in raised its priority to Nice=-10. Since the holiday catalog import
#      it no longer finishes overnight, so now it outranks the storefront for CPU
#      during business hours.
#   2. Tuesday (CHG-0420): Dani started a load test against the storefront from
#      web-02 itself, through an @reboot line in their crontab. It should have
#      stopped on Wednesday. It's still running.
#   3. 01:35 last night: the night on-call saw the storefront "eating CPU" and
#      capped it: systemctl set-property storefront.service CPUQuota=5%
#   Red herring: the reindex reads a ~1 GB catalog export, which fills the page
#   cache, so `free` shows almost no "free" memory. That's normal and harmless.
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
exec 3>&1 4>&2 1>/dev/null 2>"$ERR_FILE"
trap 'echo "ERROR: break.sh failed at line $LINENO:" >&4; cat "$ERR_FILE" >&4; rm -f "$ERR_FILE"' ERR
say() { printf '==> [break] %s\n' "$*" >&3; }

CATALOG_DIR=/var/lib/catalog
LOADTEST_DIR=/home/dani/loadtest
TOTAL_PRODUCTS=5760000

say "Replaying the last few days on web-02..."

# --- Defect 1: the reindex outranks the storefront --------------------------------
install -d -m 0755 /etc/systemd/system/catalog-reindex.service.d
cat >/etc/systemd/system/catalog-reindex.service.d/override.conf <<'EOF'
# CHG-0398: the reindex has to be done before business hours.
# Give it a bigger share of the CPU so it finishes sooner.
[Service]
Nice=-10
EOF
touch -d '-6 days' /etc/systemd/system/catalog-reindex.service.d/override.conf
systemctl daemon-reload

# --- Defect 2: a load test nobody stopped --------------------------------------------
install -d -o dani -g dani -m 0755 "$LOADTEST_DIR"
cat >"$LOADTEST_DIR/loadgen.py" <<'PY'
#!/usr/bin/env python3
"""loadgen.py: a small HTTP load generator for capacity tests.

    loadgen.py --url http://127.0.0.1/ --workers 4 --threads 4

Starts --workers worker processes with --threads client threads each. Every
thread requests --url in a loop, as fast as the server answers. The parent
process keeps the workers alive: if a worker dies, it starts a new one.
To stop everything, stop the parent (Ctrl-C, or kill <parent PID>).
"""

import argparse
import os
import signal
import sys
import threading
import time
import urllib.request

USER_AGENT = "pinewood-loadgen/0.3 (CHG-0420)"


def client(url):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    while True:
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                response.read()
        except Exception:
            time.sleep(0.5)


def worker(url, threads):
    parent = os.getppid()
    for _ in range(threads):
        threading.Thread(target=client, args=(url,), daemon=True).start()
    while os.getppid() == parent:  # quit if the parent goes away
        time.sleep(1)
    os._exit(0)


def main():
    parser = argparse.ArgumentParser(description="HTTP load generator")
    parser.add_argument("--url", required=True)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()

    stopping = []
    signal.signal(signal.SIGTERM, lambda *_: stopping.append(True))
    signal.signal(signal.SIGINT, lambda *_: stopping.append(True))
    print(f"loadgen: {args.workers} workers x {args.threads} threads -> {args.url}", flush=True)

    children = set()
    while not stopping:
        while len(children) < args.workers:
            pid = os.fork()
            if pid == 0:
                signal.signal(signal.SIGTERM, signal.SIG_DFL)
                signal.signal(signal.SIGINT, signal.SIG_DFL)
                worker(args.url, args.threads)
            children.add(pid)
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            pid = 0
        if pid:
            children.discard(pid)
            print(f"loadgen: worker {pid} exited, starting a new one", flush=True)
        else:
            time.sleep(1)

    for pid in children:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    print("loadgen: stopped", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY

cat >"$LOADTEST_DIR/NOTES.txt" <<'EOF'
CHG-0420 capacity test for the holiday sale (web-02)

- Load comes from web-02 itself, so the network isn't the bottleneck.
- Started from my crontab (@reboot), so the test keeps going if the box
  gets rebooted during the test window.
- Test window: Tuesday 16:00 -> Wednesday 18:00.
- TODO Wednesday evening: stop it and remove the crontab line!!
EOF
chown dani:dani "$LOADTEST_DIR/loadgen.py" "$LOADTEST_DIR/NOTES.txt"
chmod 0755 "$LOADTEST_DIR/loadgen.py"
touch -d '-2 days' "$LOADTEST_DIR/loadgen.py" "$LOADTEST_DIR/NOTES.txt"

crontab -u dani - <<'EOF'
# m h  dom mon dow   command
# CHG-0420: holiday capacity test. Keep the load going if web-02 reboots.
@reboot /usr/bin/python3 /home/dani/loadtest/loadgen.py --url http://127.0.0.1/ --workers 4 --threads 4 >> /home/dani/loadtest/loadgen.log 2>&1
EOF

# Start it the way it started on Tuesday: cron runs @reboot jobs when it starts
# for the first time after a boot, which it remembers in /run/crond.reboot.
rm -f /run/crond.reboot
systemctl restart cron
loadgen_running() { (($(pgrep -c -u dani -f loadgen.py || true) >= 5)); }
for _ in $(seq 1 30); do
  loadgen_running && break
  sleep 1
done
if ! loadgen_running; then
  # Fallback if cron didn't run it: start it by hand, as Dani.
  runuser -u dani -- setsid -f /usr/bin/python3 "$LOADTEST_DIR/loadgen.py" \
    --url http://127.0.0.1/ --workers 4 --threads 4 >>"$LOADTEST_DIR/loadgen.log" 2>&1 </dev/null
  for _ in $(seq 1 15); do
    loadgen_running && break
    sleep 1
  done
  loadgen_running
fi

# --- The nightly reindex starts on a much bigger catalog (and fills the page cache) --
# Size the export so the page cache takes up nearly all the "free" memory.
avail_mib=$(($(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo) / 1024))
export_mib=$((avail_mib - 160))
if ((export_mib > 1100)); then export_mib=1100; fi
if ((export_mib < 256)); then export_mib=256; fi
export_file="$CATALOG_DIR/export/catalog-$(date -u +%F).jsonl"
python3 - "$export_file" "$export_mib" <<'PY'
import json, random, sys
path, mib = sys.argv[1], int(sys.argv[2])
rng = random.Random(2026)
words = ["winter", "river", "kernel", "ledger", "night", "salt", "signal", "harbor", "paper", "lamp"]
lines = []
for i in range(4000):
    lines.append(json.dumps({
        "sku": f"PB-{rng.randrange(10**8):08d}",
        "title": " ".join(rng.choice(words).title() for _ in range(3)),
        "price": round(rng.uniform(5, 60), 2),
        "stock": rng.randrange(0, 400),
        "tags": rng.sample(words, 3),
    }) + "\n")
block = "".join(lines).encode()
target = mib * 1024 * 1024
written = 0
with open(path, "wb") as fh:
    while written < target:
        chunk = block[: target - written]
        fh.write(chunk)
        written += len(chunk)
PY
chown catalog:catalog "$export_file"

# It has been running since 01:00: start it from a checkpoint at about 38%.
workers=$(nproc)
per_worker=$((TOTAL_PRODUCTS * 38 / 100 / workers))
for ((n = 0; n < workers; n++)); do
  echo "{\"done\": $per_worker}" >"$CATALOG_DIR/reindex.checkpoint.$n"
done
chown catalog:catalog "$CATALOG_DIR"/reindex.checkpoint.*
rm -f "$CATALOG_DIR/reindex.done"
systemctl start catalog-reindex.service
for _ in $(seq 1 60); do
  (($(pgrep -c -u catalog -f catalog-reindex || true) > workers)) && break
  sleep 1
done
systemctl is-active --quiet catalog-reindex.service

# --- Defect 3: the night on-call's "temporary" limit --------------------------------
systemctl set-property storefront.service CPUQuota=5%
[[ $(systemctl show -p CPUQuotaPerSecUSec --value storefront.service) == 50ms ]]

install -d -m 0755 /var/lib/lab
date -u +%FT%TZ >"$MARKER"
rm -f "$ERR_FILE" "${BASH_SOURCE[0]}"

say "Done. The incident is live on web-02."
say "Next: 'vagrant snapshot save broken' (your reset point), then 'vagrant ssh'."
