#!/usr/bin/env bash
#
# lab-01 setup: builds the HEALTHY baseline for web-01. Defects come later (break.sh).
#
#   Mac --http:80--> nginx --proxy--> bookshop backend (python3, 127.0.0.1:8080, user "bookshop")
#                                       |-- config:    /etc/bookshop/bookshop.conf (holds a secret)
#                                       '-- audit log: /var/log/bookshop (dedicated 1 GB volume)
#
# Provisioning fails if the smoke test at the end doesn't pass, so break.sh
# always starts from a known-good system.
#
# Test hook: LAB_LOGVOL=loop forces the loop-file log volume instead of
# looking for the extra disk (handy when testing outside a VM).

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

MARKER=/var/lib/lab/provisioned
if [[ -e $MARKER ]]; then
  echo "==> [setup] lab-01 is already provisioned; not touching it."
  echo "    To reset: vagrant snapshot restore --no-provision broken"
  echo "    or rebuild: vagrant destroy -f && vagrant up"
  exit 0
fi

log() { printf '==> [setup] %s\n' "$*"; }

APP_USER=bookshop
APP_DIR=/opt/bookshop
CONF_DIR=/etc/bookshop
LOG_MNT=/var/log/bookshop
LOG_LABEL=bookshop-logs

# --- 1. Packages -------------------------------------------------------------
log "Installing nginx and python3"
apt-get -y -qq -o DPkg::Lock::Timeout=600 install nginx python3 >/dev/null

# --- 2. Service account --------------------------------------------------------
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$APP_DIR" --no-create-home \
    --shell /usr/sbin/nologin "$APP_USER"
fi

# --- 3. Dedicated log volume ---------------------------------------------------
# The Vagrantfile attaches an extra, blank 1 GB disk. Find it without assuming a
# device name (nvme0n2, sdb, ...): a whole disk of about 1 GB with no partitions,
# partition table or filesystem.
find_spare_disk() {
  local name type size
  while read -r name type size; do
    [[ $type == disk ]] || continue
    ((size >= 900 * 1024 * 1024 && size <= 1200 * 1024 * 1024)) || continue
    [[ $(lsblk -nro NAME "$name" | wc -l) -eq 1 ]] || continue
    [[ -z $(lsblk -ndro FSTYPE "$name") && -z $(lsblk -ndro PTTYPE "$name") ]] || continue
    echo "$name"
    return 0
  done < <(lsblk -dpnbro NAME,TYPE,SIZE)
  return 1
}

if [[ ${LAB_LOGVOL:-auto} != loop ]] && dev=$(find_spare_disk); then
  log "Formatting the extra disk $dev for $LOG_MNT"
  mkfs.ext4 -q -L "$LOG_LABEL" "$dev"
  fstab_line="UUID=$(blkid -s UUID -o value "$dev")  $LOG_MNT  ext4  defaults,nofail  0  2"
else
  log "WARNING: no blank 1 GB disk found, so using a loop-file volume instead."
  log "         The lab works the same way. (Did the Vagrantfile's extra-disk trigger run?)"
  install -d -m 0755 /var/lib/lab
  img=/var/lib/lab/bookshop-logs.img
  fallocate -l 1G "$img"
  mkfs.ext4 -q -F -L "$LOG_LABEL" "$img"
  fstab_line="$img  $LOG_MNT  ext4  loop,defaults,nofail  0  2"
fi
install -d "$LOG_MNT"
sed -i "\\#[[:space:]]${LOG_MNT}[[:space:]]#d" /etc/fstab
echo "$fstab_line" >>/etc/fstab
systemctl daemon-reload
mount "$LOG_MNT"
chown "$APP_USER:$APP_USER" "$LOG_MNT"
chmod 0750 "$LOG_MNT"

# --- 4. Application ------------------------------------------------------------
log "Installing the bookshop backend"
install -d -m 0755 "$APP_DIR" "$CONF_DIR"

cat >"$APP_DIR/app.py" <<'PY'
#!/usr/bin/env python3
"""Pinewood Books storefront backend.

A deliberately small web app (Python standard library only) that sits behind
nginx on web-01. Every request is recorded in an audit log. If the audit log
can't be written, the backend refuses to serve traffic (policy SEC-7).
"""

import argparse
import configparser
import datetime
import errno
import html
import json
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MIB = 1024 * 1024

