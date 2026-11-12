#!/usr/bin/env bash
#
#  ███  SPOILER WARNING  ███
#  This script injects the storefront-keeps-dying defects. Don't read it until you've
#  solved the lab (or given up and read SOLUTIONS.md).
#
# It replays the last three weeks on web-04:
#   1. CHG-0577, 3 weeks ago, "metrics agent hardening": after the agent's queue
#      dropped batches the team needed during an earlier incident, the queue
#      limit was removed (queue_limit_mb = 0), and the agent was shielded from
#      the OOM killer (OOMScoreAdjust=-1000).
#   2. CHG-0588, 2 weeks ago: Kai added a 1 GB swap file, created with
#      `dd ... count=0 seek=1024`, which makes a sparse file. swapon refuses a
#      file with holes, so swapfile.swap fails at every boot: there's no swap.
#   3. CHG-0596, last week: Merchandising imported 28,000 holiday titles. The
#      hourly search reindex now needs ~230 MB, but its own MemoryMax is 160M,
#      sized for the old 12,000-book catalog. The kernel kills it every hour,
#      so the holiday titles never reach the search index.
#   4. CHG-0601, 5 days ago: metrics-01 went offline for a rebuild. Since then
#      the agent has kept every batch in memory, with no limit: by now most of
#      the shop's 640 MB budget (pinewood.slice). When the storefront rebuilds
#      its page cache (every 10 minutes) or the reindex runs (hourly), the slice
#      runs out, and the kernel kills the biggest process it's allowed to kill:
#      the storefront. Restarting the agent doesn't help: it saves its queue to
#      a spool file on stop and loads it again at start.
#   Red herring: search-server maps its 4 GiB (sparse) postings file, so top
#   shows ~4 GB of VIRT for it. Its RES is ~25 MB.
#
# The size of the agent's backlog is measured on this VM, so that the storefront
# fits in what's left of the budget but its refresh doesn't, on any host.
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
die() {
  echo "ERROR: break.sh: $*" >&4
  journalctl -u storefront -u pinewood-agent -n 30 --no-pager >&4 || true
  rm -rf "$ERR_FILE" "$WORK"
  exit 1
}

SLICE_CG=/sys/fs/cgroup/pinewood.slice
CATALOG_DB=/var/lib/storefront/catalog.db
SEARCH_DIR=/var/lib/search
AGENT_CONF=/etc/pinewood-agent/agent.conf
SPOOL=/var/lib/pinewood-agent/queue.spool
STORE=http://127.0.0.1
MiB=$((1024 * 1024))
DAY=86400
NOW=$(date +%s)
TODAY0=$((NOW - NOW % DAY))                    # midnight UTC today
CHG0577=$((TODAY0 - 21 * DAY + 15 * 3600))      # agent hardening
CHG0588=$((TODAY0 - 14 * DAY + 11 * 3600))      # Kai's swap file
IMPORT=$((TODAY0 - 8 * DAY + 14 * 3600))        # holiday catalog import (CHG-0596)
LAST_GOOD_INDEX=$((IMPORT - 15 * 60))           # the last hourly reindex before it
OUTAGE=$((TODAY0 - 5 * DAY + 6 * 3600))         # metrics-01 offline (CHG-0601)
BROWSER="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36"

wait_storefront() {
  local _
  for _ in $(seq 1 60); do
    [[ $(curl -s -o /dev/null -m 5 -w '%{http_code}' "$STORE/healthz") == 200 ]] && return 0
    sleep 1
  done
  return 1
}
status_kb() { awk -v k="$2:" '$1 == k { print $2 }' "/proc/$1/status"; }
# Memory in the shop's budget that the kernel can't just drop: anonymous memory and kernel memory.
slice_pinned() { awk '$1 == "anon" || $1 == "kernel" || $1 == "shmem" { s += $2 } END { print s + 0 }' "$SLICE_CG/memory.stat"; }
restarts() { systemctl show -p NRestarts --value storefront; }

say "Replaying the last three weeks on web-04..."

