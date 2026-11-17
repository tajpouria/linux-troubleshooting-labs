#!/usr/bin/env bash
#
#  ███  SPOILER WARNING  ███
#  This script injects the storefront-out-of-sync defects. Don't read it until
#  you've solved the lab (or given up and read SOLUTIONS.md).
#
# It replays the last few days on web-05:
#   1. CHG-0611, 3 days ago: Sam tested larch 4.2's delivery quotes against
#      Larch's sandbox, as the storefront user, with a personal config file,
#      ~storefront/.larch.conf, that points quotes at the sandbox's rate-service
#      socket. larch reads $HOME/.larch.conf *instead of* /etc/larch/larch.conf.
#      The sandbox socket is long gone, so every quote tries to connect 4 times
#      with 0.5 + 1 + 2 s of sleep in between, then falls back to a generic
#      estimate: book pages take 3.5 s whenever the 5-minute estimate cache misses.
#   2. CHG-0618, yesterday 16:00: Security rotated the warehouse key with a
#      script that recreated /etc/larch/keys as root:root 0700. The key file is
#      root:larch 0640 and looks right, but larch can't get into the directory
#      (EACCES), so `larch sync` fails with E2041 every 2 minutes, and the shop
#      still shows yesterday afternoon's stock levels.
#   3. This morning: Sam ran `sudo -u larch larch admin reconcile` in tmux. It
#      took the spool lock (flock) and is still waiting at its y/N prompt (a
#      read() on its terminal). Sam went off shift. larch-ship blocks in
#      flock(LOCK_EX) forever, and new orders pile up in /var/spool/larch/outgoing.
#      Answering y would ship 3 orders twice: the warehouse has them, and only
#      their acknowledgements were lost.
#   Red herring: an strace of larch is full of ENOENT. That's larch searching for
#   its config file, and the dynamic loader looking for optional files. Normal.
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

STORE=http://127.0.0.1
SPOOL=/var/spool/larch
DROP=/srv/warehouse
SIM_STATE=/var/lib/warehouse-sim
DAY=86400
NOW=$(date +%s)
TODAY0=$((NOW - NOW % DAY))                    # midnight UTC today
CHG0611=$((TODAY0 - 3 * DAY + 14 * 3600 + 1200)) # 3 days ago, 14:20: the larch 4.2 upgrade
ROTATION=$((TODAY0 - DAY + 16 * 3600))         # yesterday 16:00: the key rotation
LAST_SYNC=$((ROTATION - 120))                  # the last stock sync that worked

say "Replaying the last few days on web-05..."

# Nothing scheduled runs while history is rewritten.
systemctl stop larch-sync.timer warehouse-sim.timer
for _ in $(seq 1 60); do
  busy=false
  for unit in larch-sync.service warehouse-sim.service; do
    [[ $(systemctl show -p ActiveState --value "$unit") == activating ]] && busy=true
  done
  $busy || break
  sleep 1
done

# --- Two weeks of orders: all shipped, all received, all acknowledged, except
#     the acknowledgements for 3 orders from two days ago, which got lost -------
python3 - "$SPOOL/sent" "$SIM_STATE/received" "$DROP/acks" "$TODAY0" /var/lib/lab/unacked-orders.list <<'PY'
import os, pwd, random, sys, time
sent, received, acks, today0, unacked_path = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
larch = pwd.getpwnam("larch")
rng = random.Random(611)
day = 86400
first, last = 3700, 4100            # setup.sh's smoke-test order was 4101, this morning
start, end = today0 - 14 * day, today0 - day + 21 * 3600
lost_day = today0 - 2 * day
stamp = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
times = sorted(rng.uniform(start, end) for _ in range(first, last + 1))
lost = []
for seq, t in zip(range(first, last + 1), times):
    t = int(t)
    oid = f"PB-{time.strftime('%Y%m%d', time.gmtime(t))}-{seq:04d}"
    body = f"order {oid}\nplaced {stamp(t)}\nbook {rng.randint(1, 12)}\nqty 1\n"
    for path, at, owner, mode in ((f"{sent}/{oid}.order", t + 2, larch, 0o640),
                                  (f"{received}/{oid}.order", t + 40, None, 0o600)):
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        os.chmod(path, mode)
        if owner:
            os.chown(path, owner.pw_uid, owner.pw_gid)
        os.utime(path, (at, at))
    if lost_day + 8 * 3600 <= t < lost_day + 20 * 3600 and len(lost) < 3:
        lost.append(oid)            # the warehouse got it; the acknowledgement got lost
        continue
    ack = f"{acks}/{oid}.ack"
    with open(ack, "w", encoding="utf-8") as fh:
        fh.write(f"received {stamp(t + 40)}\n")
    os.chmod(ack, 0o644)
    os.utime(ack, (t + 40, t + 40))
assert len(lost) == 3, lost
with open(unacked_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lost) + "\n")
PY
chmod 0600 /var/lib/lab/unacked-orders.list
find "$SPOOL/sent" -maxdepth 1 -name '*.order' | wc -l >/var/lib/lab/sent-history.count
chmod 0600 /var/lib/lab/sent-history.count

# --- Defect 1 (CHG-0611, 3 days ago): Sam's sandbox test config, left behind -------
cat >/var/lib/storefront/.larch.conf <<'EOF'
# Trying larch 4.2 quotes against Larch's sandbox before the upgrade (CHG-0611). -- Sam
account      = PINEWOOD-SANDBOX
stock_file   = /var/lib/larch/stock.dat
rates_socket = /run/larch-sandbox/rates.sock
EOF
chown storefront:storefront /var/lib/storefront/.larch.conf
chmod 0644 /var/lib/storefront/.larch.conf
touch -d "@$CHG0611" /var/lib/storefront/.larch.conf

