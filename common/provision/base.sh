#!/usr/bin/env bash
#
# base.sh: common provisioning shared by every lab. It runs first.
#
# Keep this lab-agnostic and defect-free. It:
#   * refuses to continue unless the guest has the architecture the host expects
#     (arm64 on Apple Silicon Macs, amd64 on Windows)
#   * freezes automatic package updates so every run of a lab is identical
#   * installs the standard troubleshooting toolbox
#   * installs the lab helpers: `lab-check`, the ticket, and the login banner
#
# Inputs (environment, set by common/vagrant/lab.rb): LAB_ID, LAB_LEVEL,
#   LAB_TITLE, LAB_ARCH, and LAB_IP (the VM's host-only address, or "auto" to
#   detect it here)
# Inputs (uploaded by file provisioners):
#   /tmp/lab-common.sh  -> /usr/local/lib/lab/lab-common.sh
#   /tmp/lab-check      -> /usr/local/sbin/lab-check
#   /tmp/lab-ticket.md  -> /etc/lab/ticket.md

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

: "${LAB_ID:?LAB_ID must be set by the Vagrantfile}"
: "${LAB_LEVEL:?LAB_LEVEL must be set by the Vagrantfile}"
: "${LAB_TITLE:?LAB_TITLE must be set by the Vagrantfile}"
: "${LAB_ARCH:?LAB_ARCH must be set by the Vagrantfile}"
: "${LAB_IP:?LAB_IP must be set by the Vagrantfile}"

log() { printf '==> [base] %s\n' "$*"; }

# Retry a command a few times: on first boot, cloud-init or apt timers may still
# hold the apt lock, and mirrors occasionally hiccup.
retry() {
  local attempt=1
  until "$@"; do
    if ((attempt >= 10)); then
      echo "ERROR: '$*' failed after $attempt attempts" >&2
      return 1
    fi
    log "'$1' failed, retrying in 10s (attempt $attempt/10)"
    attempt=$((attempt + 1))
    sleep 10
  done
}

# --- 1. Architecture guard ---------------------------------------------------
arch=$(dpkg --print-architecture)
if [[ $arch != "$LAB_ARCH" ]]; then
  echo "ERROR: on this host the lab expects a '$LAB_ARCH' guest, but this one is '$arch'." >&2
  echo "       Check config.vm.box_architecture in common/vagrant/lab.rb." >&2
  exit 1
fi
log "Guest architecture: $arch ($(uname -m)), kernel $(uname -r)"

# --- 2. Freeze automatic updates ---------------------------------------------
log "Disabling automatic package updates (keeps the lab reproducible)"
cat >/etc/apt/apt.conf.d/99-lab-no-auto-updates <<'EOF'
// Linux Troubleshooting Labs: no background package changes while you work.
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

# --- 3. Troubleshooting toolbox ----------------------------------------------
# Everything comes from the Ubuntu archive for the guest's own architecture.
PACKAGES=(
  bash-completion bind9-dnsutils curl e2fsprogs htop iproute2 jq less lsof
  ncdu net-tools procps psmisc strace sysstat tcpdump tree ufw util-linux vim
)
APT_INSTALL=(apt-get -y -qq -o DPkg::Lock::Timeout=600
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install)

log "Installing troubleshooting toolbox"
retry apt-get -qq -o DPkg::Lock::Timeout=600 update
retry "${APT_INSTALL[@]}" "${PACKAGES[@]}" >/dev/null

timedatectl set-timezone UTC >/dev/null 2>&1 || true

# --- 4. Lab helpers ------------------------------------------------------------
log "Installing lab helpers (lab-check, ticket, login banner)"
install -d -m 0755 /usr/local/lib/lab /etc/lab
# File provisioners copy files byte for byte. .gitattributes keeps them LF, but
# strip Windows line endings anyway in case a copy was edited on Windows.
sed -i 's/\r$//' /tmp/lab-common.sh /tmp/lab-check /tmp/lab-ticket.md
install -m 0644 /tmp/lab-common.sh /usr/local/lib/lab/lab-common.sh
install -m 0700 /tmp/lab-check /usr/local/sbin/lab-check

# LAB_IP=auto means the Vagrantfile fell back to DHCP on the host-only network:
# use the IPv4 address that isn't on the default-route (NAT) interface.
if [[ $LAB_IP == auto ]]; then
  nat_if=$(ip -o -4 route show default | awk '{ print $5; exit }')
  LAB_IP=$(ip -o -4 addr show scope global |
    awk -v nat="$nat_if" '$2 != nat { split($4, a, "/"); print a[1]; exit }')
  log "Host-only address (DHCP): ${LAB_IP:-unknown}"
fi

sed "s/<LAB_IP>/${LAB_IP}/g" /tmp/lab-ticket.md >/etc/lab/ticket.md
chmod 0644 /etc/lab/ticket.md
rm -f /tmp/lab-common.sh /tmp/lab-check /tmp/lab-ticket.md

cat >/etc/lab/lab.env <<EOF
LAB_ID="${LAB_ID}"
LAB_LEVEL="${LAB_LEVEL}"
LAB_TITLE="${LAB_TITLE}"
LAB_IP="${LAB_IP}"
EOF

cat >/etc/update-motd.d/99-lab <<'EOF'
#!/bin/sh
. /etc/lab/lab.env 2>/dev/null
printf '\n'
printf '  ============================================================\n'
printf '   Linux Troubleshooting Lab  |  %s  |  %s\n' "$LAB_LEVEL" "$LAB_ID"
printf '   %s\n' "$LAB_TITLE"
printf '   ------------------------------------------------------------\n'
printf '   Read the ticket :  cat /etc/lab/ticket.md\n'
printf '   Check progress  :  sudo lab-check\n'
printf '  ============================================================\n\n'
EOF
chmod 0755 /etc/update-motd.d/99-lab

# Quiet the stock Ubuntu login noise so the lab banner stands out.
for f in 10-help-text 50-motd-news 90-updates-available 91-contract-ua-esm-status 91-release-upgrade; do
  if [[ -f /etc/update-motd.d/$f ]]; then
    chmod -x "/etc/update-motd.d/$f"
  fi
done

log "Done"
