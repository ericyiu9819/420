#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_VERSION="7.1.0-rc4-mainline"
REPO_RAW_BASE="https://raw.githubusercontent.com/ericyiu9819/420/main/kernel-packages/7.1-rc4-mainline"
WORK_DIR="/tmp/mainline-kernel-7.1-rc4"
PURGE_OLD=0

PACKAGES=(
  "linux-image-7.1.0-rc4-mainline_7.1~rc4-1_amd64.deb"
  "linux-headers-7.1.0-rc4-mainline_7.1~rc4-1_amd64.deb"
  "linux-libc-dev_7.1~rc4-1_amd64.deb"
)

log() {
  printf '\n[mainline] %s\n' "$*"
}

die() {
  printf '\n[mainline] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  bash install-mainline-7.1-rc4.sh [--purge-old]

Options:
  --purge-old  Remove other linux-image/linux-headers packages after installing.
               Use only after you are sure this VPS boots correctly.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --purge-old)
      PURGE_OLD=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || die "Please run as root."

ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
[ "$ARCH" = "amd64" ] || die "This package set is for amd64 only. Current architecture: ${ARCH:-unknown}"

if [ ! -r /etc/os-release ]; then
  die "Cannot detect Linux distribution."
fi

. /etc/os-release
case "${ID:-}" in
  debian|ubuntu)
    ;;
  *)
    case "${ID_LIKE:-}" in
      *debian*|*ubuntu*) ;;
      *) die "This script supports Debian/Ubuntu-based systems only." ;;
    esac
    ;;
esac

export DEBIAN_FRONTEND=noninteractive

log "Installing required tools"
apt-get update
apt-get install -y curl ca-certificates grub2-common initramfs-tools

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

log "Downloading kernel packages"
for pkg in "${PACKAGES[@]}"; do
  curl -fL --retry 3 --connect-timeout 20 -o "$pkg" "$REPO_RAW_BASE/$pkg"
done

log "Installing kernel ${KERNEL_VERSION}"
dpkg -i "${PACKAGES[@]}" || apt-get -f install -y

if [ ! -f "/boot/vmlinuz-${KERNEL_VERSION}" ]; then
  die "Kernel image was not installed correctly: /boot/vmlinuz-${KERNEL_VERSION} not found"
fi

log "Enabling BBR and fq_codel"
install -d /etc/sysctl.d
cat >/etc/sysctl.d/99-mainline-bbr-fq-codel.conf <<EOF
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system

log "Setting GRUB default kernel"
if [ -f /etc/default/grub ]; then
  if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
    sed -i "s#^GRUB_DEFAULT=.*#GRUB_DEFAULT='Advanced options for Debian GNU/Linux>Debian GNU/Linux, with Linux ${KERNEL_VERSION}'#" /etc/default/grub
  else
    printf "\nGRUB_DEFAULT='Advanced options for Debian GNU/Linux>Debian GNU/Linux, with Linux %s'\n" "$KERNEL_VERSION" >>/etc/default/grub
  fi
fi

update-grub

if [ "$PURGE_OLD" -eq 1 ]; then
  log "Removing old kernel packages"
  current="$(uname -r)"
  dpkg-query -W -f='${Package}\n' 'linux-image-*' 'linux-headers-*' 2>/dev/null \
    | grep -Ev "(${KERNEL_VERSION}|${current}|linux-image-amd64|linux-headers-amd64)" \
    | xargs -r apt-get purge -y
  apt-get autoremove -y
  update-grub
fi

log "Installation complete"
printf 'Installed kernel: %s\n' "$KERNEL_VERSION"
printf 'Current running kernel: %s\n' "$(uname -r)"
printf 'BBR: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)"
printf 'Queue: %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || printf unknown)"
printf '\nReboot to start using the new kernel:\n  reboot\n'
