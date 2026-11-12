#!/usr/bin/env bash
#
# storefront-keeps-dying setup: builds the HEALTHY baseline for web-04. Defects come later (break.sh).
#
#   host --http:80--> nginx --+--> storefront     (127.0.0.1:8080, user "storefront")
#                             |      serves every book page from an in-memory cache of
#                             |      rendered pages; storefront-refresh.timer rebuilds it
#                             |      every 10 minutes
#                             '--> search-server  (127.0.0.1:8081, user "search"), for /search
#                                    answers from the index that search-reindex.timer
#                                    rebuilds from the catalog every hour
#
#   pinewood.slice: the shop's shared memory budget (MemoryMax=640M). The storefront,
#   search-server, search-reindex and the metrics agent all run inside it, so nothing the
#   shop does can starve the OS, sshd or your login.
#
#   pinewood-agent (user "pinewood-agent"): collects metrics from /proc and from the apps
#   (statsd, UDP 127.0.0.1:8125) and pushes them to metrics-01 every 10 seconds.
#   Batches it can't push wait in a queue (16 MB at most). Status: 127.0.0.1:8126/status
#
#   Catalog: /var/lib/storefront/catalog.db (SQLite, 12,000 books)
#   kai: a platform engineer's login account
#
# There's no swap, and only the kernel's OOM killer. Provisioning fails if the smoke test
# at the end doesn't pass, so break.sh always starts from a known-good system.

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

CATALOG_DB=/var/lib/storefront/catalog.db
DAY=86400
NOW=$(date +%s)

# --- 1. Packages -------------------------------------------------------------
log "Installing nginx, python3 and sqlite3"
apt-get -y -qq -o DPkg::Lock::Timeout=600 install nginx python3 sqlite3 >/dev/null

# --- 2. A known memory baseline: no swap, and only the kernel's OOM killer ------
# The incident is tuned for this. Ubuntu's server image normally has a swap file
# and no userspace OOM killer (systemd-oomd); make sure of both.
log "Normalising memory settings (no swap, kernel OOM killer only)"
swapoff -a
sed -i -E '/^[[:space:]]*#/! { /^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+swap[[:space:]]/ s/^/# (removed by the lab setup) / }' /etc/fstab
rm -f /swap.img /swapfile
for unit in systemd-oomd.service systemd-oomd.socket; do
  if systemctl cat "$unit" >/dev/null 2>&1; then
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    systemctl mask "$unit" >/dev/null 2>&1 || true
  fi
done
systemctl daemon-reload
if [[ -n $(awk 'NR > 1' /proc/swaps) ]]; then
  echo "ERROR: swap is still active after swapoff -a" >&2
  exit 1
fi

# --- 3. Accounts ---------------------------------------------------------------
for user in storefront search pinewood-agent; do
  if ! id "$user" >/dev/null 2>&1; then
    useradd --system --user-group --home-dir /nonexistent --no-create-home \
      --shell /usr/sbin/nologin "$user"
  fi
done
if ! id kai >/dev/null 2>&1; then
  # A colleague's login account (password login disabled, like everyone's here).
  useradd --create-home --shell /bin/bash --comment "Kai Moreno (Platform team)" kai
fi

# Pinewood's internal hosts.
if ! grep -q 'metrics-01\.pinewood\.example' /etc/hosts; then
  cat >>/etc/hosts <<'EOF'
# Pinewood internal hosts
192.0.2.21   metrics-01.pinewood.example metrics-01
EOF
fi

# --- 4. The shop's memory budget ---------------------------------------------------
log "Creating the shop's memory budget (pinewood.slice)"
cat >/etc/systemd/system/pinewood.slice <<'EOF'
[Unit]
Description=Pinewood Books shop (shared memory budget)
Before=slices.target

[Slice]
# Platform standard PS-12: everything the shop runs shares this budget, so the
# shop can never starve the OS, sshd or your login of memory. The rest of the
# server's RAM is theirs.
MemoryMax=640M
EOF

# --- 5. Catalog ------------------------------------------------------------------------
log "Creating the catalog (12,000 books)"
install -d -o storefront -g storefront -m 0755 /var/lib/storefront
rm -f "$CATALOG_DB"
python3 - "$CATALOG_DB" 12000 "$((NOW - 30 * DAY))" <<'PY'
import random, sqlite3, sys, time

path, count, newest = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rng = random.Random(1987)

ADJ = ("Quiet Patient Hidden Northern Paper Salt Iron Copper Restless Distant Borrowed Lost Last "
       "Small Open Long Bright Narrow Gentle Hollow Wandering Sleeping Faithful Careful Ordinary "
       "Endless Secret Summer Autumn Morning Evening Midnight Western Inland Coastal Upland "
       "Stubborn Honest Crooked Golden").split()
NOUN = ("Kernel Ledger Lighthouse River Harbor Orchard Signal Atlas Garden Bridge Archive Compass "
        "Ferry Workshop Almanac Inventory Scheduler Engine Meadow Station Library Typewriter Kitchen "
        "Island Valley Market Tide Quarry Railway Observatory Map Letter Promise Season Shoreline "
        "Forest Hotel Theatre Bakery Clockmaker").split()
TRADE = ("Cartographer Beekeeper Weaver Ferryman Gardener Printer Bookbinder Surveyor Locksmith "
         "Glassblower Archivist Stationmaster").split()
FIRST = ("Ada Maren Priya Tomas Elif Noor Corin Ines Lars Saoirse Kenji Amara Jonas Leila Mateo "
         "Freya Idris Olga Rafael Wren Hana Bruno Dalia Emeka").split()
LAST = ("Lindqvist Okafor Holt Castellano Raman Brandt Sahin Haddad Vale Moreau Eklund Adeyemi "
        "Novak Tanaka Ferreira Quill Marsh Abara Kowalski Lund Rossi Mbeki Yilmaz Duarte").split()
TITLES = ["The {a} {n}", "{a} {n}", "The {n} and the {t}", "A {a} {t}", "Notes from the {a} {n}",
          "The {t}'s {n}"]