# Nothing scheduled runs while history is rewritten.
systemctl stop storefront-refresh.timer search-reindex.timer
for unit in storefront-refresh.service search-reindex.service; do
  for _ in $(seq 1 120); do
    [[ $(systemctl show -p ActiveState --value "$unit") == activating ]] || break
    sleep 1
  done
done

# --- Defect 1 (CHG-0577): no queue limit, and shielded from the OOM killer --------------
cat >"$AGENT_CONF" <<'EOF'
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
# CHG-0577: never drop metrics again. During INC-2390 the queue dropped exactly
# the batches we needed to work out what had happened.
queue_limit_mb = 0

# The queue is saved here on shutdown, and loaded again at start.
spool = /var/lib/pinewood-agent/queue.spool
EOF
install -d -m 0755 /etc/systemd/system/pinewood-agent.service.d
cat >/etc/systemd/system/pinewood-agent.service.d/10-resilience.conf <<'EOF'
# CHG-0577: the agent must survive memory trouble. If the OOM killer picks the
# agent, we're blind exactly when we need the metrics most.
[Service]
OOMScoreAdjust=-1000
EOF
touch -d "@$CHG0577" "$AGENT_CONF" /etc/systemd/system/pinewood-agent.service.d/10-resilience.conf \
  /etc/systemd/system/pinewood-agent.service.d
systemctl daemon-reload

# --- Defect 2 (CHG-0588): a swap file with holes ---------------------------------------------
dd if=/dev/zero of=/swapfile bs=1M count=0 seek=1024 status=none
chmod 0600 /swapfile
mkswap /swapfile || true # warns that the file has holes, and carries on
printf '%s\n' "# CHG-0588: 1 GB swap file as a safety net (Kai)" "/swapfile none swap sw 0 0" >>/etc/fstab
touch -d "@$CHG0588" /swapfile /etc/fstab
systemctl daemon-reload
systemctl start swapfile.swap || true # what happens at every boot since
[[ $(systemctl show -p ActiveState --value swapfile.swap) == failed ]]
[[ -z $(awk 'NR > 1' /proc/swaps) ]]

cat >/home/kai/.bash_history <<'EOF'
free -h
sudo dd if=/dev/zero of=/swapfile bs=1M count=0 seek=1024
ls -lh /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
echo '# CHG-0588: 1 GB swap file as a safety net (Kai)' | sudo tee -a /etc/fstab
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
exit
EOF
chown kai:kai /home/kai/.bash_history
chmod 0600 /home/kai/.bash_history
touch -d "@$((CHG0588 + 600))" /home/kai/.bash_history

# --- Defect 3 (CHG-0596): the holiday catalog, too big for the reindex's limit ----------------
python3 - "$CATALOG_DB" 28000 "$IMPORT" <<'PY'
import random, sqlite3, sys, time

path, count, imported = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rng = random.Random(596)
ADJ = ("Midwinter Frosted Snowbound Candlelit Evergreen Starlit Silver Wintry Firelit Merry Sugared "
       "Velvet Crystal Northern Hushed Glittering Frozen Twinkling Cosy Moonlit").split()
NOUN = ("Lanterns Hearth Sleigh Solstice Carols Snowfall Mittens Chimney Wreath Feast Frost Reindeer "
        "Snowglobe Bells Stockings Cocoa Pinecone Icicle Ornament Nutcracker").split()
TRADE = ("Toymaker Baker Chimney-Sweep Bellringer Glassblower Postman Skater Candlemaker Choirmaster "
         "Woodcarver").split()
FIRST = ("Ada Maren Priya Tomas Elif Noor Corin Ines Lars Saoirse Kenji Amara Jonas Leila Mateo "
         "Freya Idris Olga Rafael Wren Hana Bruno Dalia Emeka").split()
LAST = ("Lindqvist Okafor Holt Castellano Raman Brandt Sahin Haddad Vale Moreau Eklund Adeyemi "
        "Novak Tanaka Ferreira Quill Marsh Abara Kowalski Lund Rossi Mbeki Yilmaz Duarte").split()
