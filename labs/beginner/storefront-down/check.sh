#!/usr/bin/env bash
#
# storefront-down check: verifies the outcomes the incident ticket asks for.
# Installed in the VM as /usr/local/sbin/lab-check.  Run:  sudo lab-check
#
# The output never says *why* something fails, but this source code does hint
# at it. SPOILER WARNING: read it after you finish.

# shellcheck disable=SC2317,SC2329  # check_* functions are called indirectly via lab_check
set -uo pipefail

# shellcheck source=../../../common/lib/lab-common.sh
. /usr/local/lib/lab/lab-common.sh

APP_UNIT=bookshop
APP_CONF=/etc/bookshop/bookshop.conf
LOG_MNT=/var/log/bookshop
MIN_FREE_BYTES=$((200 * 1024 * 1024))

# conf_get <key>: read a value from the backend's INI config (keys are unique).
conf_get() {
  awk -F= -v key="$1" '
    { k = $1; gsub(/[ \t]/, "", k) }
    k == key { v = $2; gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }
  ' "$APP_CONF"
}

# 1. The backend runs and reports healthy on its own port.
check_backend() {
  systemctl is-active --quiet "$APP_UNIT" || return 1
  local port
  port=$(conf_get listen_port)
  [[ $(lab_http_code "http://127.0.0.1:${port:-8080}/healthz") == 200 ]]
}

# 2. The storefront loads through nginx.
check_frontend() {
  local body
  body=$(curl -s -m 5 -w '\n%{http_code}' http://127.0.0.1/) || return 1
  [[ ${body##*$'\n'} == 200 && $body == *"Pinewood Books"* ]]
}

# 3. A client that is NOT this machine got a 200 since the incident started.
#    (Traffic from the VM to its own IP goes over loopback and skips the
#    firewall, so the only honest proof is nginx's access log.)
check_external() {
  local locals f
  locals=$(lab_local_ips)
  for f in /var/log/nginx/access.log /var/log/nginx/access.log.1; do
    [[ -r $f ]] || continue
    if awk -v locals="$locals" '
         BEGIN { n = split(locals, l, "\n"); for (i = 1; i <= n; i++) skip[l[i]] = 1 }
         !($1 in skip) && $9 == 200 { found = 1; exit }
         END { exit !found }
       ' "$f"; then
      return 0
    fi
  done
  return 1
}

# 4. The log volume is mounted, has real headroom, and isn't filling up.
check_storage() {
  mountpoint -q "$LOG_MNT" || return 1
  local before after
  before=$(lab_avail_bytes "$LOG_MNT")
  sleep 4
  after=$(lab_avail_bytes "$LOG_MNT")
  ((after >= MIN_FREE_BYTES)) || return 1
  ((before - after < 1024 * 1024))
}

# 5. Nothing will undo the fix (or re-break things) at the next boot.
check_persistence() {
  systemctl is-enabled --quiet "$APP_UNIT" || return 1
  systemctl is-enabled --quiet nginx || return 1
  [[ $(systemctl is-enabled bookshop-tracer.service 2>/dev/null) != enabled* ]] || return 1
  findmnt --fstab "$LOG_MNT" >/dev/null || return 1
  nginx -t -q || return 1
  # Firewall rules added with ufw are saved; raw iptables/nft rules are not.
  local fw
  fw=$(ufw status)
  if [[ $fw == *"Status: active"* ]]; then
    grep -Eqs -- '^-A ufw-user-input .*--dports? ([0-9:]+,)*80([,:][0-9]+)*( |$).*-j ACCEPT' \
      /etc/ufw/user.rules /etc/ufw/user6.rules || return 1
  fi
}

# 6. The fix didn't trade security for uptime.
check_security() {
  local fw mode user
  fw=$(ufw status verbose) || return 1
  [[ $fw == *"Status: active"* ]] || return 1
  [[ $fw =~ Default:\ (deny|reject)\ \(incoming\) ]] || return 1
  mode=$(stat -c '%a' "$APP_CONF") || return 1
  (((8#$mode & 8#007) == 0)) || return 1
  user=$(systemctl show -p User --value "$APP_UNIT")
  [[ -n $user && $user != root && $user != 0 ]]
}

lab_require_root
lab_begin
lab_check "Backend application is running and healthy" check_backend
lab_check "Storefront loads through the web server (http://localhost/)" check_frontend
lab_check "Storefront is reachable from outside the server" check_external \
  "Needs a successful page load from your computer: open http://${LAB_IP:-<lab IP>}/ and re-run."
lab_check "Log storage has healthy free space and is stable" check_storage
lab_check "Fixes survive a reboot" check_persistence
lab_check "No security regressions introduced" check_security
lab_end