WORDS = {
    "adj": [w.lower() for w in ADJ],
    "adj2": ("tender funny furious patient generous unhurried wise sharp warm careful brave odd "
             "luminous stubborn honest restless gentle wry hopeful clever quiet bold sly shy "
             "moving gripping playful thoughtful fierce dreamy").split(),
    "topic": ["a family of clockmakers", "the last ferry of the season", "an orchard that refuses to die",
              "thirty years of night shifts", "a library nobody visits", "the people who keep the trains running",
              "a lighthouse and its accounts", "a river that changed course", "a bakery on a very small island",
              "a map with one road missing", "the slow work of repair", "a town that counts everything",
              "two sisters and a stubborn printing press", "a market that opens before dawn",
              "the keeper of a forgotten archive", "a radio station at the edge of the map",
              "learning to wait your turn", "a garden planted for someone else", "an engine that will not start",
              "the quiet heroes of the timetable", "a theatre that loses its roof", "a valley before the dam",
              "a hotel with one guest", "letters that arrive forty years late", "a choir without a conductor",
              "the hunt for a missing violin", "a ledger that does not add up", "a ship in a bottle",
              "the first woman to chart the shoals", "a village that moved uphill", "a strike at the mill",
              "an inheritance of bees", "a dictionary that was never finished", "the night the power failed",
              "a quarrel between two lighthouse keepers", "a cookbook written from memory"],
    "place": ["a coastal town", "the northern valleys", "a city of bridges", "an island ferry route",
              "the old harbor", "a railway junction", "a hill farm", "the edge of the forest",
              "a seaside hotel", "a mountain observatory", "a busy market square", "the river delta",
              "a border village", "a salt marsh", "a canal boat", "a fishing port", "a university town",
              "a vineyard", "a mining valley", "a lakeside cabin", "a city archive", "a tram depot"],
    "who": ["a retired surveyor", "a young archivist", "the stationmaster", "a night nurse",
            "a reluctant beekeeper", "an apprentice printer", "two old friends", "a travelling locksmith",
            "the town's only cartographer", "a grandmother with a notebook", "a schoolteacher",
            "a widowed ferryman", "a runaway apprentice", "the harbor master", "a botanist",
            "a violin maker", "a postman near retirement", "twin brothers", "a young engineer"],
    "span": ["one long summer", "a single winter", "seven years", "a week of storms", "three generations",
             "one very busy autumn", "a rainy spring", "forty days", "half a century", "one strange year"],
    "thing": ["recipes", "railway tickets", "pressed flowers", "unpaid invoices", "old photographs",
              "handwritten maps", "spare keys", "seed packets", "ferry timetables", "letters", "lists",
              "broken clocks", "borrowed books", "postcards", "tide tables", "knitting patterns",
              "shipping manifests", "school reports", "weather diaries", "jam jars", "telegrams",
              "chess problems", "bus tickets", "botanical drawings"],
    "creature": ["goose", "cat", "heron", "donkey", "dog", "goat", "owl", "parrot", "hedgehog", "fox",
                 "tortoise", "pony"],
    "time": ["dawn", "dusk", "high tide", "the first frost", "market day", "the last train", "midsummer",
             "the harvest", "closing time", "the spring thaw", "the night shift"],
    "theme": ["patience", "belonging", "work", "memory", "home", "repair", "friendship", "time",
              "grief", "luck", "courage", "forgiveness", "ambition", "loyalty", "curiosity", "change"],
    "praise": ["a small miracle", "quietly brilliant", "the best kind of slow", "funny and wise",
               "a book to press into friends' hands", "warm, odd and wonderful", "utterly absorbing",
               "a gentle triumph", "sharp, kind and surprising"],
    "deed": ["kept a list", "missed a train", "fixed something with tape", "waited for a letter",
             "planted a tree", "lost a map", "learned an instrument late", "moved to a new town",
             "kept a diary"],
    "when": ["long train journeys", "rainy weekends", "the end of a long day", "reading aloud",
             "a quiet holiday", "book clubs", "sleepless nights", "a ferry crossing"],
    "shelf": ["literary fiction", "family sagas", "nature writing", "travel", "local history",
              "maritime history", "memoir", "crime", "short stories", "poetry", "food and drink",
              "gardening", "science", "music", "rail history", "crafts", "humour", "biography",
              "social history", "folklore", "adventure", "mystery", "letters and diaries", "art"],
}
OPEN = ["A {adj} novel about {topic}, told over {span}.",
        "{author} returns with a {adj2} story of {topic}.",
        "Part memoir, part field guide: {topic}, seen from {place}.",
        "In {place}, {who} sets out to understand {topic}.",
        "Over {span}, {who} keeps a careful record of {topic}."]
MIDDLE = ["Along the way there are {thing}, {thing2} and one very {adj2} {creature}.",
          "The chapters move between {place} and {place2}, and between {time} and {time2}.",
          "Nothing goes quite to plan, and {who2} has opinions about all of it.",
          "It is a book about {theme}, and about the {thing} we keep for later.",
          "Every chapter opens with a list of {thing}, {thing2} and {thing3}.",
          "There are maps, letters and at least one {adj2} argument about {theme}.",
          "Halfway through, {who2} arrives from {place2} and changes everything.",
          "It is also, unexpectedly, a book about {theme2} and {theme3}.",
          "Somewhere between {time} and {time2}, {who2} finds {topic2}.",
          "A {creature2} steals every scene it is in."]
CLOSE = ["Readers call it {praise}.", "A {adj2} book for anyone who has ever {deed}.",
         "Perfect for {when}.", "Critics call it {praise}, and it is."]
SHELF = "Shelved under {shelf}, {shelf2} and {shelf3}."


def fill(template, author):
    out = {"author": author}
    for key, words in WORDS.items():
        picks = rng.sample(words, 3)
        out[key], out[key + "2"], out[key + "3"] = picks
    return template.format(**out)


def blurb(author):
    sentences = [fill(rng.choice(OPEN), author)]
    sentences += [fill(t, author) for t in rng.sample(MIDDLE, 5)]
    sentences += [fill(rng.choice(CLOSE), author), fill(SHELF, author)]
    text = " ".join(sentences)
    return text[0].upper() + text[1:]