TITLES = ["The {a} {n}", "{a} {n}", "The {n} and the {t}", "A {a} {t}", "Twelve Nights of {n}",
          "The {t}'s {n}"]
WORDS = {
    "adj": [w.lower() for w in ADJ],
    "adj2": ("cosy merry tender funny festive gentle warm hopeful sparkling wise playful heartwarming "
             "snug joyful quiet generous bright luminous clever brave sly dreamy").split(),
    "topic": ["a village that lights a lantern for every lost thing", "the longest night of the year",
              "a toyshop on the brink of closing", "a snowed-in railway station", "a carol nobody remembers",
              "the search for a missing reindeer", "a family feast that goes wrong", "a midwinter fair",
              "the last sleigh maker in the valley", "a bakery that runs out of gingerbread",
              "a choir stranded by the snow", "a letter to the north pole", "the winter the river froze",
              "a lighthouse at midwinter", "an advent calendar with one door missing", "a frost fair",
              "an orphaned snowman", "a festive market under the stars", "a hotel full of snowbound guests",
              "the solstice bonfire", "a nutcracker that walks at night", "a lost sledge", "a candle shop",
              "the twelve nights of winter", "a bell that refuses to ring", "a midnight skating race"],
    "place": ["a snowbound village", "the frozen harbor", "a mountain chalet", "a winter market",
              "the old mill", "a lantern-lit square", "a cottage in the pines", "a railway halt",
              "the northern fells", "a frost fair on the river", "a toyshop attic", "a ski lodge",
              "a ferry in the ice", "an alpine pass", "the town hall", "a candlelit chapel"],
    "who": ["a retired toymaker", "a young bellringer", "the stationmaster", "a grumpy innkeeper",
            "a lost reindeer herder", "two snowed-in strangers", "the village baker", "a choir of orphans",
            "a travelling skater", "a grandmother with a recipe box", "a postman on skis",
            "a candlemaker's apprentice", "the night watchman", "twin sisters", "a shy woodcarver"],
    "span": ["one long winter", "the twelve nights", "a single snowstorm", "advent", "the solstice week",
             "a frozen month", "one magical december", "three snowy winters"],
    "thing": ["mittens", "gingerbread", "paper lanterns", "sleigh bells", "carol sheets", "wrapped parcels",
              "pine cones", "candles", "snow globes", "hot cocoa", "festive cards", "stockings",
              "ice skates", "fruit cakes", "woollen scarves", "tree ornaments", "roasted chestnuts",
              "sugar mice", "holly wreaths", "advent calendars"],
    "creature": ["reindeer", "robin", "fox", "snow hare", "owl", "pony", "cat", "goose", "husky", "puffin"],
    "time": ["midwinter", "the first snowfall", "midnight", "the solstice", "new year's eve", "dawn",
             "the last market day", "twelfth night", "the thaw"],
    "theme": ["kindness", "home", "family", "giving", "light", "hope", "forgiveness", "belonging",
              "tradition", "wonder", "courage", "friendship"],
    "praise": ["a festive treat", "pure winter magic", "warm as a hearth", "a perfect stocking filler",
               "funny and tender", "a new holiday classic", "cosy and wise"],
    "deed": ["waited up for the first snow", "lost a mitten", "burned the gingerbread", "sung out of tune",
             "wrapped a present badly", "made a snowman", "missed the last train home"],
    "when": ["long winter evenings", "reading by the fire", "the holidays", "snowy weekends",
             "reading aloud at bedtime", "advent"],
    "shelf": ["holiday fiction", "winter tales", "festive cooking", "children's classics", "family sagas",
              "short stories", "poetry", "crafts", "humour", "mystery", "gift books", "folklore",
              "nature writing", "travel", "picture books", "memoir"],
}
OPEN = ["A {adj} novel about {topic}, told over {span}.",
        "{author} returns with a {adj2} story of {topic}.",
        "Part memoir, part recipe book: {topic}, seen from {place}.",
        "In {place}, {who} sets out to save {topic}.",
        "Over {span}, {who} keeps a careful record of {topic}."]
