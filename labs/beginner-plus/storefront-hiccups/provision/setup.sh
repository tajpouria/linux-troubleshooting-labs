#!/usr/bin/env bash
#
# storefront-hiccups setup: builds the HEALTHY baseline for web-03. Defects come later (break.sh).
#
#   host --http:80--> nginx --proxy--> storefront app (python3, 127.0.0.1:8080, user "storefront")
#                                        |-- catalog + "Trending now" shelf: SQLite, /var/lib/storefront/db
#                                        |-- shopping carts: one file per visitor, /var/lib/storefront/sessions
#                                        |   (a small dedicated volume: a 512 MB loop file)
#                                        '-- log: /var/log/storefront/app.log (SIGHUP reopens it)
#
#   Housekeeping:
#     cron, every 5 min       storefront-trending: rebuilds the shelf from nginx's access log
#     storefront-session-gc.timer, hourly: removes carts nobody touched for 7 days
#     logrotate.timer, daily  rotates nginx's and the storefront's logs
#
#   sam: a platform engineer's login account
#
# Provisioning fails if the smoke test at the end doesn't pass, so break.sh
# always starts from a known-good system.

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
DATA_DIR=/var/lib/storefront
DB_DIR=$DATA_DIR/db
SESSION_DIR=$DATA_DIR/sessions
SESSION_IMG=/var/lib/lab/storefront-sessions.img

# --- 1. Packages -------------------------------------------------------------
log "Installing nginx, python3, sqlite3, cron and logrotate"
apt-get -y -qq -o DPkg::Lock::Timeout=600 install nginx python3 sqlite3 cron logrotate >/dev/null
systemctl enable --now cron >/dev/null 2>&1

# --- 2. Accounts ---------------------------------------------------------------
if ! id storefront >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$APP_DIR" --no-create-home \
    --shell /usr/sbin/nologin storefront
fi
# The Trending job reads nginx's access log, which belongs to group adm.
usermod -aG adm storefront
if ! id sam >/dev/null 2>&1; then
  # A colleague's login account (password login disabled, like everyone's here).
  useradd --create-home --shell /bin/bash --comment "Sam Ortiz (Platform team)" sam
fi

# --- 3. Shopping-cart volume -----------------------------------------------------
# Carts live on their own small volume, so a flood of carts can't fill the root
# disk. It's a 512 MB loop-file volume on every hypervisor.
log "Creating the 512 MB shopping-cart volume for $SESSION_DIR"
install -d -m 0755 /var/lib/lab "$DATA_DIR"
install -d "$SESSION_DIR"
if ! mountpoint -q "$SESSION_DIR"; then
  rm -f "$SESSION_IMG"
  truncate -s 512M "$SESSION_IMG"
  mkfs.ext4 -q -F -L storefront-carts "$SESSION_IMG"
fi
sed -i "\\#[[:space:]]${SESSION_DIR}[[:space:]]#d" /etc/fstab
echo "$SESSION_IMG  $SESSION_DIR  ext4  loop,defaults,nofail  0  2" >>/etc/fstab
systemctl daemon-reload
mountpoint -q "$SESSION_DIR" || mount "$SESSION_DIR"
chown storefront:storefront "$SESSION_DIR"
chmod 0750 "$SESSION_DIR"