# --- Defect 2 (CHG-0618, yesterday 16:00): the key rotation ----------------------
# Stock levels as of the last sync that worked, yesterday at 15:58.
python3 - "$SIM_STATE/stock.json" /var/lib/larch/stock.dat "$LAST_SYNC" <<'PY'
import json, os, pwd, sys, time
state, out, at = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(state, encoding="utf-8") as fh:
    stock = json.load(fh)
lines = [f"# larch stock 2 generated={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(at - 4))} synced={at}"]
for book, s in sorted(stock.items(), key=lambda kv: int(kv[0])):
    lines.append(f"{book} {s['qty']} {s['lead'] if s['qty'] > 0 else s['restock']}")
with open(out, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
larch = pwd.getpwnam("larch")
os.chown(out, larch.pw_uid, larch.pw_gid)
os.chmod(out, 0o644)
os.utime(out, (at, at))
# Since then, the warehouse has sold out of three titles and sold copies of others.
for book, qty in {"2": 0, "6": 0, "9": 0, "3": 15, "7": 9, "12": 13, "1": 11}.items():
    stock[book]["qty"] = qty
with open(state, "w", encoding="utf-8") as fh:
    json.dump(stock, fh, indent=1)
PY

# Security's rotation script recreated the keys directory, root-only.
secret=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
printf '%s\n' "$secret" >"$SIM_STATE/secret"
rm -rf /etc/larch/keys
install -d -o root -g root -m 0700 /etc/larch/keys
printf 'account=PINEWOOD-0042\nsecret=%s\n' "$secret" >/etc/larch/keys/warehouse.key
unset secret
chown root:larch /etc/larch/keys/warehouse.key
chmod 0640 /etc/larch/keys/warehouse.key
touch -d "@$ROTATION" /etc/larch/keys/warehouse.key /etc/larch/keys
sha256sum /etc/larch/keys/warehouse.key >>/var/lib/lab/checksums

systemctl start warehouse-sim.service # a fresh feed, signed with the new key
if runuser -u larch -- /opt/larch/bin/larch sync 2>"$ERR_FILE.sync"; then
  echo "larch sync still works" >&2
  false
fi
grep -q E2041 "$ERR_FILE.sync"
rm -f "$ERR_FILE.sync"

# History is written. Housekeeping is back on schedule (and failing).
systemctl start warehouse-sim.timer larch-sync.timer

# --- Defect 3 (this morning): Sam's reconcile, waiting at its prompt in tmux --------
rm -f /var/cache/storefront/estimates/*
# (fds 3 and 4 are vagrant's terminal: the tmux server mustn't keep them open.)
sam_tmux() { runuser -u sam -- tmux "$@" </dev/null >/dev/null 2>&1 3>&- 4>&-; }
sam_type() {
  sam_tmux send-keys -t larch "$1" Enter
  sleep 1
}
sam_tmux new-session -d -s larch -x 150 -y 45 -c /home/sam
sleep 1
sam_type 'larch version'
sam_type 'systemctl is-active larch-ship larch-sync.timer'
sam_type 'sudo -u larch larch admin reconcile'

reconcile=""
for _ in $(seq 1 30); do
  reconcile=$(pgrep -u larch -f 'larch admin reconcile' || true)
  if [[ -n $reconcile ]] && grep -q "FLOCK .* $reconcile " /proc/locks &&
    [[ $(runuser -u sam -- tmux capture-pane -p -t larch 3>&- 4>&-) == *"[y/N]"* ]]; then
    break
  fi
  reconcile=""
  sleep 1
done
[[ -n $reconcile ]]

# --- Customers keep shopping ---------------------------------------------------------
: >/var/lib/lab/backlog-orders.list
for book in 6 3 9 11 1; do # 6 and 9 are sold out at the warehouse, but not on the site
  page=$(curl -s -m 10 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -d "book=$book" "$STORE/order")
  [[ $page =~ data-order=\"(PB-[0-9]+-[0-9]+)\" ]]
  echo "${BASH_REMATCH[1]}" >>/var/lib/lab/backlog-orders.list
  sleep 2
done
chmod 0600 /var/lib/lab/backlog-orders.list
for path in /book/3 /book/7 /book/12; do
  curl -s -o /dev/null -m 30 -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_6)" "$STORE$path" &
done
wait

systemctl start larch-sync.service || true # (fails, like every run since yesterday)

# --- Sanity: the incident is live -------------------------------------------------------
[[ $(systemctl show -p Result --value larch-sync.service) == exit-code ]]
(($(find "$SPOOL/outgoing" -maxdepth 1 -name '*.order' | wc -l) == 5))
kill -0 "$reconcile"
start=$(date +%s%N)
curl -s -o /dev/null -m 30 "$STORE/book/5"
(($(date +%s%N) - start > 3000000000))
[[ $(curl -s -m 5 "$STORE/book/5") == *"Usually ships in 3-5 working days."* ]]
[[ $(curl -s -m 5 "$STORE/") == *'data-book="9" data-stock="5"'* ]]

install -d -m 0755 /var/lib/lab
date -u +%FT%TZ >"$MARKER"
rm -f "$ERR_FILE" "${BASH_SOURCE[0]}"

say "Done. The incident is live on web-05."
say "Next: 'vagrant snapshot save broken' (your reset point), then 'vagrant ssh'."
