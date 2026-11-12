#!/usr/bin/env bash
#
# storefront-keeps-dying check: verifies the outcomes the incident ticket asks for.
# Installed in the VM as /usr/local/sbin/lab-check.  Run:  sudo lab-check
#
# The output never says *why* something fails, but this source code does hint
# at it. SPOILER WARNING: read it after you finish.

# shellcheck disable=SC2317,SC2329  # check_* functions are called indirectly via lab_check
set -uo pipefail

# shellcheck source=../../../common/lib/lab-common.sh
. /usr/local/lib/lab/lab-common.sh

STORE=http://127.0.0.1
AGENT_STATUS=http://127.0.0.1:8126/status
AGENT_CONF=/etc/pinewood-agent/agent.conf
MiB=$((1024 * 1024))
SHOP_UNITS=(storefront.service search.service pinewood-agent.service search-reindex.service)

# wait_storefront: give a storefront that was just (re)started time to load its cache.
wait_storefront() {
  local _
  for _ in $(seq 1 30); do
    [[ $(lab_http_code "$STORE/healthz" 2) == 200 ]] && return 0
    sleep 0.5
  done
  return 1
}

random_book() { echo $(((RANDOM * 32768 + RANDOM) % 40000 + 1)); }

# 1. The storefront survives its catalog refresh: run the refresh now, as the
#    timer does, keep loading pages while it runs, and make sure the storefront
#    process was never replaced.
check_refresh() {
  local pid restarts job bad=0
  wait_storefront || return 1
  pid=$(systemctl show -p MainPID --value storefront)
  restarts=$(systemctl show -p NRestarts --value storefront)
  timeout 120 systemctl start storefront-refresh.service &
  job=$!
  sleep 0.2
  while kill -0 "$job" 2>/dev/null; do
    [[ $(lab_http_code "$STORE/book/$(random_book)" 3) == 200 ]] || bad=$((bad + 1))
    sleep 0.1
  done
  wait "$job" || return 1
  [[ $(lab_http_code "$STORE/book/$(random_book)" 3) == 200 ]] || return 1
  ((bad == 0)) || return 1
  [[ $(systemctl show -p MainPID --value storefront) == "$pid" ]] || return 1
  [[ $(systemctl show -p NRestarts --value storefront) == "$restarts" ]]
}

# 2. The hourly reindex succeeds (run it now), and search then finds both a
#    holiday title and an old favourite.
check_search() {
  local page
  wait_storefront
  timeout 300 systemctl start search-reindex.service || return 1
  [[ $(systemctl show -p Result --value search-reindex.service) == success ]] || return 1
  sleep 0.5
  page=$(curl -s -m 10 "$STORE/search?q=midwinter+lanterns")
  [[ $page == *"Midwinter Lanterns"* ]] || return 1
  page=$(curl -s -m 10 "$STORE/search?q=quiet+kernel")
  [[ $page == *"The Quiet Kernel"* ]]
}

# The agent may never use more than a sane share of the shop's budget...
agent_bounded() {
  local status limit queued cg anon
  systemctl is-active --quiet pinewood-agent || return 1
  status=$(curl -s -m 5 "$AGENT_STATUS") || return 1
  limit=$(jq -r '.queue_limit_bytes' <<<"$status") || return 1
  queued=$(jq -r '.queued_bytes' <<<"$status") || return 1
  [[ $limit =~ ^[0-9]+$ && $queued =~ ^[0-9]+$ ]] || return 1
  ((limit > 0 && limit <= 128 * MiB && queued <= limit)) || return 1
  # ...and really doesn't (memory it holds, not the cache of files it read).
  cg=/sys/fs/cgroup$(systemctl show -p ControlGroup --value pinewood-agent)
  anon=$(awk '$1 == "anon" { print $2 }' "$cg/memory.stat") || return 1
  ((anon <= limit + 96 * MiB))
}

# ...and if it ever runs away anyway, the kernel can stop *it*: it isn't
# shielded from the OOM killer, or it's boxed in by a memory limit of its own.
agent_stoppable() {
  local adj=$1 max
  max=$(systemctl show -p MemoryMax --value pinewood-agent)
  ((adj >= 0)) && return 0
  [[ $max =~ ^[0-9]+$ ]] && ((max <= 256 * MiB))
}

# 3. A runaway metrics agent can't take the shop down with it.
check_agent() {
  local pid
  agent_bounded || return 1
  pid=$(systemctl show -p MainPID --value pinewood-agent)
  [[ $pid != 0 ]] || return 1
  agent_stoppable "$(cat "/proc/$pid/oom_score_adj")"
}

# 4. About 1 GB of swap is active.
check_swap() {
  local kb
  kb=$(awk '$1 == "SwapTotal:" { print $2 }' /proc/meminfo)
  ((kb >= 900 * 1024))
}