# --- 4. Catalog database -----------------------------------------------------------
log "Creating the catalog database"
install -d -o storefront -g storefront -m 0750 "$DB_DIR"
rm -f "$DB_DIR/shop.db"
python3 - "$DB_DIR/shop.db" <<'PY'
import sqlite3, sys
books = [
    ("The Quiet Kernel", "Ada Lindqvist", "18.00", "A sysadmin's memoir of thirty years of pager duty."),
    ("Paging at Midnight", "R. Okafor", "14.50", "Short stories from the night shift."),
    ("A Field Guide to Small Rivers", "Maren Holt", "22.00", "Every stream in the valley, mapped and drawn."),
    ("Letters from the Night Shift", "J. Castellano", "16.75", "A nurse writes home, one shift at a time."),
    ("The Lighthouse Ledger", "Priya Raman", "19.25", "A keeper's accounts, and the storms between them."),
    ("Load Average", "Tomas Brandt", "12.99", "A novel about a very busy summer."),
    ("Winter Inventory", "Elif Sahin", "21.50", "Counting everything in a bookshop, in January."),
    ("The Patient Scheduler", "Noor Haddad", "17.00", "Why waiting your turn is fairer than it looks."),
    ("Salt and Signal", "Corin Vale", "15.25", "Radio operators on a North Sea platform."),
    ("A Short History of Waiting", "M. Adeyemi", "13.75", "Queues, from bakeries to data centres."),
    ("The Housekeeper's Almanac", "Ines Moreau", "20.00", "Small chores that keep a big house standing."),
    ("Every Fifth Minute", "Lars Eklund", "16.00", "A detective story told in timestamps."),
]
db = sqlite3.connect(sys.argv[1])
db.executescript("""
CREATE TABLE books (
    id     INTEGER PRIMARY KEY,
    path   TEXT NOT NULL UNIQUE,   -- the book's page on the storefront
    title  TEXT NOT NULL,
    author TEXT NOT NULL,
    price  TEXT NOT NULL,
    blurb  TEXT NOT NULL
);
CREATE TABLE trending (
    rank    INTEGER PRIMARY KEY,
    book_id INTEGER NOT NULL REFERENCES books(id),
    score   REAL NOT NULL
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
""")
for i, (title, author, price, blurb) in enumerate(books, 1):
    db.execute("INSERT INTO books VALUES (?, ?, ?, ?, ?, ?)", (i, f"/book/{i}", title, author, price, blurb))
db.commit()
db.close()
PY
chown storefront:storefront "$DB_DIR/shop.db"
chmod 0640 "$DB_DIR/shop.db"

# --- 5. Storefront application ---------------------------------------------------
log "Installing the storefront app"
install -d -m 0755 "$APP_DIR"
cat >"$APP_DIR/app.py" <<'PY'
#!/usr/bin/env python3
"""Pinewood Books storefront (web-03).

Pages: / (home, with the "Trending now" shelf), /book/<id>, /cart, POST /cart/add,
and /healthz (cheap on purpose: it only says the process is up).

Data:
  * Catalog and the Trending shelf: the SQLite database DB_PATH. The shelf is
    rebuilt every 5 minutes by storefront-trending (see /etc/cron.d).
  * Shopping carts: one small file per visitor in SESSION_DIR, named after the
    visitor's pb_session cookie. storefront-session-gc.timer removes carts
    nobody has touched for 7 days.

Log: LOG_PATH. The app keeps it open. `systemctl reload storefront` (SIGHUP)
makes it reopen the file, for log rotation.
"""

import argparse
import html
import json
import os
import re
import secrets
import signal
import socket
import sqlite3
import sys
import threading
import time
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

DB_PATH = "/var/lib/storefront/db/shop.db"
SESSION_DIR = "/var/lib/storefront/sessions"
LOG_PATH = "/var/log/storefront/app.log"
COOKIE = "pb_session"
CART_DAYS = 7
DB_TIMEOUT = 20.0     # seconds to wait when the database is busy
SLOW_REQUEST = 2.0    # log requests slower than this many seconds

SID_RE = re.compile(r"^[0-9a-f]{32}$")
BOOK_PATH_RE = re.compile(r"^/book/(\d+)$")