db = sqlite3.connect(path)
db.executescript("""
CREATE TABLE books (
    id     INTEGER PRIMARY KEY,
    title  TEXT NOT NULL,
    author TEXT NOT NULL,
    price  TEXT NOT NULL,
    added  TEXT NOT NULL,   -- the day the book was added to the shop (UTC)
    blurb  TEXT NOT NULL
);
CREATE INDEX books_added ON books (added);
""")
rows = []
for book_id in range(1, count + 1):
    author = f"{rng.choice(FIRST)} {rng.choice(LAST)}"
    if book_id == 1:
        title, author = "The Quiet Kernel", "Ada Lindqvist"
    else:
        title = rng.choice(TITLES).format(a=rng.choice(ADJ), n=rng.choice(NOUN), t=rng.choice(TRADE))
    added = time.strftime("%Y-%m-%d", time.gmtime(newest - rng.randint(0, 700) * 86400))
    rows.append((book_id, title, author, f"{rng.randint(899, 3499) / 100:.2f}", added, blurb(author)))
db.executemany("INSERT INTO books VALUES (?, ?, ?, ?, ?, ?)", rows)
db.commit()
db.close()
PY
chown storefront:storefront "$CATALOG_DB"
chmod 0644 "$CATALOG_DB"

# --- 6. Storefront ---------------------------------------------------------------------
log "Installing the storefront"
install -d -m 0755 /opt/storefront
cat >/opt/storefront/storefront <<'PY'
#!/usr/bin/python3
"""Pinewood Books storefront (web-04).

Pages: / (home: new arrivals and a search box), /book/<id> and /healthz.
nginx sends /search to a separate service, search-server.

Every book page is rendered ahead of time and kept in memory, so a book page
never waits for the database. storefront-refresh.timer rebuilds this cache from
the catalog every 10 minutes (POST /internal/refresh). A rebuild renders a
complete new cache next to the old one and then switches over, so customers
never see a half-built cache.

The app sends a few metrics to the local metrics agent (statsd, UDP port 8125).
"""

import argparse
import html
import json
import mmap
import re
import socket
import sqlite3
import sys
import threading
import time
from array import array
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CATALOG = "/var/lib/storefront/catalog.db"
STATSD = ("127.0.0.1", 8125)
PAGE_BUDGET = 3072  # bytes set aside per book page in the cache (every page fits)

