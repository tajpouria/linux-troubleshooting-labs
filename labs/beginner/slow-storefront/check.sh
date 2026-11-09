#!/usr/bin/env bash
#
# slow-storefront check: verifies the outcomes the incident ticket asks for.
# Installed in the VM as /usr/local/sbin/lab-check.  Run:  sudo lab-check
#
# The output never says *why* something fails, but this source code does hint
# at it. SPOILER WARNING: read it after you finish.

# shellcheck disable=SC2317,SC2329  # check_* functions are called indirectly via lab_check
set -uo pipefail

# shellcheck source=../../../common/lib/lab-common.sh
. /usr/local/lib/lab/lab-common.sh

STORE_URL=http://127.0.0.1/

# setup.sh measured how fast pages load on this VM while it was healthy. "Fast
# again" means at most 100 ms slower than that, and never stricter than 150 ms,
# so slow and fast host computers are judged fairly. (Each of the incident's
# problems adds well over 200 ms on its own.)
BASELINE_MS=40
if [[ -r /var/lib/lab/baseline.env ]]; then
  # shellcheck source=/dev/null
  . /var/lib/lab/baseline.env
fi
LIMIT_MS=$((BASELINE_MS + 100 > 150 ? BASELINE_MS + 100 : 150))

# page_ms: load the storefront once and print the time it took in ms.
# Fails on anything but a 200, or if it takes more than 3 seconds.
page_ms() {
  local out
  out=$(curl -s -o /dev/null -m 3 -A lab-check -w '%{http_code} %{time_total}' "$STORE_URL") || return 1
  [[ ${out%% *} == 200 ]] || return 1
  awk '{ printf "%d\n", $2 * 1000 }' <<<"$out"
}

# 1. Customers get fast pages again: median of 9 loads, after a warm-up load.
check_fast() {
  curl -s -m 3 -A lab-check "$STORE_URL" | grep -q 'Pinewood Books' || return 1
  local times=() ms
  for _ in 1 2 3 4 5 6 7 8 9; do
    ms=$(page_ms) || return 1
    times+=("$ms")
  done
  (($(printf '%s\n' "${times[@]}" | sort -n | sed -n 5p) <= LIMIT_MS))
}

# 2. No flood of requests: few concurrent client connections to the web server.
#    (The fewest seen in four samples, so a browser's few keep-alive
#    connections or a quick burst of your own curls don't count against you.)
check_traffic() {
  local n fewest=1000
  for _ in 1 2 3 4; do
    n=$(ss -Htn state established '( sport = :80 )' | wc -l)
    ((n < fewest)) && fewest=$n
    sleep 0.5
  done
  ((fewest < 8))
}

# 3. The business still gets its reindex: it's running, or it has finished.
check_reindex() {
  systemctl is-active --quiet catalog-reindex.service || [[ -e /var/lib/catalog/reindex.done ]]
}

# 4. Nothing will bring the slowness back at the next boot (or the next night).
check_persistence() {
  systemctl is-enabled --quiet storefront || return 1
  systemctl is-enabled --quiet nginx || return 1
  nginx -t -q || return 1
  # Nothing starts the load test again.
  if grep -rEqs '^[^#]*loadgen' /etc/crontab /etc/cron.d /var/spool/cron/crontabs \
    /etc/systemd/system /etc/rc.local; then
    return 1
  fi
  # The nightly batch job is configured to let the storefront go first.
  local nice quota
  nice=$(systemctl show -p Nice --value catalog-reindex.service)
  ((${nice:-0} >= 10)) || return 1
  # The storefront may use at least one full CPU: no cap, or a cap of 100% or more.
  quota=$(systemctl show -p CPUQuotaPerSecUSec --value storefront.service)
  [[ $quota == infinity || $quota =~ ^[0-9.]+s$ ]]
}

# 5. The fix didn't break or remove something else.
check_guard() {
  local user
  user=$(systemctl show -p User --value storefront)
  [[ -n $user && $user != root && $user != 0 ]] || return 1
  systemctl is-enabled --quiet catalog-reindex.timer || return 1
  id dani >/dev/null 2>&1
}

lab_require_root
lab_begin
lab_check "Storefront pages load quickly (median under ${LIMIT_MS} ms)" check_fast
lab_check "Traffic to the web server is back to normal levels" check_traffic
lab_check "Nightly catalog reindex is still running, or has finished" check_reindex \
  "Merchandising needs this run to finish today. Restarted, it resumes from its last checkpoint."
lab_check "Fixes survive a reboot" check_persistence
lab_check "Nothing important was removed or weakened" check_guard
lab_end