class AppLog:
    """A log file the app keeps open. reopen() switches to a fresh file."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.RLock()
        self.fh = None
        self.reopen()

    def reopen(self):
        with self.lock:
            old, self.fh = self.fh, open(self.path, "a", buffering=1, encoding="utf-8")
            if old:
                old.close()

    def write(self, level, message):
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with self.lock:
            self.fh.write(f"{stamp} {level} {message}\n")


LOG = None


class DatabaseBusy(Exception):
    pass


def query(sql, args=()):
    """Run one read query. Returns (rows, seconds spent in the database)."""
    started = time.monotonic()
    con = sqlite3.connect(DB_PATH, timeout=DB_TIMEOUT)
    try:
        rows = con.execute(sql, args).fetchall()
    except sqlite3.OperationalError as exc:
        if "locked" in str(exc):
            raise DatabaseBusy(time.monotonic() - started) from exc
        raise
    finally:
        con.close()
    return rows, time.monotonic() - started


def session_path(sid):
    return os.path.join(SESSION_DIR, f"sess_{sid}")


def load_cart(sid):
    if not sid or not SID_RE.match(sid):
        return None
    try:
        with open(session_path(sid), encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def save_cart(sid, cart):
    """Rewrite an existing visitor's cart in place."""
    with open(session_path(sid), "r+", encoding="utf-8") as fh:
        json.dump(cart, fh)
        fh.truncate()


