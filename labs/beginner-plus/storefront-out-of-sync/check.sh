#!/usr/bin/env bash
#
# storefront-out-of-sync check: verifies the outcomes the incident ticket asks for.
# Installed in the VM as /usr/local/sbin/lab-check.  Run:  sudo lab-check
#
# The output never says *why* something fails, but this source code does hint
# at it. SPOILER WARNING: read it after you finish.

# shellcheck disable=SC2317,SC2329  # check_* functions are called indirectly via lab_check
set -uo pipefail

# shellcheck source=../../../common/lib/lab-common.sh
. /usr/local/lib/lab/lab-common.sh

STORE=http://127.0.0.1
SPOOL=/var/spool/larch
DROP=/srv/warehouse
RECEIVED=/var/lib/warehouse-sim/received # the warehouse's own records (warehouse-sim)
FEED=$DROP/outbox/stock.csv
STOCK=/var/lib/larch/stock.dat
BACKLOG=/var/lib/lab/backlog-orders.list # orders customers placed while the incident started

# header_field <file> <name>: print "name=value" from a stock file's first line.
header_field() {
  local first
  first=$(head -n 1 "$1" 2>/dev/null) || return 1
  grep -o "$2=[^ ]*" <<<"$first"
}

# 1. The warehouse publishes a fresh feed, larch-sync fetches it (as its timer
#    would), and every book on the home page shows the warehouse's quantity.
check_stock() {
  local generated home id qty _
  systemctl start warehouse-sim.service || return 1
  systemctl start larch-sync.service || return 1
  generated=$(header_field "$FEED" generated) || return 1
  [[ $(header_field "$STOCK" generated) == "$generated" ]] || return 1
  home=$(curl -s -m 5 -A lab-check "$STORE/") || return 1
  while IFS=, read -r id qty _; do
    [[ $home == *"data-book=\"$id\" data-stock=\"$qty\""* ]] || return 1
  done < <(tail -n +2 "$FEED")
}

# 2. A customer orders the book the shop has most of. Within 10 seconds the
#    order is in the warehouse's inbox (or already received).
check_new_order() {
  local book page order
  book=$(awk '!/^#/ && $2 > 0' "$STOCK" 2>/dev/null | sort -k2,2nr | awk '{ print $1; exit }')
  [[ -n $book ]] || return 1
  page=$(curl -s -m 10 -A lab-check -d "book=$book" "$STORE/order") || return 1
  [[ $page =~ data-order=\"(PB-[0-9]+-[0-9]+)\" ]] || return 1
  order=${BASH_REMATCH[1]}
  for _ in $(seq 1 20); do
    [[ -e $DROP/inbox/$order.order || -e $RECEIVED/$order.order ]] && return 0
    sleep 0.5
  done
  return 1
}

# 3. Nothing waits in the spool, every order the customers placed reached the
#    warehouse, every order filed as sent arrived, and none arrived twice.
check_every_order() {
  local id f
  [[ -z $(find "$SPOOL/outgoing" -maxdepth 1 -name '*.order' ! -newermt '-30 seconds' -print -quit) ]] ||
    return 1
  systemctl start warehouse-sim.service || return 1 # take in what's in the inbox now
  [[ -s $BACKLOG ]] || return 1
  while read -r id; do
    [[ -z $id || -e $RECEIVED/$id.order ]] || return 1
  done <"$BACKLOG"
  for f in "$SPOOL"/sent/*.order; do
    [[ -e $RECEIVED/${f##*/} ]] || return 1
  done
  [[ -z $(find "$RECEIVED" -maxdepth 1 -name '*.dup*.order' -print -quit) ]]
}

# 4. With the delivery-estimate cache empty, book pages still load in under a
#    second, and show a real estimate (in stock / out of stock), not the
#    generic fallback.
check_book_pages() {
  local id out code secs
  rm -f /var/cache/storefront/estimates/* 2>/dev/null
  for id in 2 8; do
    out=$(curl -s -m 3 -A lab-check -w '\n%{http_code} %{time_total}' "$STORE/book/$id") || return 1
    read -r code secs <<<"${out##*$'\n'}"
    [[ $code == 200 ]] || return 1
    awk -v s="$secs" 'BEGIN { exit !(s < 1.0) }' || return 1
    [[ $out == *"data-estimate=\"$id\">Delivery: In stock"* ||
      $out == *"data-estimate=\"$id\">Delivery: Out of stock"* ]] || return 1
  done
}

# 5. Everything comes back at boot, the stock sync is scheduled every few
#    minutes, and its last run worked.
check_persistence() {
  local unit next
  for unit in nginx storefront larch-ship larch-sync.timer warehouse-sim.timer; do
    systemctl is-enabled --quiet "$unit" || return 1
    systemctl is-active --quiet "$unit" || return 1
  done
  nginx -t -q 2>/dev/null || return 1
  [[ $(systemctl show -p LoadState --value larch-sync.timer) == loaded ]] || return 1
  next=$(systemctl show -p NextElapseUSecRealtime --value larch-sync.timer)
  [[ -n $next ]] || return 1
  next=$(date -d "$next" +%s) || return 1
  ((next - $(date +%s) <= 5 * 60)) || return 1
  [[ $(systemctl show -p Result --value larch-sync.service) == success ]]
}

# 6. The fix didn't throw something away or open something up.
check_guard() {
  local unit mode dir sent
  for unit in larch-sync larch-ship; do
    [[ $(systemctl show -p User --value "$unit") == larch ]] || return 1
  done
  [[ $(systemctl show -p User --value storefront) == storefront ]] || return 1
  # The vendor's binary, the warehouse key and the warehouse itself are unchanged.
  sha256sum --quiet -c /var/lib/lab/checksums || return 1
  # The key is still a secret: no permissions at all for "others".
  mode=$(stat -c %a /etc/larch/keys/warehouse.key) || return 1
  (((8#$mode & 8#007) == 0)) || return 1
  # No world-writable shortcuts.
  for dir in /etc/larch /etc/larch/keys /var/lib/larch "$SPOOL" "$SPOOL/outgoing" "$SPOOL/sent" "$DROP/inbox"; do
    [[ -d $dir && -z $(find "$dir" -maxdepth 1 ! -type l -perm -o+w -print -quit 2>/dev/null) ]] || return 1
  done
  # The order history is still there.
  sent=$(find "$SPOOL/sent" -maxdepth 1 -name '*.order' | wc -l)
  ((sent >= $(cat /var/lib/lab/sent-history.count)))
}

lab_require_root
# Give a just-restarted storefront a moment to start listening (nginx answers
# 502 until it does), so a check doesn't fail only because of the timing.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ $(lab_http_code "$STORE/healthz" 2) == 200 ]] && break
  sleep 0.5
done
lab_begin
lab_check "The shop shows the warehouse's current stock levels" check_stock \
  "lab-check has the warehouse publish fresh stock levels, then fetches them the way larch-sync.timer does."
lab_check "New orders reach the warehouse within seconds" check_new_order
lab_check "Every order placed so far reached the warehouse, exactly once" check_every_order
lab_check "Book pages load quickly, with a real delivery estimate" check_book_pages \
  "lab-check empties the delivery-estimate cache first, so it sees what a customer sees when the cache misses."
lab_check "Fixes survive a reboot" check_persistence
lab_check "Nothing important was removed or weakened" check_guard
lab_end