BOOK_PATH = re.compile(r"^/book/(\d+)$")
HOST = socket.gethostname()

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
  .meta {{ color: #777; font-size: .9rem; }}
  form.search input {{ font: inherit; width: 60%; }}
  footer {{ margin-top: 2rem; font-size: .8rem; color: #888; }}
</style>
</head>
<body>
<header>
  <h1><a href="/">Pinewood Books</a></h1>
  <p class="tagline">Independent booksellers since 1987</p>
</header>
{body}
<footer>Served by {host}</footer>
</body>
</html>
"""

SEARCH_FORM = ('<form class="search" action="/search" method="get">'
               '<input name="q" placeholder="Title, author or topic"> <button>Search</button></form>')


def log(message):
    print(message, flush=True)


def page(title, body):
    return PAGE.format(title=html.escape(title), body=body, host=html.escape(HOST))


def render_book(book_id, title, author, price, added, blurb):
    body = (f"<h2><em>{html.escape(title)}</em></h2>\n"
            f'<p>by {html.escape(author)} &middot; <span class="price">${price}</span></p>\n'
            f"<p>{html.escape(blurb)}</p>\n"
            f'<p class="meta">Book #{book_id} &middot; in the shop since {added}</p>\n{SEARCH_FORM}')
    return page(title, body)


def catalog():
    return sqlite3.connect(f"file:{CATALOG}?mode=ro", uri=True, timeout=10)


class PageCache:
    """Every book page, rendered, back to back in one block of memory."""

    def __init__(self):
        started = time.monotonic()
        con = catalog()
        try:
            (top,) = con.execute("SELECT COALESCE(MAX(id), 0) FROM books").fetchone()
            self.offsets = array("Q", bytes(8 * (top + 1)))
            self.lengths = array("I", bytes(4 * (top + 1)))
            self.buf = mmap.mmap(-1, (top + 1) * PAGE_BUDGET, flags=mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS)
            pos = self.books = 0
            for row in con.execute("SELECT id, title, author, price, added, blurb FROM books ORDER BY id"):
                data = render_book(*row).encode("utf-8")
                end = pos + len(data)
                if end > len(self.buf):
                    raise RuntimeError("the page cache is full")
                self.buf[pos:end] = data
                self.offsets[row[0]] = pos
                self.lengths[row[0]] = len(data)
                pos = end
                self.books += 1
            self.bytes = pos
        finally:
            con.close()
        self.seconds = time.monotonic() - started

    def get(self, book_id):
        if 0 < book_id < len(self.lengths) and self.lengths[book_id]:
            start = self.offsets[book_id]
            return self.buf[start:start + self.lengths[book_id]]
        return None

    def close(self):
        self.buf.close()


CACHE = None
REFRESH_LOCK = threading.Lock()


def refresh():
    """Build a new cache next to the current one, then switch over."""
    global CACHE
    with REFRESH_LOCK:
        new = PageCache()
        old, CACHE = CACHE, new
    if old is not None:
        time.sleep(0.5)  # let requests that are reading the old cache finish
        old.close()
    return new


def cached_page(book_id):
    for _ in range(3):
        try:
            return CACHE.get(book_id)
        except ValueError:  # that cache was just replaced; try the new one
            continue
    return None


_statsd = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)


def metric(line):
    try:
        _statsd.sendto(line.encode(), STATSD)
    except OSError:
        pass


class Handler(BaseHTTPRequestHandler):
    server_version = "storefront/4.1"

    def log_message(self, fmt, *args):
        pass  # nginx already logs every request

    def send(self, status, body, ctype="text/html; charset=utf-8", route="other"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
        metric(f"storefront.requests:1|c|#route:{route},status:{status}")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            body = json.dumps({"status": "ok", "host": HOST, "books": CACHE.books}) + "\n"
            return self.send(200, body, "application/json", "healthz")
        if path == "/":
            return self.home()
        if m := BOOK_PATH.match(path):
            data = cached_page(int(m.group(1)))
            if data is None:
                return self.send(404, page("Not found", "<p>Sorry, we don't have that book.</p>"), route="book")
            return self.send(200, data, route="book")
        return self.send(404, page("Not found", "<p>Sorry, that page doesn't exist.</p>"))

    do_HEAD = do_GET

    def do_POST(self):
        # nginx never passes /internal/ on, and always adds X-Forwarded-For.
        if self.path == "/internal/refresh" and "X-Forwarded-For" not in self.headers:
            cache = refresh()
            message = (f"refreshed {cache.books:,} books ({cache.bytes / 2**20:.1f} MB) "
                       f"in {cache.seconds:.1f} s")
            log(f"catalog cache: {message}")
            return self.send(200, message + "\n", "text/plain; charset=utf-8", "refresh")
        return self.send(404, page("Not found", "<p>Sorry, that page doesn't exist.</p>"))

    def home(self):
        con = catalog()
        try:
            rows = con.execute("SELECT id, title, author, price FROM books "
                               "ORDER BY added DESC, id DESC LIMIT 8").fetchall()
            (total,) = con.execute("SELECT COUNT(*) FROM books").fetchone()
        finally:
            con.close()
        items = "\n".join(f'  <li><a href="/book/{i}"><em>{html.escape(t)}</em></a> by {html.escape(a)} '
                          f'<span class="price">${p}</span></li>' for i, t, a, p in rows)
        body = (f"{SEARCH_FORM}\n<h2>New arrivals</h2>\n<ul>\n{items}\n</ul>\n"
                f'<p class="meta">{total:,} books in the shop.</p>')
        self.send(200, page("Pinewood Books", body), route="home")


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128


def main():
    global CACHE
    parser = argparse.ArgumentParser(description="Pinewood Books storefront")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    log("loading the catalog cache...")
    CACHE = PageCache()
    log(f"catalog cache: loaded {CACHE.books:,} books ({CACHE.bytes / 2**20:.1f} MB) in {CACHE.seconds:.1f} s")
    server = Server((args.host, args.port), Handler)
    log(f"Pinewood Books storefront listening on http://{args.host}:{args.port}")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
chmod 0755 /opt/storefront/storefront

cat >/etc/systemd/system/storefront.service <<'EOF'
[Unit]
Description=Pinewood Books storefront
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=storefront
Group=storefront
Slice=pinewood.slice
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/storefront/storefront --port 8080
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/storefront-refresh.service <<'EOF'
[Unit]
Description=Refresh the storefront's catalog cache

[Service]
Type=oneshot
User=storefront
Group=storefront
Slice=pinewood.slice
ExecStart=/usr/bin/curl -fsS -m 120 -X POST http://127.0.0.1:8080/internal/refresh
EOF

cat >/etc/systemd/system/storefront-refresh.timer <<'EOF'
[Unit]
Description=Refresh the storefront's catalog cache every 10 minutes

[Timer]
OnCalendar=*:0/10
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

# --- 7. Search -------------------------------------------------------------------------
log "Installing search"
install -d -m 0755 /opt/search
install -d -o search -g search -m 0755 /var/lib/search
cat >/opt/search/search-reindex <<'PY'
#!/usr/bin/python3
"""search-reindex: rebuild the storefront's search index from the catalog.

search-reindex.timer runs it every hour. It reads the catalog and scores every
word of every book (a word in the title counts 3, in the author's name 2, in
the description 1), then writes a new index next to the current one. When the
new index is complete, /var/lib/search/current is switched over to it, and
search-server picks it up with its next query. Older indexes are removed.

The postings file is preallocated at 4 GiB, so it never has to grow. Only the
part that holds data takes up space on disk (it's a sparse file).
"""

import collections
import itertools
import json
import os
import re
import resource
import shutil
import sqlite3
import sys
import time
from array import array

CATALOG = "/var/lib/storefront/catalog.db"
BASE = "/var/lib/search"
CURRENT = os.path.join(BASE, "current")
ARENA = 4 << 30
WORD = re.compile(r"[a-z0-9]+")
STOPWORDS = frozenset("a an and are as at be by for from in into is it its of on or that the this to "
                      "with".split())


def words(text):
    counts = collections.Counter(WORD.findall(text.lower()))
    for word in [w for w in counts if w in STOPWORDS or len(w) < 2]:
        del counts[word]
    return counts


def main():
    started = time.monotonic()
    con = sqlite3.connect(f"file:{CATALOG}?mode=ro", uri=True, timeout=30)
    try:
        books = con.execute("SELECT id, title, author, blurb FROM books").fetchall()
    finally:
        con.close()
    print(f"reindex: read {len(books):,} books from the catalog", flush=True)

    postings = {}
    for book_id, title, author, blurb in books:
        scores = words(blurb)
        for weight, text in ((2, author), (3, title)):
            for word, n in words(text).items():
                scores[word] += weight * n
        for word, score in scores.items():
            entry = (book_id, score)
            if (bucket := postings.get(word)) is None:
                postings[word] = [entry]
            else:
                bucket.append(entry)

    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    target = os.path.join(BASE, f"index-{stamp}")
    tmp = target + ".tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    os.mkdir(tmp, 0o755)
    terms = {}
    with open(os.path.join(tmp, "postings.dat"), "wb") as fh:
        fh.truncate(ARENA)  # preallocate the whole arena; only what's written uses disk space
        offset = 0
        for word in sorted(postings):
            data = array("I", itertools.chain.from_iterable(postings[word])).tobytes()
            fh.write(data)
            terms[word] = [offset, len(postings[word])]
            offset += len(data)
    with open(os.path.join(tmp, "terms.json"), "w", encoding="utf-8") as fh:
        json.dump(terms, fh, separators=(",", ":"))
    meta = {"built": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "books": len(books),
            "words": len(terms), "seconds": round(time.monotonic() - started, 1),
            "peak_mb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // 1024}
    with open(os.path.join(tmp, "meta.json"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2)
    shutil.rmtree(target, ignore_errors=True)
    os.rename(tmp, target)

    # Switch over (atomically), then remove everything but the new index and the
    # previous one, which search-server may still be using.
    try:
        previous = os.path.basename(os.path.realpath(CURRENT))
    except OSError:
        previous = None
    link = CURRENT + ".new"
    if os.path.lexists(link):
        os.unlink(link)
    os.symlink(os.path.basename(target), link)
    os.replace(link, CURRENT)
    for name in os.listdir(BASE):
        if name.startswith("index-") and name not in (os.path.basename(target), previous):
            shutil.rmtree(os.path.join(BASE, name), ignore_errors=True)
    print(f"reindex: indexed {len(books):,} books ({len(terms):,} words) in {meta['seconds']} s, "
          f"peak memory {meta['peak_mb']} MB", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
chmod 0755 /opt/search/search-reindex

cat >/opt/search/search-server <<'PY'
#!/usr/bin/python3
"""search-server: book search for the Pinewood Books storefront (web-04).

nginx sends /search?q=... here. Answers come from the search index that
search-reindex.timer rebuilds from the catalog every hour
(/var/lib/search/current points to the newest one). When a new index appears,
the next query switches to it.

The postings file is memory-mapped: the kernel reads in the parts of it that
queries actually use, and nothing else.
"""

import argparse
import html
import json
import mmap
import os
import re
import socket
import sqlite3
import sys
import threading
import time
from array import array
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

CATALOG = "/var/lib/storefront/catalog.db"
CURRENT = "/var/lib/search/current"
STATSD = ("127.0.0.1", 8125)
MAX_RESULTS = 20
WORD = re.compile(r"[a-z0-9]+")
STOPWORDS = frozenset("a an and are as at be by for from in into is it its of on or that the this to "
                      "with".split())
HOST = socket.gethostname()

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
  li {{ margin: .5rem 0; }}
  .price {{ color: #3c5a40; font-weight: bold; }}
  .meta {{ color: #777; font-size: .9rem; }}
  form.search input {{ font: inherit; width: 60%; }}
  footer {{ margin-top: 2rem; font-size: .8rem; color: #888; }}
</style>
</head>
<body>
<header><h1><a href="/">Pinewood Books</a></h1></header>
{body}
<footer>{meta}Served by {host}</footer>
</body>
</html>
"""


def log(message):
    print(message, flush=True)


def tokens(text):
    return [w for w in WORD.findall(text.lower()) if w not in STOPWORDS and len(w) > 1]


class Index:
    def __init__(self, path):
        self.path = path
        with open(os.path.join(path, "meta.json"), encoding="utf-8") as fh:
            self.meta = json.load(fh)
        with open(os.path.join(path, "terms.json"), encoding="utf-8") as fh:
            self.terms = json.load(fh)
        with open(os.path.join(path, "postings.dat"), "rb") as fh:
            self.postings = mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ)

    def scores(self, term):
        entry = self.terms.get(term)
        if entry is None:
            return {}
        offset, count = entry
        pairs = array("I")
        pairs.frombytes(self.postings[offset:offset + pairs.itemsize * 2 * count])
        return dict(zip(pairs[0::2], pairs[1::2]))

    def search(self, query):
        result = None
        for term in tokens(query):
            scores = self.scores(term)
            result = scores if result is None else {b: s + scores[b] for b, s in result.items() if b in scores}
            if not result:
                return []
        if not result:
            return []
        return sorted(result, key=lambda b: (-result[b], b))[:MAX_RESULTS]

    def close(self):
        self.postings.close()


class Searcher:
    """Keeps the newest index open, and switches when search-reindex builds a new one."""

    def __init__(self):
        self.lock = threading.Lock()
        self.index = None
        self.target = None

    def current(self):
        target = os.path.realpath(CURRENT) if os.path.lexists(CURRENT) else None
        if target != self.target:
            with self.lock:
                if target != self.target:
                    new = Index(target) if target and os.path.isdir(target) else None
                    old, self.index, self.target = self.index, new, target
                    if old is not None:
                        threading.Timer(5, old.close).start()
                    if new is not None:
                        log(f"using the index in {target}: {new.meta['books']:,} books, built {new.meta['built']}")
        return self.index


SEARCHER = Searcher()
_statsd = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)


class Handler(BaseHTTPRequestHandler):
    server_version = "search-server/1.6"

    def log_message(self, fmt, *args):
        pass

    def send(self, status, body, ctype="text/html; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
        try:
            _statsd.sendto(f"search.requests:1|c|#status:{status}".encode(), STATSD)
        except OSError:
            pass

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/healthz":
            return self.send(200, json.dumps({"status": "ok", "host": HOST}) + "\n", "application/json")
        if path != "/search":
            return self.send(404, "not found\n", "text/plain; charset=utf-8")
        q = parse_qs(query).get("q", [""])[0].strip()
        index = SEARCHER.current()
        if index is None:
            return self.send(503, PAGE.format(title="Search", body="<p>Search is being set up. Try again soon.</p>",
                                              meta="", host=HOST))
        for _ in range(3):
            try:
                ids = index.search(q) if q else []
                break
            except ValueError:  # that index was just replaced; use the new one
                index = SEARCHER.current()
        else:
            ids = []
        rows = {}
        if ids:
            con = sqlite3.connect(f"file:{CATALOG}?mode=ro", uri=True, timeout=10)
            try:
                marks = ",".join("?" * len(ids))
                for row in con.execute(f"SELECT id, title, author, price FROM books WHERE id IN ({marks})", ids):
                    rows[row[0]] = row
            finally:
                con.close()
        items = "\n".join(f'  <li><a href="/book/{i}"><em>{html.escape(rows[i][1])}</em></a> by '
                          f'{html.escape(rows[i][2])} <span class="price">${rows[i][3]}</span></li>'
                          for i in ids if i in rows)
        form = (f'<form class="search" action="/search" method="get"><input name="q" value="{html.escape(q)}"> '
                f'<button>Search</button></form>')
        if not q:
            results = ""
        elif items:
            results = f"<h2>Results for &ldquo;{html.escape(q)}&rdquo;</h2>\n<ul>\n{items}\n</ul>"
        else:
            results = f"<p>No books match &ldquo;{html.escape(q)}&rdquo;.</p>"
        meta = (f"Search index built {index.meta['built']} &middot; {index.meta['books']:,} books"
                " &middot; ")
        self.send(200, PAGE.format(title="Search", body=f"{form}\n{results}", meta=meta, host=HOST))

    do_HEAD = do_GET


class Server(ThreadingHTTPServer):
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser(description="Pinewood Books search")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8081)
    args = parser.parse_args()
    SEARCHER.current()
    server = Server((args.host, args.port), Handler)
    log(f"search-server listening on http://{args.host}:{args.port}")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
chmod 0755 /opt/search/search-server

cat >/etc/systemd/system/search.service <<'EOF'
[Unit]
Description=Pinewood Books search (search-server)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=search
Group=search
Slice=pinewood.slice
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/search/search-server --port 8081
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/search-reindex.service <<'EOF'
[Unit]
Description=Rebuild the search index from the catalog

[Service]
Type=oneshot
User=search
Group=search
Slice=pinewood.slice
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/search/search-reindex
# Platform standard PS-12: every batch job has its own memory limit, sized from
# its measured peak, and batch jobs don't swap.
# Measured peak with the 12,000-book catalog: about 80 MB.
MemoryMax=160M
MemorySwapMax=0
EOF

cat >/etc/systemd/system/search-reindex.timer <<'EOF'
[Unit]
Description=Rebuild the search index every hour

[Timer]
OnCalendar=*:45
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

# --- 8. Metrics agent --------------------------------------------------------------------
log "Installing the metrics agent"
install -d -m 0755 /opt/pinewood-agent /etc/pinewood-agent
cat >/opt/pinewood-agent/pinewood-agent <<'PY'
#!/usr/bin/python3
"""pinewood-agent 2.3.1: the Pinewood Books metrics agent.

Every push_interval seconds the agent collects a batch of samples: the
server's memory and load, the memory and CPU time of every process, the memory
of each shop service, and whatever the apps sent to its statsd port since the
last batch. Then it pushes the waiting batches to the metrics server.

Batches that can't be pushed yet wait in a queue in memory, and the agent
retries with a backoff. When the queue reaches queue_limit_mb, the oldest
batches are dropped (0 = no limit). On shutdown the queue is saved to the
spool file, and it's loaded again at start, so a restart doesn't lose metrics.

Configuration: /etc/pinewood-agent/agent.conf
Status:        curl http://127.0.0.1:8126/status
"""

import argparse
import collections
import configparser
import json
import os
import re
import signal
import socket
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "2.3.1"
HOST = socket.gethostname()
PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")
TICKS = os.sysconf("SC_CLK_TCK")
PUSH_BATCHES = 50  # batches per push request
MAX_BACKOFF = 60   # seconds between retries, at most
STARTED = time.time()
TS = re.compile(rb'"ts":\s*(\d+)')


def log(message):
    print(message, flush=True)


def mb(n):
    return f"{n / 2**20:,.1f} MB"


def batches(n):
    return f"{n:,} batch" if n == 1 else f"{n:,} batches"


def utc(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def hostport(text):
    host, _, port = text.rpartition(":")
    return host or "127.0.0.1", int(port)


class Config:
    def __init__(self, path):
        parser = configparser.ConfigParser(inline_comment_prefixes=("#", ";"))
        if not parser.read(path, encoding="utf-8"):
            sys.exit(f"pinewood-agent: can't read {path}")
        c = parser["agent"]
        self.statsd = hostport(c.get("statsd_listen", "127.0.0.1:8125"))
        self.status = hostport(c.get("status_listen", "127.0.0.1:8126"))
        self.push_url = c.get("push_url")
        self.interval = c.getfloat("push_interval", 10.0)
        self.queue_limit_mb = max(c.getfloat("queue_limit_mb", 16.0), 0.0)
        self.queue_limit = int(self.queue_limit_mb * 2**20)
        self.spool = c.get("spool", "/var/lib/pinewood-agent/queue.spool")


class Queue:
    """Batches waiting to be pushed, oldest first."""

    def __init__(self, limit):
        self.limit = limit  # bytes; 0 = no limit
        self.items = collections.deque()
        self.bytes = 0
        self.dropped = 0
        self.lock = threading.Lock()

    def add(self, batch):
        """Queue a batch. Returns how many old batches had to be dropped to make room."""
        with self.lock:
            self.items.append(batch)
            self.bytes += len(batch)
            dropped = 0
            while self.limit and self.bytes > self.limit and len(self.items) > 1:
                self.bytes -= len(self.items.popleft())
                dropped += 1
            self.dropped += dropped
            return dropped

    def oldest(self, n):
        with self.lock:
            return [self.items[i] for i in range(min(n, len(self.items)))]

    def remove(self, batches):
        with self.lock:
            for batch in batches:
                if self.items and self.items[0] is batch:
                    self.bytes -= len(self.items.popleft())

    def oldest_ts(self):
        with self.lock:
            first = self.items[0] if self.items else b""
        m = TS.search(first[:200])
        return int(m.group(1)) if m else None

    def load(self, path):
        loaded = dropped = 0
        try:
            fh = open(path, "rb")
        except FileNotFoundError:
            return 0, 0
        with fh:
            for line in fh:
                line = line.rstrip(b"\n")
                if line:
                    dropped += self.add(line)
                    loaded += 1
            # The spool is read once: don't keep it in the page cache.
            os.posix_fadvise(fh.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)
        return loaded, dropped

    def save(self, path):
        tmp = path + ".tmp"
        with self.lock, open(tmp, "wb") as fh:
            for batch in self.items:
                fh.write(batch)
                fh.write(b"\n")
            count, size = len(self.items), self.bytes
            fh.flush()
            os.fdatasync(fh.fileno())
            os.posix_fadvise(fh.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)
        os.replace(tmp, path)
        return count, size


class Collector:
    def __init__(self):
        self.lock = threading.Lock()
        self.app = {}

    def statsd(self, data):
        """Lines like name:value|type|#tag:value,tag:value (types: c = counter, g = gauge, ms = timer)."""
        for line in data.decode("utf-8", "replace").splitlines():
            name, _, rest = line.partition(":")
            value, _, rest = rest.partition("|")
            kind, _, tags = rest.partition("|")
            try:
                value = float(value)
            except ValueError:
                continue
            key = f"{name}{{{tags.lstrip('#')}}}" if tags else name
            with self.lock:
                self.app[key] = self.app.get(key, 0) + value if kind == "c" else value

    def batch(self):
        samples = {}
        with open("/proc/meminfo") as fh:
            for line in fh:
                key, value = line.split(":", 1)
                if key in ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree"):
                    samples[f"node_{key}_bytes"] = int(value.split()[0]) * 1024
        with open("/proc/loadavg") as fh:
            for name, value in zip(("load1", "load5", "load15"), fh.read().split()):
                samples[f"node_{name}"] = float(value)
        try:
            for unit in os.scandir("/sys/fs/cgroup/pinewood.slice"):
                if unit.is_dir() and unit.name.endswith(".service"):
                    with open(os.path.join(unit.path, "memory.current")) as fh:
                        samples[f'service_memory_bytes{{unit="{unit.name}"}}'] = int(fh.read())
        except OSError:
            pass
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            try:
                with open(f"/proc/{pid}/stat") as fh:
                    stat = fh.read()
            except OSError:
                continue
            comm = stat[stat.find("(") + 1:stat.rfind(")")]
            fields = stat[stat.rfind(")") + 2:].split()
            labels = f'{{comm="{comm}",pid="{pid}"}}'
            samples[f"process_rss_bytes{labels}"] = int(fields[21]) * PAGE_SIZE
            samples[f"process_cpu_seconds{labels}"] = round((int(fields[11]) + int(fields[12])) / TICKS, 2)
        with self.lock:
            app, self.app = self.app, {}
        for key, value in app.items():
            samples[f"app_{key}"] = value
        return json.dumps({"host": HOST, "ts": int(time.time()), "samples": samples},
                          separators=(",", ":")).encode()


class Agent:
    def __init__(self, config):
        self.config = config
        self.queue = Queue(config.queue_limit)
        self.collector = Collector()
        self.stopping = threading.Event()
        self.last_ok = None
        self.last_error = None

    def status(self):
        oldest = self.queue.oldest_ts()
        with open("/proc/self/statm") as fh:
            rss = int(fh.read().split()[1]) * PAGE_SIZE
        return {
            "version": VERSION, "pid": os.getpid(), "started": utc(STARTED),
            "push_url": self.config.push_url, "push_interval_seconds": self.config.interval,
            "queue_limit_mb": self.config.queue_limit_mb, "queue_limit_bytes": self.config.queue_limit,
            "queued_batches": len(self.queue.items), "queued_bytes": self.queue.bytes,
            "oldest_batch": utc(oldest) if oldest else None, "dropped_batches": self.queue.dropped,
            "last_push_ok": self.last_ok, "last_push_error": self.last_error, "rss_bytes": rss,
        }

    def push(self):
        batches = self.queue.oldest(PUSH_BATCHES)
        if not batches:
            return
        request = urllib.request.Request(
            self.config.push_url, data=b"\n".join(batches) + b"\n", method="POST",
            headers={"Content-Type": "application/x-ndjson", "User-Agent": f"pinewood-agent/{VERSION}"})
        with urllib.request.urlopen(request, timeout=5) as response:
            if not 200 <= response.status < 300:
                raise OSError(f"HTTP {response.status}")
        self.queue.remove(batches)
        self.last_ok = utc(time.time())

    def statsd_loop(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(self.config.statsd)
        sock.settimeout(1)
        while not self.stopping.is_set():
            try:
                data = sock.recv(65535)
            except socket.timeout:
                continue
            self.collector.statsd(data)

    def run(self):
        c = self.config
        limit = f"{c.queue_limit_mb:g} MB" if c.queue_limit else "none (queue_limit_mb = 0)"
        log(f"pinewood-agent {VERSION} starting: pushing to {c.push_url} every {c.interval:g} s; "
            f"queue limit: {limit}")
        loaded, dropped = self.queue.load(c.spool)
        if loaded:
            note = f"; dropped the {dropped:,} oldest (queue limit {c.queue_limit_mb:g} MB)" if dropped else ""
            log(f"loaded {batches(loaded)} from {c.spool}: {batches(len(self.queue.items))} "
                f"({mb(self.queue.bytes)}) waiting{note}")

        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, lambda *_: self.stopping.set())
        threading.Thread(target=self.statsd_loop, daemon=True).start()
        status = ThreadingHTTPServer(c.status, StatusHandler)
        status.daemon_threads = True
        status.agent = self
        threading.Thread(target=status.serve_forever, daemon=True).start()

        next_collect = next_push = time.monotonic()
        backoff = c.interval
        last_report = last_drop_report = 0.0
        dropped_since = 0
        while not self.stopping.is_set():
            now = time.monotonic()
            if now >= next_collect:
                dropped_since += self.queue.add(self.collector.batch())
                next_collect = max(next_collect + c.interval, now)
            if now >= next_push:
                try:
                    self.push()
                    backoff = c.interval
                    next_push = now if self.queue.items else now + c.interval
                except Exception as exc:  # noqa: BLE001 (any failure: retry later)
                    self.last_error = f"{utc(time.time())} {exc}"
                    next_push = now + backoff
                    backoff = min(backoff * 2, MAX_BACKOFF)
                    if now - last_report >= 60:
                        oldest = self.queue.oldest_ts()
                        log(f"push failed: {exc}; {batches(len(self.queue.items))} ({mb(self.queue.bytes)}) "
                            f"waiting, oldest from {utc(oldest) if oldest else '-'}")
                        last_report = now
            if dropped_since and now - last_drop_report >= 60:
                log(f"queue full ({c.queue_limit_mb:g} MB): dropped the oldest {batches(dropped_since)}")
                dropped_since, last_drop_report = 0, now
            self.stopping.wait(max(0.0, min(next_collect, next_push) - time.monotonic()))

        count, size = self.queue.save(c.spool)
        log(f"stopping: saved {batches(count)} ({mb(size)}) to {c.spool}")


class StatusHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path.split("?", 1)[0] != "/status":
            self.send_error(404)
            return
        body = (json.dumps(self.server.agent.status(), indent=2) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description="Pinewood Books metrics agent")
    parser.add_argument("--config", default="/etc/pinewood-agent/agent.conf")
    args = parser.parse_args()
    Agent(Config(args.config)).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
chmod 0755 /opt/pinewood-agent/pinewood-agent

cat >/etc/pinewood-agent/agent.conf <<'EOF'
# Pinewood Books metrics agent. Restart the agent after changing this file.
[agent]
# Apps send metrics here (statsd format, over UDP).
statsd_listen = 127.0.0.1:8125
# Status: curl http://127.0.0.1:8126/status
status_listen = 127.0.0.1:8126

# Where batches go, and how often.
push_url = http://metrics-01.pinewood.example:8428/api/v1/import
push_interval = 10

# Batches wait in memory until the metrics server accepts them. When the queue
# is full, the oldest batches are dropped. 0 = no limit.
queue_limit_mb = 16

# The queue is saved here on shutdown, and loaded again at start.
spool = /var/lib/pinewood-agent/queue.spool
EOF
chmod 0644 /etc/pinewood-agent/agent.conf

cat >/etc/systemd/system/pinewood-agent.service <<'EOF'
[Unit]
Description=Pinewood Books metrics agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pinewood-agent
Group=pinewood-agent
Slice=pinewood.slice
StateDirectory=pinewood-agent
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/pinewood-agent/pinewood-agent --config /etc/pinewood-agent/agent.conf
Restart=always
RestartSec=2
# Saving a long queue to the spool can take a while.
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF

for script in /opt/storefront/storefront /opt/search/search-server /opt/search/search-reindex \
  /opt/pinewood-agent/pinewood-agent; do
  python3 -m py_compile "$script"
  rm -rf "$(dirname "$script")/__pycache__"
done

# --- 9. nginx ----------------------------------------------------------------------------
log "Configuring nginx"
cat >/etc/nginx/sites-available/storefront <<'EOF'
upstream storefront_app {
    server 127.0.0.1:8080;
}

upstream search_app {
    server 127.0.0.1:8081;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_connect_timeout 5s;
    proxy_read_timeout 60s;

    location / {
        proxy_pass http://storefront_app;
    }

    location = /search {
        proxy_pass http://search_app;
    }

    # The shop's internal endpoints are for the server itself, not for customers.
    location /internal/ {
        return 404;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/storefront /etc/nginx/sites-enabled/storefront

# --- 10. Start everything and prove it works ---------------------------------------------
log "Starting services"
systemctl daemon-reload
fail() {
  echo "ERROR: baseline smoke test failed: $*. The lab can't be built." >&2
  journalctl -u storefront -u search -u search-reindex -u pinewood-agent -n 40 --no-pager >&2 || true
  exit 1
}

# Build the first search index before search-server starts.
systemctl start search-reindex.service || fail "the first search reindex failed"
systemctl enable --now pinewood-agent.service search.service storefront.service >/dev/null 2>&1
systemctl enable --now storefront-refresh.timer search-reindex.timer >/dev/null 2>&1
nginx -t -q
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx

log "Smoke test"
# Retry until the storefront is up and ONE response has both the right status and content.
code=000
healthy=false
for _ in $(seq 1 60); do
  response=$(curl -s -m 5 -w '\n%{http_code}' http://127.0.0.1/ || true)
  code=${response##*$'\n'}
  if [[ $code == 200 && $response == *"New arrivals"* ]]; then
    healthy=true
    break
  fi
  sleep 1
done
$healthy || fail "home page returned HTTP $code"

[[ $(curl -s -m 5 http://127.0.0.1/book/1 || true) == *"The Quiet Kernel"* ]] || fail "a book page is missing"
[[ $(curl -s -m 5 'http://127.0.0.1/search?q=quiet+kernel' || true) == *"The Quiet Kernel"* ]] ||
  fail "search doesn't find a book"
[[ $(curl -s -o /dev/null -m 5 -w '%{http_code}' -X POST http://127.0.0.1/internal/refresh || true) == 404 ]] ||
  fail "the internal endpoints are reachable through nginx"

# The scheduled jobs work, inside the shop's budget.
systemctl start storefront-refresh.service || fail "the catalog cache refresh failed"
systemctl start search-reindex.service || fail "the search reindex failed"
for unit in storefront search pinewood-agent search-reindex; do
  [[ $(systemctl show -p Slice --value "$unit") == pinewood.slice ]] || fail "$unit isn't in pinewood.slice"
done
[[ $(systemctl show -p MemoryMax --value pinewood.slice) == $((640 * 1024 * 1024)) ]] ||
  fail "the shop's memory budget isn't set"
[[ $(systemctl show -p NRestarts --value storefront) == 0 ]] || fail "the storefront restarted"

# The agent collects and queues, within its limit.
for _ in $(seq 1 15); do
  status=$(curl -s -m 2 http://127.0.0.1:8126/status || true)
  [[ $(jq -r '.queued_batches // 0' <<<"${status:-null}" 2>/dev/null) -ge 1 ]] && break
  sleep 1
done
[[ $(jq -r '.queue_limit_bytes' <<<"$status") == $((16 * 1024 * 1024)) ]] || fail "the agent's queue isn't limited"
[[ $(jq -r '.queued_batches' <<<"$status") -ge 1 ]] || fail "the agent isn't collecting"

log "Healthy baseline is up: http://127.0.0.1/ -> 200, search, refresh and the agent work"
