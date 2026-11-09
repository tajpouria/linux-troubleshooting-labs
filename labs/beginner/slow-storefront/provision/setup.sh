#!/usr/bin/env bash
#
# slow-storefront setup: builds the HEALTHY baseline for web-02. Defects come later (break.sh).
#
#   host --http:80--> nginx --proxy--> storefront app (python3, 127.0.0.1:8080, user "storefront")
#
#   catalog-reindex.timer (01:00 nightly) --> catalog-reindex.service
#       user "catalog", Nice=10 (batch work yields to the storefront),
#       one worker process per CPU, checkpoints in /var/lib/catalog
#   catalog-reindex-resume.service: at boot, resumes a run a reboot interrupted
#
#   dani: a platform engineer's login account
#
# Provisioning fails if the smoke test at the end doesn't pass, so break.sh
# always starts from a known-good system. The smoke test also measures how fast
# pages load on this VM when it's healthy (/var/lib/lab/baseline.env), so
# lab-check can judge "fast again" fairly on both fast and slow host computers.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

MARKER=/var/lib/lab/provisioned
if [[ -e $MARKER ]]; then
  echo "==> [setup] This lab is already provisioned; not touching it."
  echo "    To reset: vagrant snapshot restore --no-provision broken"
  echo "    or rebuild: vagrant destroy -f, then vagrant up"
  exit 0
fi

log() { printf '==> [setup] %s\n' "$*"; }

APP_DIR=/opt/storefront
CATALOG_DIR=/var/lib/catalog

# --- 1. Packages -------------------------------------------------------------
log "Installing nginx, python3 and cron"
apt-get -y -qq -o DPkg::Lock::Timeout=600 install nginx python3 cron >/dev/null
systemctl enable --now cron >/dev/null 2>&1

# --- 2. Accounts ---------------------------------------------------------------
if ! id storefront >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$APP_DIR" --no-create-home \
    --shell /usr/sbin/nologin storefront
fi
if ! id catalog >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$CATALOG_DIR" --no-create-home \
    --shell /usr/sbin/nologin catalog
fi
if ! id dani >/dev/null 2>&1; then
  # A colleague's login account (password login disabled, like everyone's here).
  useradd --create-home --shell /bin/bash --comment "Dani Okafor (Platform team)" dani
fi

# --- 3. Storefront application ---------------------------------------------------
log "Installing the storefront app"
install -d -m 0755 "$APP_DIR"
cat >"$APP_DIR/app.py" <<'PY'
#!/usr/bin/env python3
"""Pinewood Books storefront (web-02).

Serves the shop's home page with a "Recommended for you" shelf. The ranker
refines its recommendations until a fixed CPU budget per page view is spent
(RECS_CPU_BUDGET_MS), so every page costs the same, predictable amount of CPU.

/healthz is cheap on purpose: it only says the process is up.
"""

import argparse
import html
import json
import random
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RECS_CPU_BUDGET_MS = 25