def new_cart(cart):
    """Store a cart for a new visitor. Returns its session id."""
    for _ in range(5):
        sid = secrets.token_hex(16)
        try:
            fd = os.open(session_path(sid), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            continue
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(cart, fh)
        return sid
    raise OSError("could not pick a free session id")


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
  body {{ font-family: Georgia, serif; max-width: 44rem; margin: 2rem auto; padding: 0 1rem;
         color: #2b2b2b; background: #fbf8f1; }}
  header {{ border-bottom: 2px solid #3c5a40; margin-bottom: 1.5rem; }}
  header a {{ color: inherit; text-decoration: none; }}
  h1 {{ color: #3c5a40; margin: 0 0 .25rem; }}
  .tagline {{ margin: 0 0 1rem; color: #666; }}
  li {{ margin: .5rem 0; }}
  .price {{ color: #3c5a40; font-weight: bold; }}
  .shelf {{ background: #f1ece0; padding: .5rem 1rem; border-radius: 6px; }}
  form {{ display: inline; }}
  button {{ font: inherit; font-size: .8rem; margin-left: .5rem; }}
  footer {{ margin-top: 2rem; font-size: .8rem; color: #888; }}
</style>
</head>
<body>
<header>
  <h1><a href="/">Pinewood Books</a></h1>
  <p class="tagline">Independent booksellers since 1987 &middot; <a href="/cart">Your cart</a></p>
</header>
{body}
<footer>Served by {host}</footer>
</body>
</html>
"""


def page(title, body):
    return PAGE.format(title=html.escape(title), body=body, host=html.escape(socket.gethostname()))


def book_item(book_id, title, author, price):
    return (f'  <li><a href="/book/{book_id}"><em>{html.escape(title)}</em></a> by {html.escape(author)} '
            f'<span class="price">${price}</span>'
            f'<form method="post" action="/cart/add"><input type="hidden" name="book" value="{book_id}">'
            f'<button>Add to cart</button></form></li>')


class Handler(BaseHTTPRequestHandler):
    server_version = "storefront/3.2"

    def log_message(self, fmt, *args):
        pass  # nginx already logs every request

    # --- helpers -------------------------------------------------------------
    def send(self, status, body, ctype="text/html; charset=utf-8", headers=()):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def session_id(self):
        cookie = SimpleCookie(self.headers.get("Cookie", ""))
        return cookie[COOKIE].value if COOKIE in cookie else None

    def busy(self):
        self.send(503, page("Busy", "<p>We're very busy right now. Please try again in a moment.</p>"))

    # --- request handling ----------------------------------------------------
    def handle_request(self):
        started = time.monotonic()
        self.db_seconds = 0.0
        try:
            self.route()
        finally:
            took = time.monotonic() - started
            if took >= SLOW_REQUEST:
                LOG.write("WARNING", f"slow request: {self.command} {self.path} took {took:.1f} s "
                                     f"({self.db_seconds:.1f} s waiting for the database)")

    def db(self, sql, args=()):
        try:
            rows, seconds = query(sql, args)
        except DatabaseBusy as exc:
            self.db_seconds += exc.args[0]
            raise
        self.db_seconds += seconds
        return rows

    def route(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            body = json.dumps({"status": "ok", "host": socket.gethostname()}) + "\n"
            return self.send(200, body, "application/json")
        if self.command == "POST":
            if path == "/cart/add":
                return self.cart_add()
            return self.send(405, "method not allowed\n", "text/plain; charset=utf-8")
        if path == "/":
            return self.home()
        if path == "/cart":
            return self.cart()
        if m := BOOK_PATH_RE.match(path):
            return self.book(int(m.group(1)))
        return self.send(404, page("Not found", "<p>Sorry, that page doesn't exist.</p>"))

    def home(self):
        try:
            picks = self.db("SELECT id, title, author, price FROM books ORDER BY id LIMIT 5")
        except DatabaseBusy:
            return self.busy()
        shelf = ""
        try:
            trending = self.db("SELECT b.id, b.title, b.author, b.price FROM trending t "
                               "JOIN books b ON b.id = t.book_id ORDER BY t.rank")
            if trending:
                shelf = ('<div class="shelf">\n<h2>Trending now</h2>\n<ul>\n'
                         + "\n".join(book_item(*row) for row in trending) + "\n</ul>\n</div>")
        except DatabaseBusy as exc:
            LOG.write("WARNING", f"trending shelf skipped: database still locked after {exc.args[0]:.1f} s")
        body = ("<h2>This week's picks</h2>\n<ul>\n" + "\n".join(book_item(*row) for row in picks)
                + "\n</ul>\n" + shelf)
        self.send(200, page("Pinewood Books", body))

    def book(self, book_id):
        try:
            rows = self.db("SELECT id, title, author, price, blurb FROM books WHERE id = ?", (book_id,))
        except DatabaseBusy:
            return self.busy()
        if not rows:
            return self.send(404, page("Not found", "<p>Sorry, we don't have that book.</p>"))
        _, title, author, price, blurb = rows[0]
        body = (f"<h2><em>{html.escape(title)}</em></h2>\n<p>by {html.escape(author)} &middot; "
                f'<span class="price">${price}</span></p>\n<p>{html.escape(blurb)}</p>\n'
                f'<form method="post" action="/cart/add"><input type="hidden" name="book" value="{book_id}">'
                f"<button>Add to cart</button></form>")
        self.send(200, page(title, body))

    def cart(self):
        cart = load_cart(self.session_id()) or {"items": {}}
        items = cart.get("items", {})
        if not items:
            return self.send(200, page("Your cart", "<h2>Your cart</h2>\n<p>Your cart is empty.</p>"))
        try:
            books = {row[0]: row[1:] for row in self.db("SELECT id, title, price FROM books")}
        except DatabaseBusy:
            return self.busy()
        lines, total = [], 0.0
        for book_id, qty in items.items():
            title, price = books.get(int(book_id), ("(no longer available)", "0"))
            total += float(price) * qty
            lines.append(f"  <li>{qty} &times; <em>{html.escape(title)}</em> "
                         f'<span class="price">${price}</span></li>')
        body = ("<h2>Your cart</h2>\n<ul>\n" + "\n".join(lines)
                + f'\n</ul>\n<p>Total: <span class="price">${total:.2f}</span></p>')
        self.send(200, page("Your cart", body))

    def cart_add(self):
        length = min(int(self.headers.get("Content-Length") or 0), 4096)
        form = parse_qs(self.rfile.read(length).decode("utf-8", "replace"))
        try:
            book_id = int(form.get("book", ["0"])[0])
        except ValueError:
            book_id = 0
        try:
            if not self.db("SELECT 1 FROM books WHERE id = ?", (book_id,)):
                return self.send(400, page("Not found", "<p>Sorry, we don't have that book.</p>"))
        except DatabaseBusy:
            return self.busy()

        sid = self.session_id()
        cart = load_cart(sid)
        headers = [("Location", "/cart")]
        try:
            if cart is not None:
                cart["items"][str(book_id)] = cart["items"].get(str(book_id), 0) + 1
                cart["updated"] = int(time.time())
                save_cart(sid, cart)
                LOG.write("INFO", f"cart: session {sid[:8]}... added book {book_id} "
                                  f"({sum(cart['items'].values())} items)")
            else:
                now = int(time.time())
                sid = new_cart({"items": {str(book_id): 1}, "created": now, "updated": now})
                headers.append(("Set-Cookie", f"{COOKIE}={sid}; Path=/; Max-Age={CART_DAYS * 86400}; "
                                              "HttpOnly; SameSite=Lax"))
                LOG.write("INFO", f"cart: new session {sid[:8]}... added book {book_id}")
        except OSError as exc:
            LOG.write("ERROR", f"cart: could not save the cart for a "
                               f"{'returning' if cart is not None else 'new'} visitor: {exc}")
            return self.send(500, page("Sorry", "<h2>Sorry, we couldn't save your cart</h2>\n"
                                                "<p>Something went wrong on our side. Please try again later.</p>"))
        self.send(303, page("Added", '<p>Added. <a href="/cart">See your cart</a>.</p>'), headers=headers)

    do_GET = do_HEAD = do_POST = handle_request


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128


def main():
    global LOG
    parser = argparse.ArgumentParser(description="Pinewood Books storefront")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    LOG = AppLog(LOG_PATH)

    def reopen_log(*_):
        LOG.reopen()
        LOG.write("INFO", f"reopened {LOG_PATH} (SIGHUP)")

    signal.signal(signal.SIGHUP, reopen_log)
    server = Server((args.host, args.port), Handler)
    LOG.write("INFO", f"Pinewood Books storefront listening on http://{args.host}:{args.port} (pid {os.getpid()})")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
chmod 0755 "$APP_DIR/app.py"
python3 -m py_compile "$APP_DIR/app.py"
rm -rf "$APP_DIR/__pycache__"

cat >/etc/systemd/system/storefront.service <<EOF
[Unit]
Description=Pinewood Books storefront
After=network-online.target
Wants=network-online.target
RequiresMountsFor=$SESSION_DIR

[Service]
Type=simple
User=storefront
Group=storefront
# Creates /var/log/storefront, owned by the service user.
LogsDirectory=storefront
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 $APP_DIR/app.py --port 8080
# The app reopens its log file on SIGHUP.
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

# --- 6. Trending shelf (cron, every 5 minutes) ------------------------------------
log "Installing the Trending shelf job"
cat >/usr/local/bin/storefront-trending <<'PY'
#!/usr/bin/env python3
"""storefront-trending: rebuild the storefront's "Trending now" shelf.

cron runs it every 5 minutes (/etc/cron.d/storefront-trending). It reads the
web server's access log, scores each book by its page views (a view an hour
ago counts for more than one from this morning; bots don't count), and stores
the top 5 in the shop database.

The whole rebuild runs in one exclusive database transaction. cron starts a
new run every 5 minutes whether or not the previous one has finished, and the
lock makes sure two runs never overlap, and that the shop never shows a
half-built shelf.
"""

import argparse
import collections
import datetime
import re
import signal
import sqlite3
import sys
import time

DB_PATH = "/var/lib/storefront/db/shop.db"
ACCESS_LOG = "/var/log/nginx/access.log"
SHELF_SIZE = 5

LINE = re.compile(r'^(?P<ip>\S+) - \[(?P<time>[^\]]+)\] "(?P<method>[A-Z]+) (?P<path>\S+)[^"]*" '
                  r'(?P<status>\d{3}) .*"(?P<agent>[^"]*)"$')
BOTS = re.compile(r"bot|crawl|spider|slurp|monitor|scan", re.IGNORECASE)
TIME_FORMAT = "%d/%b/%Y:%H:%M:%S %z"


def main():
    parser = argparse.ArgumentParser(description='Rebuild the "Trending now" shelf')
    parser.add_argument("--log", default=ACCESS_LOG, help="access log to read (default: %(default)s)")
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit("trending: stopped, nothing changed"))

    started = time.monotonic()
    now = datetime.datetime.now(datetime.timezone.utc)
    db = sqlite3.connect(DB_PATH, timeout=300, isolation_level=None)
    db.execute("BEGIN EXCLUSIVE")
    try:
        scores = collections.Counter()
        lines = views = 0
        with open(args.log, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                lines += 1
                m = LINE.match(line)
                if not m or m["method"] != "GET" or m["status"] != "200":
                    continue
                if BOTS.search(m["agent"]):
                    continue
                when = datetime.datetime.strptime(m["time"], TIME_FORMAT)
                book = db.execute("SELECT id FROM books WHERE path = ?", (m["path"],)).fetchone()
                if book is None:
                    continue
                hours_ago = max((now - when).total_seconds() / 3600, 0)
                scores[book[0]] += 1 / (1 + hours_ago)
                views += 1
        db.execute("DELETE FROM trending")
        for rank, (book_id, score) in enumerate(scores.most_common(SHELF_SIZE), 1):
            db.execute("INSERT INTO trending (rank, book_id, score) VALUES (?, ?, ?)", (rank, book_id, score))
        db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('trending_updated', ?)",
                   (now.strftime("%Y-%m-%dT%H:%M:%SZ"),))
        db.execute("COMMIT")
    except BaseException:
        db.execute("ROLLBACK")
        raise
    finally:
        db.close()
    print(f"{now:%Y-%m-%dT%H:%M:%SZ} trending: rebuilt from {lines:,} log lines "
          f"({views:,} book views) in {time.monotonic() - started:.1f} s", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
chmod 0755 /usr/local/bin/storefront-trending
python3 -m py_compile /usr/local/bin/storefront-trending
rm -rf /usr/local/bin/__pycache__

cat >/etc/cron.d/storefront-trending <<'EOF'
# Rebuild the storefront's "Trending now" shelf from the web server's access log.
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

*/5 * * * *  storefront  /usr/local/bin/storefront-trending >>/var/log/storefront/trending.log 2>&1
EOF
chmod 0644 /etc/cron.d/storefront-trending

# --- 7. Expired-cart cleanup (systemd timer, hourly) ---------------------------------
log "Installing the expired-cart cleanup"
cat >/usr/local/bin/storefront-session-gc <<'EOF'
#!/bin/bash
# storefront-session-gc: remove shopping carts nobody has touched for 7 days.
# Run by storefront-session-gc.timer.
set -euo pipefail
dir=/var/lib/storefront/sessions
removed=$(find "$dir" -maxdepth 1 -type f -name 'sess_*' -mtime +7 -print -delete | wc -l)
kept=$(find "$dir" -maxdepth 1 -type f -name 'sess_*' | wc -l)
echo "removed $removed expired carts, kept $kept"
EOF
chmod 0755 /usr/local/bin/storefront-session-gc

cat >/etc/systemd/system/storefront-session-gc.service <<EOF
[Unit]
Description=Remove expired shopping carts (Pinewood Books storefront)
RequiresMountsFor=$SESSION_DIR

[Service]
Type=oneshot
User=storefront
Group=storefront
ExecStart=/usr/local/bin/storefront-session-gc
EOF

cat >/etc/systemd/system/storefront-session-gc.timer <<'EOF'
[Unit]
Description=Remove expired shopping carts every hour

[Timer]
OnCalendar=hourly

[Install]
WantedBy=timers.target
EOF

# --- 8. Log rotation for the storefront's own logs -------------------------------------
cat >/etc/logrotate.d/storefront <<'EOF'
# Pinewood Books storefront logs.
/var/log/storefront/*.log {
	weekly
	rotate 4
	missingok
	notifempty
	create 0640 storefront adm
	sharedscripts
	postrotate
		# The app keeps its log open: tell it to reopen the new file.
		systemctl reload storefront.service >/dev/null 2>&1 || true
	endscript
}
EOF
chmod 0644 /etc/logrotate.d/storefront

# --- 9. nginx reverse proxy ----------------------------------------------------------
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

# --- 10. Start everything and prove it works ---------------------------------------------
log "Starting services"
systemctl daemon-reload
systemctl enable --now storefront.service >/dev/null 2>&1
systemctl enable --now storefront-session-gc.timer >/dev/null 2>&1
systemctl enable --now logrotate.timer >/dev/null 2>&1
nginx -t -q
systemctl enable nginx >/dev/null 2>&1
# Restart, not reload: after a reload, the old workers (stock config, stock log
# format) keep answering for a moment, and the smoke test below would hit them.
systemctl restart nginx

fail() {
  echo "ERROR: baseline smoke test failed: $*. The lab can't be built." >&2
  journalctl -u storefront -n 30 --no-pager >&2 || true
  tail -n 20 /var/log/storefront/app.log /var/log/nginx/error.log >&2 || true
  exit 1
}

log "Smoke test"
# Retry until the app is up and ONE response has both the right status and the
# storefront's content.
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
$healthy || fail "home page returned HTTP $code"

# Some visitors browse books, so the Trending shelf has something to show.
for id in 3 3 3 7 7 12 1 5 3 7; do
  curl -s -o /dev/null -m 5 "http://127.0.0.1/book/$id" -A "Mozilla/5.0 (smoke test)" || true
done
# Run it exactly as cron does, so trending.log belongs to the storefront user.
runuser -u storefront -- /bin/sh -c \
  '/usr/local/bin/storefront-trending >>/var/log/storefront/trending.log 2>&1' ||
  fail "the Trending job didn't run"
[[ $(curl -s -m 5 http://127.0.0.1/ || true) == *"Trending now"* ]] || fail "the Trending shelf is missing"

# A new visitor adds a book to the cart, and sees it in the cart.
jar=$(mktemp)
cart=$(curl -s -m 5 -c "$jar" -b "$jar" -L -d book=1 http://127.0.0.1/cart/add || true)
rm -f "$jar"
[[ $cart == *"The Quiet Kernel"* ]] || fail "adding a book to a new cart didn't work"
compgen -G "$SESSION_DIR/sess_*" >/dev/null || fail "no cart file was written"
grep -q 'cart: new session' /var/log/storefront/app.log || fail "the app log isn't being written"

# Housekeeping works.
systemctl start storefront-session-gc.service || fail "the expired-cart cleanup failed"
[[ -n $(systemctl show -p NextElapseUSecRealtime --value storefront-session-gc.timer) ]] ||
  fail "the expired-cart cleanup isn't scheduled"
# (Capture the output first: `logrotate | grep -q` can fail with SIGPIPE under pipefail.)
dry_run=$(logrotate -d /etc/logrotate.conf 2>&1 || true)
if grep -q '^error:' <<<"$dry_run"; then
  fail "logrotate reports errors"
fi
grep -q 'considering log /var/log/nginx/access.log' <<<"$dry_run" ||
  fail "nginx's logs aren't covered by log rotation"
grep -q 'considering log /var/log/storefront/app.log' <<<"$dry_run" ||
  fail "the storefront's logs aren't covered by log rotation"

log "Healthy baseline is up: http://127.0.0.1/ -> 200, carts and housekeeping work"
