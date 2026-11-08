# shellcheck shell=bash
#
# lab-common.sh: helpers shared by every level's check script.
#
# Installed in the VM at /usr/local/lib/lab/lab-common.sh by common/provision/base.sh.
# A level's check.sh sources this file, defines one function per check, then:
#
#   lab_require_root
#   lab_begin
#   lab_check "Backend application is running"  check_backend
#   lab_check "Site reachable from outside"     check_external  "optional note shown on FAIL"
#   lab_end        # prints the summary; exit 0 only if every check passed
#
# Rules for check functions:
#   * Be silent: all output is discarded.
#   * Return 0 for pass, non-zero for fail.
#   * Test outcomes (what the ticket asks for), not causes, and never print
#     *why* a check failed. Explaining is the job of HINTS.md.

LAB_ENV_FILE=/etc/lab/lab.env
if [[ -r $LAB_ENV_FILE ]]; then
  # shellcheck source=/dev/null
  . "$LAB_ENV_FILE"
fi
: "${LAB_ID:=lab}" "${LAB_TITLE:=}" "${LAB_IP:=}"

_lab_pass=0
_lab_total=0

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  _c_green=$'\e[32m' _c_red=$'\e[31m' _c_dim=$'\e[2m' _c_bold=$'\e[1m' _c_reset=$'\e[0m'
else
  _c_green='' _c_red='' _c_dim='' _c_bold='' _c_reset=''
fi

lab_require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "lab-check needs root to inspect the system. Run: sudo lab-check" >&2
    exit 2
  fi
}

lab_begin() {
  printf '\n %s%s%s  %s\n' "$_c_bold" "$LAB_ID" "$_c_reset" "$LAB_TITLE"
  printf ' %s\n' "------------------------------------------------------------"
}

# lab_check <description> <function> [note shown only when the check fails]
lab_check() {
  local desc=$1 fn=$2 note=${3:-}
  _lab_total=$((_lab_total + 1))
  # Run in a subshell so a check can't change our state or exit the script.
  if ("$fn") >/dev/null 2>&1; then
    _lab_pass=$((_lab_pass + 1))
    printf ' %s[PASS]%s %d. %s\n' "$_c_green" "$_c_reset" "$_lab_total" "$desc"
  else
    printf ' %s[FAIL]%s %d. %s\n' "$_c_red" "$_c_reset" "$_lab_total" "$desc"
    if [[ -n $note ]]; then
      printf '           %s%s%s\n' "$_c_dim" "$note" "$_c_reset"
    fi
  fi
}

lab_end() {
  printf ' %s\n' "------------------------------------------------------------"
  if ((_lab_pass == _lab_total)); then
    printf ' %sAll %d checks pass.%s Incident resolved. Nice work.\n' \
      "$_c_green" "$_lab_total" "$_c_reset"
    printf ' Next: write your post-incident note, then compare it with SOLUTIONS.md.\n\n'
    exit 0
  fi
  printf ' %d/%d checks passing. Stuck? HINTS.md has progressive hints.\n\n' \
    "$_lab_pass" "$_lab_total"
  exit 1
}

# ---------------------------------------------------------------------------
# Small utilities for check functions
# ---------------------------------------------------------------------------

# lab_http_code <url> [timeout]: print the HTTP status code ("000" = no response).
lab_http_code() {
  curl -s -o /dev/null -m "${2:-5}" -w '%{http_code}' "$1" 2>/dev/null || true
}

# lab_avail_bytes <path>: bytes available to unprivileged users on that filesystem.
lab_avail_bytes() {
  df --output=avail -B1 "$1" 2>/dev/null | awk 'NR == 2 { print $1 }'
}

# lab_local_ips: every address configured on this machine, one per line.
lab_local_ips() {
  ip -o addr show 2>/dev/null | awk '{ split($4, a, "/"); print a[1] }'
}
