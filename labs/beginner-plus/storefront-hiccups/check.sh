#!/usr/bin/env bash
#
# storefront-hiccups check: verifies the outcomes the incident ticket asks for.
# Installed in the VM as /usr/local/sbin/lab-check.  Run:  sudo lab-check
#
# The output never says *why* something fails, but this source code does hint
# at it. SPOILER WARNING: read it after you finish.

# shellcheck disable=SC2317,SC2329  # check_* functions are called indirectly via lab_check
set -uo pipefail

# shellcheck source=../../../common/lib/lab-common.sh
. /usr/local/lib/lab/lab-common.sh

STORE=http://127.0.0.1
SESSION_DIR=/var/lib/storefront/sessions
APP_LOG=/var/log/storefront/app.log
ACCESS_LOG=/var/log/nginx/access.log
TRENDING_LOG=/var/log/storefront/trending.log
ACTIVE_CARTS=/var/lib/lab/active-carts.list # 50 customers' recent carts, recorded by break.sh

# How long ago cron last wrote to the Trending job's log. Measured up front,
# because check 1 runs the job too (with its output discarded).
TRENDING_AGE=$(($(date +%s) - $(stat -c %Y "$TRENDING_LOG" 2>/dev/null || echo 0)))

# page_ms <url>: load a page once and print how long it took in ms.
# Fails on anything but a 200, or if it takes more than 3 seconds.
page_ms() {
  local out
  out=$(curl -s -o /dev/null -m 3 -A lab-check -w '%{http_code} %{time_total}' "$1") || return 1
  [[ ${out%% *} == 200 ]] || return 1
  awk '{ printf "%d\n", $2 * 1000 }' <<<"$out"
}

# 1. No freezes. They come every 5 minutes, when cron rebuilds the Trending
#    shelf, so start one rebuild now (as cron would) and load pages while it
#    runs. A healthy rebuild takes well under a second.
check_steady() {
  local job ms worst=0 deadline path
  [[ $(curl -s -m 5 -A lab-check "$STORE/") == *"Pinewood Books"* ]] || return 1
  setpriv --reuid=storefront --regid=storefront --init-groups \
    /usr/local/bin/storefront-trending >/dev/null 2>&1 &
  job=$!
  deadline=$((SECONDS + 6))
  sleep 0.3
  while ((SECONDS < deadline)); do
    for path in / /book/1 /cart; do
      ms=$(page_ms "$STORE$path") || ms=9999
      ((ms > worst)) && worst=$ms
    done
    kill -0 "$job" 2>/dev/null || break
  done
  if kill -0 "$job" 2>/dev/null; then
    kill "$job" 2>/dev/null # it rolls back: nothing changes
    wait "$job" 2>/dev/null
    return 1
  fi
  ((worst <= 1000))
}

# 2. A brand-new visitor (no cookie) adds a book and sees it in their cart.
check_new_cart() {
  local jar page
  jar=$(mktemp) || return 1
  page=$(curl -s -m 10 -A lab-check -c "$jar" -b "$jar" -L -d book=2 "$STORE/cart/add")
  rm -f "$jar"
  [[ $page == *"Paging at Midnight"* && $page == *"Total:"* ]]
}

# 3. The cart volume has plenty of room for new carts (inodes, not just bytes),
#    and nothing is left that's well past the 7-day expiry.
check_cart_storage() {
  local used
  mountpoint -q "$SESSION_DIR" || return 1
  used=$(df --output=ipcent "$SESSION_DIR" | tail -n 1 | tr -dc '0-9')
  [[ -n $used ]] && ((used <= 50)) || return 1
  [[ -z $(find "$SESSION_DIR" -maxdepth 1 -type f -name 'sess_*' -mtime +8 -print -quit) ]]
}

# 4. A cart action always writes a line to the app's log (success or error),
#    so it must show up in app.log.
check_app_log() {
  local before after
  [[ -f $APP_LOG ]] || return 1
  before=$(stat -c %s "$APP_LOG")
  curl -s -o /dev/null -m 10 -A lab-check -d book=4 "$STORE/cart/add"
  sleep 0.5
  after=$(stat -c %s "$APP_LOG")
  ((after > before))
}

# 5. nginx's access log is back to a normal size, and logrotate accepts every
#    config file and still covers both nginx's and the storefront's logs.
check_rotation() {
  local size dry
  size=$(stat -c %s "$ACCESS_LOG") || return 1
  ((size < 50 * 1024 * 1024)) || return 1
  dry=$(logrotate -d /etc/logrotate.conf 2>&1)
  grep -q '^error:' <<<"$dry" && return 1
  grep -q "considering log $ACCESS_LOG" <<<"$dry" || return 1
  grep -q "considering log $APP_LOG" <<<"$dry"
}