MIDDLE = ["Along the way there are {thing}, {thing2} and one very {adj2} {creature}.",
          "The chapters move between {place} and {place2}, and between {time} and {time2}.",
          "Nothing goes quite to plan, and {who2} has opinions about all of it.",
          "It is a book about {theme}, and about the {thing} we keep for later.",
          "Every chapter opens with a list of {thing}, {thing2} and {thing3}.",
          "There are lanterns, letters and at least one {adj2} argument about {theme}.",
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
        out[key], out[key + "2"], out[key + "3"] = rng.sample(words, 3)
    return template.format(**out)


def blurb(author):
    sentences = [fill(rng.choice(OPEN), author)]
    sentences += [fill(t, author) for t in rng.sample(MIDDLE, 5)]
    sentences += [fill(rng.choice(CLOSE), author), fill(SHELF, author)]
    text = " ".join(sentences)
    return text[0].upper() + text[1:]


db = sqlite3.connect(path)
(first,) = db.execute("SELECT MAX(id) + 1 FROM books").fetchone()
added = time.strftime("%Y-%m-%d", time.gmtime(imported))
rows = []
for book_id in range(first, first + count):
    author = f"{rng.choice(FIRST)} {rng.choice(LAST)}"
    if book_id == first + count - 1:  # the newest arrival: top of the home page
        title, author = "Midwinter Lanterns", "Saoirse Quill"
    else:
        title = rng.choice(TITLES).format(a=rng.choice(ADJ), n=rng.choice(NOUN), t=rng.choice(TRADE))
    rows.append((book_id, title, author, f"{rng.randint(799, 2999) / 100:.2f}", added, blurb(author)))
db.executemany("INSERT INTO books VALUES (?, ?, ?, ?, ?, ?)", rows)
db.commit()
db.close()
PY
chown storefront:storefront "$CATALOG_DB"
touch -d "@$IMPORT" "$CATALOG_DB"
systemctl restart storefront
wait_storefront || die "the storefront didn't start with the holiday catalog"

# Since the import, every hourly reindex hits the job's own memory limit.
systemctl start search-reindex.service || true
[[ $(systemctl show -p Result --value search-reindex.service) == oom-kill ]] ||
  die "the reindex wasn't stopped by its memory limit ($(systemctl show -p Result --value search-reindex.service))"

# So search still answers from the last index built before the import.
current=$(readlink -f "$SEARCH_DIR/current")
old_name=index-$(date -u -d "@$LAST_GOOD_INDEX" +%Y%m%dT%H%M%SZ)
for dir in "$SEARCH_DIR"/index-*; do
  [[ $dir == "$current" ]] || rm -rf "$dir"
done
mv "$current" "$SEARCH_DIR/$old_name"
ln -sfn "$old_name" "$SEARCH_DIR/current.new"
mv -T "$SEARCH_DIR/current.new" "$SEARCH_DIR/current"
python3 - "$SEARCH_DIR/$old_name/meta.json" "$LAST_GOOD_INDEX" <<'PY'
import json, sys, time
path, built = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as fh:
    meta = json.load(fh)
meta["built"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(built + 2))
with open(path, "w", encoding="utf-8") as fh:
    json.dump(meta, fh, indent=2)
PY
chown -h search:search "$SEARCH_DIR/current" "$SEARCH_DIR/$old_name"/*
touch -d "@$((LAST_GOOD_INDEX + 2))" "$SEARCH_DIR/$old_name"/* "$SEARCH_DIR/$old_name"
touch -h -d "@$((LAST_GOOD_INDEX + 2))" "$SEARCH_DIR/current"
systemctl restart search

# --- Defect 4 (CHG-0601): five days of metrics, waiting in memory -------------------------
# Measure this VM: the storefront at rest, and how much more its refresh needs.
systemctl restart storefront
wait_storefront || die "the storefront didn't come back"
sf=$(systemctl show -p MainPID --value storefront)
sleep 2
rest_kb=$(status_kb "$sf" VmRSS)
curl -s -o /dev/null -m 120 -X POST http://127.0.0.1:8080/internal/refresh
sleep 1
peak_kb=$(status_kb "$sf" VmHWM)
REFRESH_NEEDS=$(((peak_kb - rest_kb) * 1024))
((REFRESH_NEEDS > 40 * MiB)) || die "unexpected refresh size: $((REFRESH_NEEDS / MiB)) MB"

# The shop with an empty agent queue.
systemctl stop pinewood-agent
rm -f "$SPOOL"
systemctl start pinewood-agent
sleep 3
BUDGET=$(systemctl show -p MemoryMax --value pinewood.slice)
BASE=$(slice_pinned)

# A backlog that leaves the storefront 60% of what its refresh needs: enough to
# run, not enough to refresh.
backlog=$((BUDGET - BASE - REFRESH_NEEDS * 6 / 10))
((backlog > 200 * MiB)) || die "unexpected memory baseline: budget $BUDGET, in use $BASE"

# One batch every 10 seconds since metrics-01 went offline, ending now.
cat >"$WORK/spool.py" <<'PY'
"""spool.py <file> <bytes> <first ts> <last ts>: the agent's queue since the outage."""
import json, os, random, socket, sys

path, target, first, last = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
rng = random.Random(601)
host = socket.gethostname()
count = (last - first) // 10 + 1
per_batch = target // count - 70  # ~70 bytes of bookkeeping per batch in the agent

procs = []
for pid in sorted(os.listdir("/proc"), key=lambda p: int(p) if p.isdigit() else 0):
    if pid.isdigit():
        try:
            with open(f"/proc/{pid}/comm") as fh:
                procs.append((fh.read().strip(), int(pid)))
        except OSError:
            pass
units = ["pinewood-agent.service", "search.service", "storefront.service"]


def batch(i, ts, nprocs):
    progress = i / count
    s = {"node_MemTotal_bytes": 1527 * 2**20,
         "node_MemAvailable_bytes": int((1050 - 420 * progress) * 2**20) + rng.randint(-2**22, 2**22),
         "node_SwapTotal_bytes": 0, "node_SwapFree_bytes": 0,
         "node_load1": round(rng.uniform(0.0, 0.6), 2), "node_load5": round(rng.uniform(0.0, 0.4), 2),
         "node_load15": round(rng.uniform(0.0, 0.3), 2)}
    for unit in units:
        size = 30 + 420 * progress if unit.startswith("pinewood") else (100 if unit.startswith("store") else 30)
        s[f'service_memory_bytes{{unit="{unit}"}}'] = int(size * 2**20) + rng.randint(0, 2**21)
    for k in range(nprocs):
        comm, pid = procs[k % len(procs)]
        pid += 4096 * (k // len(procs))
        labels = f'{{comm="{comm}",pid="{pid}"}}'
        s[f"process_rss_bytes{labels}"] = rng.randint(0, 120) * 2**20
        s[f"process_cpu_seconds{labels}"] = round(rng.uniform(0, 5000), 2)
    s['app_storefront.requests{route:book,status:200}'] = rng.randint(0, 40)
    s['app_storefront.requests{route:home,status:200}'] = rng.randint(0, 15)
    s['app_search.requests{status:200}'] = rng.randint(0, 6)
    return json.dumps({"host": host, "ts": ts, "samples": s}, separators=(",", ":")).encode()


small = len(batch(count // 2, first, 10))
large = len(batch(count // 2, first, 60))
nprocs = max(1, round(10 + (per_batch - small) * 50 / (large - small)))
written = 0
with open(path, "wb") as fh:
    for i in range(count):
        data = batch(i, first + 10 * i, nprocs)
        fh.write(data)
        fh.write(b"\n")
        written += len(data)
print(count, written)
PY

make_backlog() {
  systemctl stop pinewood-agent # saves whatever it has; replaced below
  python3 "$WORK/spool.py" "$SPOOL" "$1" "$OUTAGE" "$((NOW - 10))" >/dev/null
  chown pinewood-agent:pinewood-agent "$SPOOL"
  chmod 0644 "$SPOOL"
  systemctl start pinewood-agent
  local _ queued
  for _ in $(seq 1 120); do
    queued=$(curl -s -m 2 http://127.0.0.1:8126/status | jq -r '.queued_bytes // 0' 2>/dev/null || true)
    ((${queued:-0} >= $1 * 9 / 10)) && return 0
    sleep 1
  done
  die "the agent didn't load its backlog"
}

# Customers who happen to be shopping while the storefront dies.
customers() {
  local _ id
  for _ in $(seq 1 "$1"); do
    id=$(((RANDOM * 32768 + RANDOM) % 40000 + 1))
    curl -s -o /dev/null -m 5 -A "$BROWSER" "$STORE/book/$id" || true
    sleep 0.3
  done
}

# Prove it: the next refresh must get the storefront killed, and the storefront
# must come back. Adjust the backlog until both are true.
attempt=0
while :; do
  attempt=$((attempt + 1))
  ((attempt <= 5)) || die "couldn't size the agent's backlog (last try: $((backlog / MiB)) MB)"
  make_backlog "$backlog"
  wait_storefront || {
    backlog=$((backlog - REFRESH_NEEDS / 4))
    continue
  }
  before=$(restarts)
  customers 25 &
  systemctl start storefront-refresh.service || true
  wait
  if ! wait_storefront; then
    backlog=$((backlog - REFRESH_NEEDS / 4))
    continue
  fi
  (($(restarts) > before)) && break
  backlog=$((backlog + REFRESH_NEEDS / 4))
done
# (Capture first: `journalctl | grep -q` can fail with SIGPIPE under pipefail.)
kernel_log=$(journalctl -k --since "-5min" --no-pager)
grep -Eq 'oom_memcg=[^,]*/pinewood\.slice,task_memcg=[^,]*/pinewood\.slice/storefront\.service' <<<"$kernel_log" ||
  die "the storefront died, but not from the slice running out of memory"

# --- This morning: the night on-call restarts the storefront, twice, and it dies again ----
sleep 5
systemctl restart storefront
wait_storefront || die "the storefront didn't come back"
sleep 5
systemctl restart storefront
wait_storefront || die "the storefront didn't come back"
customers 15
before=$(restarts)
customers 25 &
systemctl start storefront-refresh.service || true
wait
wait_storefront || die "the storefront didn't come back"
(($(restarts) > before)) || die "the storefront survived its refresh"

# Customers browse, and look for the holiday titles.
for q in midwinter+lanterns frosted+sleigh snowbound gingerbread quiet+kernel; do
  curl -s -o /dev/null -m 5 -A "$BROWSER" "$STORE/search?q=$q" || true
done
customers 10

# --- Sanity: the incident is live -------------------------------------------------------------
systemctl start storefront-refresh.timer search-reindex.timer
[[ -z $(awk 'NR > 1' /proc/swaps) ]]
systemctl is-failed --quiet swapfile.swap
[[ $(curl -s -m 5 http://127.0.0.1:8126/status | jq -r .queue_limit_bytes) == 0 ]]
[[ $(cat "/proc/$(systemctl show -p MainPID --value pinewood-agent)/oom_score_adj") == -1000 ]]
[[ $(curl -s -m 5 "$STORE/search?q=midwinter+lanterns") != *"Midwinter Lanterns"* ]]
[[ $(curl -s -m 5 "$STORE/search?q=quiet+kernel") == *"The Quiet Kernel"* ]]
[[ $(curl -s -m 5 "$STORE/") == *"Midwinter Lanterns"* ]] # the newest arrivals are on the home page

install -d -m 0755 /var/lib/lab
date -u +%FT%TZ >"$MARKER"
rm -rf "$ERR_FILE" "$WORK" "${BASH_SOURCE[0]}"

say "Done. The incident is live on web-04."
say "Next: 'vagrant snapshot save broken' (your reset point), then 'vagrant ssh'."