BOOKS = [
    ("The Quiet Kernel", "Ada Lindqvist", "18.00"),
    ("Paging at Midnight", "R. Okafor", "14.50"),
    ("A Field Guide to Small Rivers", "Maren Holt", "22.00"),
    ("Letters from the Night Shift", "J. Castellano", "16.75"),
    ("The Lighthouse Ledger", "Priya Raman", "19.25"),
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
{items}
</ul>
<footer>Served by {host} &middot; backend pid {pid}</footer>
</body>
</html>
"""


def log(level, message):
    print(f"{level} {message}", flush=True)


def render_home():
    items = "\n".join(
        f'  <li><em>{html.escape(title)}</em> by {html.escape(author)} '
        f'<span class="price">${price}</span></li>'
        for title, author, price in BOOKS
    )
    return PAGE.format(items=items, host=html.escape(socket.gethostname()), pid=os.getpid())


class AuditLog:
    """Append-only audit trail. Refuses to write when the volume is nearly full."""

    def __init__(self, directory, min_free_mb):
        self.directory = directory
        self.path = os.path.join(directory, "audit.log")
        self.min_free = min_free_mb * MIB

    def free_bytes(self):
        st = os.statvfs(self.directory)
        return st.f_bavail * st.f_frsize

    def write(self, event):
        free = self.free_bytes()
        if free < self.min_free:
            raise OSError(
                errno.ENOSPC,
                f"{os.strerror(errno.ENOSPC)} "
                f"(free {free // MIB} MiB, need {self.min_free // MIB} MiB)",
                self.path,
            )
        stamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds")
        with open(self.path, "a", encoding="utf-8") as fh:
            fh.write(f"{stamp} {event}\n")


class Handler(BaseHTTPRequestHandler):
    server_version = "bookshop/1.4"
    audit = None  # set in main()

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
        client = self.headers.get("X-Real-IP", self.client_address[0])
        try:
            self.audit.write(f"client={client} method={self.command} path={self.path}")
        except OSError as exc:
            log("ERROR", f"audit write failed, rejecting request: {exc}")
            self._send(503, "audit log unavailable\n", "text/plain; charset=utf-8")
            return

        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            body = json.dumps({"status": "ok", "host": socket.gethostname()}) + "\n"
            self._send(200, body, "application/json")
        elif path == "/":
            self._send(200, render_home())
        else:
            self._send(404, "not found\n", "text/plain; charset=utf-8")

    do_GET = _handle
    do_HEAD = _handle


def main():
    parser = argparse.ArgumentParser(description="Pinewood Books storefront backend")
    parser.add_argument("--config", default="/etc/bookshop/bookshop.conf")
    args = parser.parse_args()

    config = configparser.ConfigParser()
    with open(args.config, encoding="utf-8") as fh:
        config.read_file(fh)

    host = config.get("server", "listen_host", fallback="127.0.0.1")
    port = config.getint("server", "listen_port", fallback=8080)
    audit = AuditLog(
        config.get("audit", "log_dir"),
        config.getint("audit", "min_free_mb", fallback=50),
    )

    try:
        audit.write(f"event=startup pid={os.getpid()}")
    except OSError as exc:
        log("FATAL", f"cannot write audit log: {exc}")
        log("FATAL", "refusing to start without audit logging (policy SEC-7)")
        return 1

    Handler.audit = audit
    server = ThreadingHTTPServer((host, port), Handler)
    log("INFO", f"Pinewood Books backend listening on http://{host}:{port}")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
chmod 0755 "$APP_DIR/app.py"

cat >"$CONF_DIR/bookshop.conf" <<'EOF'
# Pinewood Books storefront backend
# Owner: platform team. Edited by hand on web-01 (TODO: move to config management).

[server]
listen_host = 127.0.0.1
listen_port = 8080

[audit]
# Every request is written to the audit log. The backend refuses to serve
# traffic when it cannot guarantee audit logging (policy SEC-7).
log_dir = /var/log/bookshop
min_free_mb = 50

[payments]
provider = examplepay
api_key = lab-demo-key-0f3a9c2e-not-a-real-secret
EOF
chown "root:$APP_USER" "$CONF_DIR/bookshop.conf"
chmod 0640 "$CONF_DIR/bookshop.conf"

cat >/etc/systemd/system/bookshop.service <<EOF
[Unit]
Description=Pinewood Books storefront backend
After=network-online.target
Wants=network-online.target
RequiresMountsFor=$LOG_MNT

[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 $APP_DIR/app.py --config $CONF_DIR/bookshop.conf
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/logrotate.d/bookshop <<EOF
$LOG_MNT/audit.log {
    su $APP_USER $APP_USER
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 $APP_USER $APP_USER
}
EOF

# --- 5. nginx reverse proxy ----------------------------------------------------
log "Configuring nginx"
cat >/etc/nginx/conf.d/bookshop-upstream.conf <<'EOF'
# Backend for the Pinewood Books storefront.
upstream bookshop_backend {
    server 127.0.0.1:8080;
}
EOF

cat >/etc/nginx/sites-available/bookshop <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;

    # Friendly page for customers when the backend is unavailable.
    error_page 502 503 504 /50x.html;
    location = /50x.html {
        root /var/www/bookshop-errors;
        internal;
    }

    location / {
        proxy_pass http://bookshop_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 3s;
        proxy_read_timeout 15s;
        proxy_intercept_errors on;
    }
}
EOF

install -d -m 0755 /var/www/bookshop-errors
cat >/var/www/bookshop-errors/50x.html <<'EOF'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>We'll be right back</title>
<style>body{font-family:Georgia,serif;max-width:36rem;margin:4rem auto;padding:0 1rem;color:#2b2b2b;background:#fbf8f1}h1{color:#3c5a40}</style>
</head>
<body>
<h1>We'll be right back</h1>
<p>Our online shop is having a little trouble right now. Please try again in a few minutes.</p>
<p>Thanks for your patience.</p>
</body>
</html>
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/bookshop /etc/nginx/sites-enabled/bookshop

# --- 6. Start everything and prove it works ------------------------------------
log "Starting services"
systemctl daemon-reload
systemctl enable --now bookshop.service >/dev/null 2>&1
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
  journalctl -u bookshop -n 30 --no-pager >&2 || true
  tail -n 20 /var/log/nginx/error.log >&2 || true
  exit 1
fi

# A little normal traffic so the logs have some history.
for path in / /healthz / / /healthz /; do
  curl -s -o /dev/null "http://127.0.0.1$path" || true
done

log "Healthy baseline is up: http://127.0.0.1/ -> 200"