# After rotating the storefront's logs, the app must end up writing to the new
# app.log: either copytruncate, or a postrotate script that tells the
# storefront (not some other service) to reopen its log.
rotation_reopens_app_log() {
  local f post
  for f in /etc/logrotate.conf /etc/logrotate.d/*; do
    if [[ ! -f $f ]] || ! grep -q '/var/log/storefront' "$f"; then
      continue
    fi
    grep -Eq '^[[:space:]]*copytruncate' "$f" && return 0
    post=$(awk '/^[[:space:]]*postrotate/ { p = 1; next } /^[[:space:]]*endscript/ { p = 0 } p' "$f" |
      sed 's/#.*//')
    [[ $post == *storefront* ]] && return 0
  done
  return 1
}

# 6. Nothing brings the problems back at the next boot, or the next night.
check_persistence() {
  local unit next
  for unit in storefront nginx cron logrotate.timer storefront-session-gc.timer; do
    systemctl is-enabled --quiet "$unit" || return 1
  done
  nginx -t -q 2>/dev/null || return 1
  findmnt --fstab "$SESSION_DIR" >/dev/null || return 1
  # The expired-cart cleanup is really scheduled, at least once a day, and works.
  [[ $(systemctl show -p LoadState --value storefront-session-gc.timer) == loaded ]] || return 1
  systemctl is-active --quiet storefront-session-gc.timer || return 1
  next=$(systemctl show -p NextElapseUSecRealtime --value storefront-session-gc.timer)
  [[ -n $next ]] || return 1
  next=$(date -d "$next" +%s) || return 1
  ((next - $(date +%s) <= 25 * 3600)) || return 1
  [[ $(systemctl show -p Result --value storefront-session-gc.service) == success ]] || return 1
  rotation_reopens_app_log
}

# 7. The fix didn't throw something away or open something up.
check_guard() {
  local user name mtime missing=0 now last dir
  user=$(systemctl show -p User --value storefront)
  [[ -n $user && $user != root && $user != 0 ]] || return 1
  # Customers' recent carts are still there (unless they've expired since).
  [[ -r $ACTIVE_CARTS ]] || return 1
  now=$(date +%s)
  while read -r name mtime; do
    [[ -n $name ]] || continue
    if [[ ! -e $SESSION_DIR/$name ]] && ((now - mtime < 7 * 86400)); then
      missing=$((missing + 1))
    fi
  done <"$ACTIVE_CARTS"
  ((missing <= 5)) || return 1
  # The Trending shelf is still rebuilt on a schedule (cron, or a systemd unit
  # if you moved it), recently, and the last run worked.
  grep -rqs '^[^#]*storefront-trending' /etc/crontab /etc/cron.d /var/spool/cron/crontabs \
    /etc/systemd/system || return 1
  ((TRENDING_AGE <= 20 * 60)) || return 1
  last=$(cat "$TRENDING_LOG.1" "$TRENDING_LOG" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 1)
  [[ $last == *"trending: rebuilt"* ]] || return 1
  # No world-writable shortcuts on logs, log rotation or carts.
  for dir in /var/log/nginx /var/log/storefront /etc/logrotate.d "$SESSION_DIR"; do
    [[ -z $(find "$dir" -maxdepth 1 ! -type l -perm -o+w -print -quit 2>/dev/null) ]] || return 1
  done
}

lab_require_root
# Give a just-restarted storefront a moment to start listening (nginx answers
# 502 until it does), so a check doesn't fail only because of the timing.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ $(lab_http_code "$STORE/healthz" 2) == 200 ]] && break
  sleep 0.5
done
lab_begin
lab_check "Pages load quickly, every time (no freezes)" check_steady \
  "The freezes come and go. This check makes sure they can't happen, not just that pages are fast right now."
lab_check "New visitors can add books to their cart" check_new_cart
lab_check "Cart storage has room to spare, and expired carts are cleaned up" check_cart_storage \
  "Carts expire after 7 days without activity."
lab_check "The storefront's log shows what's happening now" check_app_log
lab_check "Web server logs are rotated" check_rotation
lab_check "Fixes survive a reboot and tonight's housekeeping" check_persistence
lab_check "Nothing important was removed or weakened" check_guard \
  "Just booted, or resumed after a long pause? Give cron 5 minutes, then check again."
lab_end