# Bytes of swap that /etc/fstab will turn on at boot: swap files without holes,
# and swap partitions.
swap_at_boot() {
  local src dev total=0
  while read -r src; do
    case $src in
      UUID=* | LABEL=* | PARTUUID=* | PARTLABEL=*) dev=$(findfs "$src" 2>/dev/null) || continue ;;
      *) dev=$src ;;
    esac
    if [[ -f $dev ]]; then
      (($(stat -c '%b * %B' "$dev") >= $(stat -c %s "$dev"))) || continue
      total=$((total + $(stat -c %s "$dev")))
    elif [[ -b $dev ]]; then
      total=$((total + $(blockdev --getsize64 "$dev")))
    fi
  done < <(awk '!/^[[:space:]]*#/ && $3 == "swap" && $4 !~ /(^|,)noauto(,|$)/ { print $1 }' /etc/fstab)
  echo "$total"
}

# The queue limit the agent will read from its config file at its next start.
agent_config_limit_ok() {
  python3 - "$AGENT_CONF" <<'PY'
import configparser, sys
c = configparser.ConfigParser(inline_comment_prefixes=("#", ";"))
c.read(sys.argv[1], encoding="utf-8")
limit = c.getfloat("agent", "queue_limit_mb", fallback=16.0)
sys.exit(0 if 0 < limit <= 128 else 1)
PY
}

# 5. Nothing brings the problems back at the next boot.
check_persistence() {
  local unit
  for unit in nginx storefront search pinewood-agent storefront-refresh.timer search-reindex.timer; do
    systemctl is-enabled --quiet "$unit" || return 1
  done
  nginx -t -q 2>/dev/null || return 1
  # Unit changes are on disk and loaded: no pending daemon-reload, nothing that
  # only lives in /run (which a reboot clears).
  for unit in pinewood.slice "${SHOP_UNITS[@]}" storefront-refresh.service; do
    [[ $(systemctl show -p NeedDaemonReload --value "$unit") == no ]] || return 1
    [[ $(systemctl show -p FragmentPath --value "$unit") != /run/* ]] || return 1
    [[ $(systemctl show -p DropInPaths --value "$unit") != *"/run/systemd/"* ]] || return 1
  done
  agent_config_limit_ok || return 1
  agent_stoppable "$(systemctl show -p OOMScoreAdjust --value pinewood-agent)" || return 1
  (($(swap_at_boot) >= 900 * MiB))
}

# 6. The fix didn't remove or weaken something that matters.
check_guard() {
  local unit user max next
  for unit in "${SHOP_UNITS[@]}"; do
    user=$(systemctl show -p User --value "$unit")
    [[ -n $user && $user != root && $user != 0 ]] || return 1
    [[ $(systemctl show -p Slice --value "$unit") == pinewood.slice ]] || return 1
  done
  # The shop's budget is still there, and no bigger.
  max=$(systemctl show -p MemoryMax --value pinewood.slice)
  [[ $max =~ ^[0-9]+$ ]] && ((max <= 640 * MiB)) || return 1
  # The reindex still has a memory limit of its own (PS-12).
  max=$(systemctl show -p MemoryMax --value search-reindex.service)
  [[ $max =~ ^[0-9]+$ ]] && ((max <= 512 * MiB)) || return 1
  # The catalog refresh still runs every 10 minutes, and the reindex every hour.
  for unit in storefront-refresh.timer:660 search-reindex.timer:3660; do
    systemctl is-enabled --quiet "${unit%:*}" && systemctl is-active --quiet "${unit%:*}" || return 1
    next=$(systemctl show -p NextElapseUSecRealtime --value "${unit%:*}")
    [[ -n $next ]] || return 1
    next=$(date -d "$next" +%s) || return 1
    ((next - $(date +%s) <= ${unit#*:})) || return 1
  done
  # The metrics agent still runs: Monitoring needs it when metrics-01 is back.
  systemctl is-enabled --quiet pinewood-agent && systemctl is-active --quiet pinewood-agent || return 1
  # Swap files can't be read by other users (swap holds copies of memory).
  local name type mode
  while read -r name type; do
    [[ $type == file ]] || continue
    mode=$(stat -c %a "$name" 2>/dev/null) || continue # e.g. "/swapfile (deleted)"
    (((8#$mode & 8#077) == 0)) || return 1
  done < <(awk 'NR > 1 { print $1, $2 }' /proc/swaps)
}

lab_require_root
wait_storefront
lab_begin
lab_check "The storefront survives its 10-minute catalog refresh" check_refresh \
  "This check runs the refresh now, as the timer does, and watches the storefront."
lab_check "Search finds the holiday titles" check_search \
  "This check runs the hourly reindex now, as the timer does."
lab_check "A runaway metrics agent can't take the shop down with it" check_agent
lab_check "The 1 GB swap safety net is active" check_swap
lab_check "Fixes survive a reboot" check_persistence
lab_check "Nothing important was removed or weakened" check_guard
lab_end