BOOKS = [
    ("The Quiet Kernel", "Ada Lindqvist", "18.00"),
    ("Paging at Midnight", "R. Okafor", "14.50"),
    ("A Field Guide to Small Rivers", "Maren Holt", "22.00"),
    ("Letters from the Night Shift", "J. Castellano", "16.75"),
    ("The Lighthouse Ledger", "Priya Raman", "19.25"),
    ("Load Average", "Tomas Brandt", "12.99"),
    ("Winter Inventory", "Elif Sahin", "21.50"),
    ("The Patient Scheduler", "Noor Haddad", "17.00"),
    ("Salt and Signal", "Corin Vale", "15.25"),
    ("A Short History of Waiting", "M. Adeyemi", "13.75"),
]

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pinewood Books</title>
<style>
  body {{ font-family: Georgia, serif; max-width: 44rem; margin: 2rem auto; padding: 0 1rem;
         color: #2b2b2b; background: #fbf8f1; }}
  header {{ border-bottom: 2px solid #3c5a40; margin-bottom: 1.5rem; }}
  h1 {{ color: #3c5a40; margin: 0 0 .25rem; }}
  .tagline {{ margin: 0 0 1rem; color: #666; }}
  li {{ margin: .5rem 0; }}
  .price {{ color: #3c5a40; font-weight: bold; }}
  .recs {{ background: #f1ece0; padding: .5rem 1rem; border-radius: 6px; }}
  footer {{ margin-top: 2rem; font-size: .8rem; color: #888; }}
</style>
</head>
<body>
<header>
  <h1>Pinewood Books</h1>
  <p class="tagline">Independent booksellers since 1987</p>
</header>
<h2>This week's picks</h2>
<ul>
{picks}
</ul>
<div class="recs">
<h2>Recommended for you</h2>
<ul>
{recs}
</ul>
</div>
<footer>Page rendered in {ms} ms by {host}</footer>
</body>
</html>
"""


def book_item(book):
    title, author, price = book
    return (f'  <li><em>{html.escape(title)}</em> by {html.escape(author)} '
            f'<span class="price">${price}</span></li>')


def recommend(seed):
    """Rank the catalog for one visitor, refining until the CPU budget is spent."""
    rng = random.Random(seed)
    deadline = time.thread_time() + RECS_CPU_BUDGET_MS / 1000
    scores = [0.0] * len(BOOKS)
    rounds = 0
    while True:
        for i in range(len(BOOKS)):
            scores[i] = 0.9 * scores[i] + rng.random()
        rounds += 1
        if rounds % 50 == 0 and time.thread_time() >= deadline:
            break
    ranked = sorted(range(len(BOOKS)), key=lambda i: scores[i], reverse=True)
    return [BOOKS[i] for i in ranked[:3]]


class Handler(BaseHTTPRequestHandler):
    server_version = "storefront/2.1"

    def log_message(self, fmt, *args):
        pass  # nginx already logs every request

    def _send(self, status, body, ctype="text/html; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _handle(self):
        started = time.monotonic()
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            body = json.dumps({"status": "ok", "host": socket.gethostname()}) + "\n"
            self._send(200, body, "application/json")
        elif path == "/":
            visitor = self.headers.get("X-Real-IP", self.client_address[0])
            recs = recommend(f"{visitor}-{time.time_ns()}")
            ms = int((time.monotonic() - started) * 1000)
            page = PAGE.format(
                picks="\n".join(book_item(b) for b in BOOKS[:5]),
                recs="\n".join(book_item(b) for b in recs),
                ms=ms,
                host=html.escape(socket.gethostname()),
            )
            self._send(200, page)
        else:
            self._send(404, "not found\n", "text/plain; charset=utf-8")

    do_GET = _handle
    do_HEAD = _handle


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128


def main():
    parser = argparse.ArgumentParser(description="Pinewood Books storefront")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    server = Server((args.host, args.port), Handler)
    print(f"INFO Pinewood Books storefront listening on http://{args.host}:{args.port}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
chmod 0755 "$APP_DIR/app.py"

cat >/etc/systemd/system/storefront.service <<EOF
[Unit]
Description=Pinewood Books storefront
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=storefront
Group=storefront
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 $APP_DIR/app.py --port 8080
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

# --- 4. Nightly catalog reindex ------------------------------------------------------
log "Installing the nightly catalog reindex"
install -d -o catalog -g catalog -m 0755 "$CATALOG_DIR" "$CATALOG_DIR/export"
cat >/usr/local/bin/catalog-reindex <<'PY'
#!/usr/bin/env python3
"""catalog-reindex: rebuild the storefront's search index from the catalog export.

Started every night at 01:00 by catalog-reindex.timer. It loads the newest
export from /var/lib/catalog/export, then ranks the products in parallel, with
one worker process per CPU. Each worker saves a checkpoint every few seconds,
so a restart resumes where the last run stopped instead of starting over.
When all products are done it writes /var/lib/catalog/reindex.done and exits.
"""

import argparse
import glob
import hashlib
import json
import os
import signal
import sys
import time

STATE_DIR = "/var/lib/catalog"
EXPORT_GLOB = os.path.join(STATE_DIR, "export", "*.jsonl")
DONE_FILE = os.path.join(STATE_DIR, "reindex.done")
CHECKPOINT_GLOB = os.path.join(STATE_DIR, "reindex.checkpoint.*")

TOTAL_PRODUCTS = 5_760_000
BATCH = 10                # products per batch
BATCH_CPU_SECONDS = 0.05  # CPU time it takes to rank one batch
CHECKPOINT_EVERY = 5      # seconds
REPORT_EVERY = 60         # seconds


def log(message):
    print(message, flush=True)


def checkpoint_path(n):
    return os.path.join(STATE_DIR, f"reindex.checkpoint.{n}")


def read_checkpoints():
    done = 0
    for path in glob.glob(CHECKPOINT_GLOB):
        try:
            with open(path, encoding="utf-8") as fh:
                done += int(json.load(fh)["done"])
        except (OSError, ValueError, KeyError, TypeError):
            pass
    return min(done, TOTAL_PRODUCTS)


def write_checkpoint(n, done):
    tmp = checkpoint_path(n) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"done": done}, fh)
    os.replace(tmp, checkpoint_path(n))


def load_export():
    exports = sorted(glob.glob(EXPORT_GLOB))
    if not exports:
        log(f"ERROR no catalog export found in {os.path.dirname(EXPORT_GLOB)}")
        return None
    path = exports[-1]
    size = 0
    with open(path, "rb") as fh:
        while chunk := fh.read(8 * 1024 * 1024):
            size += len(chunk)
    log(f"loaded catalog export {os.path.basename(path)} ({size // (1024 * 1024)} MiB)")
    return path


def worker(n, start, quota):
    """Rank products [start, quota) of this worker's share. Runs in a child process."""
    stopping = []
    signal.signal(signal.SIGTERM, lambda *_: stopping.append(True))
    block = os.urandom(4096)
    digest = hashlib.sha256()
    done = start
    last_save = time.monotonic()
    while done < quota and not stopping:
        deadline = time.process_time() + BATCH_CPU_SECONDS
        while time.process_time() < deadline:
            digest.update(block)
        done = min(done + BATCH, quota)
        if time.monotonic() - last_save >= CHECKPOINT_EVERY:
            write_checkpoint(n, done)
            last_save = time.monotonic()
    write_checkpoint(n, done)
    os._exit(0)


def describe(status):
    if os.WIFSIGNALED(status):
        return f"killed by signal {os.WTERMSIG(status)}"
    return f"exit code {os.WEXITSTATUS(status)}"


def main():
    parser = argparse.ArgumentParser(description="Rebuild the catalog search index")
    parser.add_argument("--workers", default="auto", help='number of worker processes, or "auto" (one per CPU)')
    args = parser.parse_args()
    cpus = len(os.sched_getaffinity(0))  # the CPUs this process may run on
    workers = cpus if args.workers == "auto" else max(1, int(args.workers))

    os.chdir(STATE_DIR)
    done = read_checkpoints()
    if done == 0 and os.path.exists(DONE_FILE):
        os.remove(DONE_FILE)  # a new night, a new run
    if load_export() is None:
        return 1

    log(f"starting {workers} workers, resuming at {done:,}/{TOTAL_PRODUCTS:,} products "
        f"({100 * done / TOTAL_PRODUCTS:.1f}%)")
    for path in glob.glob(CHECKPOINT_GLOB):
        os.remove(path)
    share = TOTAL_PRODUCTS // workers
    children = {}
    for n in range(workers):
        quota = share if n < workers - 1 else TOTAL_PRODUCTS - share * (workers - 1)
        start = min(done // workers, quota)
        write_checkpoint(n, start)
        pid = os.fork()
        if pid == 0:
            worker(n, start, quota)
        children[pid] = n

    stopping = []
    signal.signal(signal.SIGTERM, lambda *_: stopping.append(True))
    last_report, last_done = time.monotonic(), read_checkpoints()
    failed = None
    while children:
        if stopping or failed:
            for pid in children:
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        try:
            pid, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            break
        if pid:
            n = children.pop(pid)
            if status != 0 and not stopping and not failed:
                failed = f"worker {n} (pid {pid}) died: {describe(status)}"
            continue
        time.sleep(1)
        if time.monotonic() - last_report >= REPORT_EVERY:
            now_done = read_checkpoints()
            rate = (now_done - last_done) / (time.monotonic() - last_report)
            eta = f"about {(TOTAL_PRODUCTS - now_done) / rate / 60:.0f} min left" if rate > 0 else "no progress"
            log(f"progress {100 * now_done / TOTAL_PRODUCTS:.1f}% "
                f"({now_done:,}/{TOTAL_PRODUCTS:,} products, {rate:,.0f}/s), {eta}")
            last_report, last_done = time.monotonic(), now_done

    done = read_checkpoints()
    if failed:
        log(f"ERROR {failed}. Stopping the other workers. Progress is saved; a restart resumes at "
            f"{100 * done / TOTAL_PRODUCTS:.1f}%.")
        return 1
    if stopping:
        log(f"stopped at {100 * done / TOTAL_PRODUCTS:.1f}%. Progress is saved; a restart resumes from here.")
        return 0
    with open(DONE_FILE, "w", encoding="utf-8") as fh:
        fh.write(time.strftime("%Y-%m-%dT%H:%M:%SZ\n", time.gmtime()))
    for path in glob.glob(CHECKPOINT_GLOB):
        os.remove(path)
    log("reindex complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
chmod 0755 /usr/local/bin/catalog-reindex
python3 -m py_compile /usr/local/bin/catalog-reindex
rm -rf /usr/local/bin/__pycache__

cat >/etc/systemd/system/catalog-reindex.service <<'EOF'
[Unit]
Description=Nightly catalog reindex (search index for the storefront)
After=network-online.target

[Service]
Type=simple
User=catalog
Group=catalog
WorkingDirectory=/var/lib/catalog
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 /usr/local/bin/catalog-reindex --workers auto
# Batch work: always let the storefront go first when both want the CPU.
Nice=10
EOF

cat >/etc/systemd/system/catalog-reindex.timer <<'EOF'
[Unit]
Description=Run the catalog reindex every night

[Timer]
OnCalendar=*-*-* 01:00:00

[Install]
WantedBy=timers.target
EOF

cat >/etc/systemd/system/catalog-reindex-resume.service <<'EOF'
[Unit]
Description=Resume a catalog reindex that a reboot interrupted
# Checkpoints only exist while a run is unfinished.
ConditionPathExistsGlob=/var/lib/catalog/reindex.checkpoint.*

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl start --no-block catalog-reindex.service

[Install]
WantedBy=multi-user.target
EOF

# --- 5. nginx reverse proxy ----------------------------------------------------------
log "Configuring nginx"
cat >/etc/nginx/conf.d/storefront-logformat.conf <<'EOF'
# Access log format with timings: rt = whole request, urt = time spent in the app.
log_format timed '$remote_addr - [$time_local] "$request" $status $body_bytes_sent '
                 'rt=$request_time urt=$upstream_response_time "$http_user_agent"';
EOF

cat >/etc/nginx/sites-available/storefront <<'EOF'
upstream storefront_app {
    server 127.0.0.1:8080;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    access_log /var/log/nginx/access.log timed;
    error_log  /var/log/nginx/error.log;

    location / {
        proxy_pass http://storefront_app;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/storefront /etc/nginx/sites-enabled/storefront

# --- 6. Start everything and prove it works --------------------------------------------
log "Starting services"
systemctl daemon-reload
systemctl enable --now storefront.service >/dev/null 2>&1
systemctl enable --now catalog-reindex.timer >/dev/null 2>&1
systemctl enable catalog-reindex-resume.service >/dev/null 2>&1
nginx -t -q
systemctl enable nginx >/dev/null 2>&1
systemctl reload-or-restart nginx

log "Smoke test"
# `systemctl reload nginx` returns before the old workers (still serving the
# stock "Welcome to nginx" page) are gone, so retry until ONE response has both
# the right status and the storefront's content.
code=000
healthy=false
for _ in $(seq 1 30); do
  response=$(curl -s -m 5 -w '\n%{http_code}' http://127.0.0.1/ || true)
  code=${response##*$'\n'}
  if [[ $code == 200 && $response == *"Pinewood Books"* ]]; then
    healthy=true
    break
  fi
  sleep 1
done
if ! $healthy; then
  echo "ERROR: baseline smoke test failed (last HTTP $code). The lab can't be built." >&2
  journalctl -u storefront -n 30 --no-pager >&2 || true
  tail -n 20 /var/log/nginx/error.log >&2 || true
  exit 1
fi

# How fast is a healthy page on this VM? Median of 21 loads, after a warm-up.
for _ in 1 2 3 4 5; do curl -s -o /dev/null http://127.0.0.1/ || true; done
times=()
for _ in $(seq 1 21); do
  t=$(curl -s -o /dev/null -m 5 -w '%{time_total}' http://127.0.0.1/ || echo 5)
  times+=("$(awk -v t="$t" 'BEGIN { printf "%d", t * 1000 }')")
done
baseline=$(printf '%s\n' "${times[@]}" | sort -n | sed -n 11p)
install -d -m 0755 /var/lib/lab
echo "BASELINE_MS=$baseline" >/var/lib/lab/baseline.env

log "Healthy baseline is up: http://127.0.0.1/ -> 200, median page time ${baseline} ms"
if ((baseline > 120)); then
  log "NOTE: pages are slower than expected even when healthy. lab-check allows for"
  log "      that, but on Windows see 'Hyper-V' in docs/setup-windows.md."
fi
