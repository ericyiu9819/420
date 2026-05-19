#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
BACKUP_DIR="${BACKUP_DIR:-/tmp/ufa-tcp-backup}"
SYSCTL_BACKUP="${BACKUP_DIR}/sysctl.before"
TC_BACKUP="${BACKUP_DIR}/tc.before"

IFACE=""
UPLINK_MBIT=""
RTT_MS="80"
EGRESS_HEADROOM_PCT="96"
CC_MODE="auto"
QDISC_MODE="auto"
MODE="apply"
DRY_RUN="0"
SYSCTL_PERSIST_FILE=""
ACTIVE_CC=""
CURRENT_QDISC=""
CURRENT_ECN="0"
CURRENT_FASTOPEN="0"
CURRENT_MTU_PROBING="0"
CURRENT_RMEM_MAX="0"
CURRENT_WMEM_MAX="0"
CURRENT_SOMAXCONN="0"
CURRENT_SYN_BACKLOG="0"
TARGET_ECN="1"
TARGET_FASTOPEN="3"
TARGET_MTU_PROBING="1"
TARGET_SOMAXCONN="4096"
TARGET_SYN_BACKLOG="8192"

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} --uplink-mbit <mbit> [options]

Modes:
  --mode apply      Apply adaptive TCP acceleration settings
  --mode status     Show computed values and current kernel/qdisc state
  --mode restore    Restore sysctl/qdisc from backup created by apply

Required:
  --uplink-mbit N   Real uplink capacity in Mbit/s for this VPS egress path

Options:
  --iface NAME              Network interface, default: system default route iface
  --rtt-ms N                Baseline RTT used for BDP sizing, default: 80
  --egress-headroom-pct N   Shape egress to N%% of real rate, default: 96
  --cc auto|bbrplus|bbr|cubic  Congestion control choice, default: auto
  --qdisc auto|cake|htb|keep   Queue discipline strategy, default: auto
  --persist-sysctl PATH     Write persistent sysctl file to PATH
  --dry-run                 Print actions without applying them
  --help                    Show this message

Examples:
  ${SCRIPT_NAME} --uplink-mbit 1000 --rtt-ms 120
  ${SCRIPT_NAME} --iface eth0 --uplink-mbit 300 --rtt-ms 60 --cc bbr
  ${SCRIPT_NAME} --mode status --uplink-mbit 1000
EOF
}

log() {
  printf '[ufa] %s\n' "$*"
}

die() {
  printf '[ufa] error: %s\n' "$*" >&2
  exit 1
}

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  eval "$@"
}

sysctl_set() {
  local key="$1"
  local value="$2"
  run "sysctl -w ${key}='${value}'"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iface)
        IFACE="${2:-}"; shift 2 ;;
      --uplink-mbit)
        UPLINK_MBIT="${2:-}"; shift 2 ;;
      --rtt-ms)
        RTT_MS="${2:-}"; shift 2 ;;
      --egress-headroom-pct)
        EGRESS_HEADROOM_PCT="${2:-}"; shift 2 ;;
      --cc)
        CC_MODE="${2:-}"; shift 2 ;;
      --qdisc)
        QDISC_MODE="${2:-}"; shift 2 ;;
      --mode)
        MODE="${2:-}"; shift 2 ;;
      --persist-sysctl)
        SYSCTL_PERSIST_FILE="${2:-}"; shift 2 ;;
      --dry-run)
        DRY_RUN="1"; shift ;;
      --help|-h)
        usage; exit 0 ;;
      *)
        die "unknown argument: $1" ;;
    esac
  done
}

detect_iface() {
  if [[ -n "${IFACE}" ]]; then
    return 0
  fi
  IFACE="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')"
  [[ -n "${IFACE}" ]] || die "unable to detect default interface, use --iface"
}

validate_numbers() {
  [[ "${UPLINK_MBIT}" =~ ^[0-9]+$ ]] || die "--uplink-mbit must be an integer"
  [[ "${RTT_MS}" =~ ^[0-9]+$ ]] || die "--rtt-ms must be an integer"
  [[ "${EGRESS_HEADROOM_PCT}" =~ ^[0-9]+$ ]] || die "--egress-headroom-pct must be an integer"
  (( UPLINK_MBIT > 0 )) || die "--uplink-mbit must be > 0"
  (( RTT_MS > 0 )) || die "--rtt-ms must be > 0"
  (( EGRESS_HEADROOM_PCT >= 80 && EGRESS_HEADROOM_PCT <= 100 )) || die "--egress-headroom-pct should be 80-100"
}

max_int() {
  local a="$1"
  local b="$2"
  if (( a > b )); then
    printf '%s' "${a}"
  else
    printf '%s' "${b}"
  fi
}

detect_current_state() {
  ACTIVE_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  CURRENT_QDISC="$(tc qdisc show dev "${IFACE}" 2>/dev/null | awk 'NR==1 {print $2}')"
  CURRENT_ECN="$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null || echo 0)"
  CURRENT_FASTOPEN="$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0)"
  CURRENT_MTU_PROBING="$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo 0)"
  CURRENT_RMEM_MAX="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
  CURRENT_WMEM_MAX="$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)"
  CURRENT_SOMAXCONN="$(sysctl -n net.core.somaxconn 2>/dev/null || echo 0)"
  CURRENT_SYN_BACKLOG="$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo 0)"
}

select_cc() {
  local available
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"

  case "${CC_MODE}" in
    auto)
      if [[ -n "${ACTIVE_CC}" ]] && grep -qw "${ACTIVE_CC}" <<<"${available}" && [[ "${ACTIVE_CC}" =~ ^(bbrplus|bbr|cubic)$ ]]; then
        CC_MODE="${ACTIVE_CC}"
      elif grep -qw bbrplus <<<"${available}"; then
        CC_MODE="bbrplus"
      elif grep -qw bbr <<<"${available}"; then
        CC_MODE="bbr"
      elif grep -qw cubic <<<"${available}"; then
        CC_MODE="cubic"
      else
        CC_MODE="$(awk '{print $1}' <<<"${available}")"
      fi
      [[ -n "${CC_MODE}" ]] || die "unable to determine an available congestion control"
      ;;
    bbrplus|bbr|cubic)
      grep -qw "${CC_MODE}" <<<"${available}" || die "congestion control ${CC_MODE} not available: ${available}"
      ;;
    *)
      die "--cc must be auto, bbrplus, bbr, or cubic"
      ;;
  esac
}

select_qdisc_mode() {
  case "${QDISC_MODE}" in
    auto)
      if [[ "${CURRENT_QDISC}" == "cake" ]]; then
        QDISC_MODE="cake"
      elif [[ -n "${CURRENT_QDISC}" ]]; then
        QDISC_MODE="htb"
      else
        QDISC_MODE="htb"
      fi
      ;;
    cake|htb|keep)
      ;;
    *)
      die "--qdisc must be auto, cake, htb, or keep"
      ;;
  esac
}

calc_values() {
  REAL_RATE_KBIT=$(( UPLINK_MBIT * 1000 ))
  SHAPED_RATE_KBIT=$(( REAL_RATE_KBIT * EGRESS_HEADROOM_PCT / 100 ))
  BDP_BYTES=$(( SHAPED_RATE_KBIT * RTT_MS / 8 ))

  # Keep buffers in a bounded window around BDP so we fill the path without
  # creating unbounded queue memory under loss or application stalls.
  CORE_MIN_BUF=$(( 4 * 1024 * 1024 ))
  CORE_MAX_BUF=$(( 64 * 1024 * 1024 ))
  SOCK_BUF_MAX=$(( BDP_BYTES * 4 ))
  [[ ${SOCK_BUF_MAX} -lt ${CORE_MIN_BUF} ]] && SOCK_BUF_MAX=${CORE_MIN_BUF}
  [[ ${SOCK_BUF_MAX} -gt ${CORE_MAX_BUF} ]] && SOCK_BUF_MAX=${CORE_MAX_BUF}

  SOCK_BUF_DEFAULT=$(( BDP_BYTES / 2 ))
  [[ ${SOCK_BUF_DEFAULT} -lt 131072 ]] && SOCK_BUF_DEFAULT=131072
  [[ ${SOCK_BUF_DEFAULT} -gt ${SOCK_BUF_MAX} ]] && SOCK_BUF_DEFAULT=${SOCK_BUF_MAX}

  TBF_BURST_BYTES=$(( SHAPED_RATE_KBIT * 1000 / 8 / 100 ))
  [[ ${TBF_BURST_BYTES} -lt 32768 ]] && TBF_BURST_BYTES=32768
  [[ ${TBF_BURST_BYTES} -gt 1048576 ]] && TBF_BURST_BYTES=1048576

  QUEUE_LIMIT_PACKETS=$(( BDP_BYTES / 1500 ))
  [[ ${QUEUE_LIMIT_PACKETS} -lt 128 ]] && QUEUE_LIMIT_PACKETS=128
  [[ ${QUEUE_LIMIT_PACKETS} -gt 4096 ]] && QUEUE_LIMIT_PACKETS=4096

  SOCK_BUF_MAX="$(max_int "${SOCK_BUF_MAX}" "${CURRENT_RMEM_MAX}")"
  SOCK_BUF_MAX="$(max_int "${SOCK_BUF_MAX}" "${CURRENT_WMEM_MAX}")"
  TARGET_SOMAXCONN="$(max_int 4096 "${CURRENT_SOMAXCONN}")"
  TARGET_SYN_BACKLOG="$(max_int 8192 "${CURRENT_SYN_BACKLOG}")"

  if (( CURRENT_ECN > 0 )); then
    TARGET_ECN="${CURRENT_ECN}"
  fi
  TARGET_FASTOPEN="$(max_int 3 "${CURRENT_FASTOPEN}")"
  TARGET_MTU_PROBING="$(max_int 1 "${CURRENT_MTU_PROBING}")"
}

print_summary() {
  cat <<EOF
Interface:              ${IFACE}
Detected qdisc:         ${CURRENT_QDISC:-none}
Apply qdisc mode:       ${QDISC_MODE}
Active CC:              ${ACTIVE_CC:-unknown}
Congestion control:     ${CC_MODE}
Real uplink:            ${UPLINK_MBIT} Mbit/s
Shaped uplink:          $(( SHAPED_RATE_KBIT / 1000 )) Mbit/s (${EGRESS_HEADROOM_PCT}%)
Baseline RTT:           ${RTT_MS} ms
Estimated BDP:          ${BDP_BYTES} bytes
Socket buffer default:  ${SOCK_BUF_DEFAULT} bytes
Socket buffer max:      ${SOCK_BUF_MAX} bytes
Queue packet limit:     ${QUEUE_LIMIT_PACKETS}
Burst bytes:            ${TBF_BURST_BYTES}
Target somaxconn:       ${TARGET_SOMAXCONN}
Target syn backlog:     ${TARGET_SYN_BACKLOG}
EOF
}

backup_state() {
  run "mkdir -p '${BACKUP_DIR}'"

  if [[ "${DRY_RUN}" == "0" ]]; then
    {
      sysctl -n net.core.default_qdisc 2>/dev/null || true
      sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true
      sysctl -n net.ipv4.tcp_ecn 2>/dev/null || true
      sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || true
      sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || true
      sysctl -n net.core.rmem_max 2>/dev/null || true
      sysctl -n net.core.wmem_max 2>/dev/null || true
      sysctl -n net.ipv4.tcp_rmem 2>/dev/null || true
      sysctl -n net.ipv4.tcp_wmem 2>/dev/null || true
      sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || true
      sysctl -n net.core.somaxconn 2>/dev/null || true
      sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || true
    } >"${SYSCTL_BACKUP}"

    tc qdisc show dev "${IFACE}" >"${TC_BACKUP}" 2>/dev/null || true
  fi
}

apply_sysctls() {
  sysctl_set net.core.default_qdisc "fq"
  sysctl_set net.ipv4.tcp_congestion_control "${CC_MODE}"
  sysctl_set net.ipv4.tcp_ecn "${TARGET_ECN}"
  sysctl_set net.ipv4.tcp_fastopen "${TARGET_FASTOPEN}"
  sysctl_set net.ipv4.tcp_mtu_probing "${TARGET_MTU_PROBING}"
  sysctl_set net.core.rmem_max "${SOCK_BUF_MAX}"
  sysctl_set net.core.wmem_max "${SOCK_BUF_MAX}"
  sysctl_set net.ipv4.tcp_rmem "4096 ${SOCK_BUF_DEFAULT} ${SOCK_BUF_MAX}"
  sysctl_set net.ipv4.tcp_wmem "4096 ${SOCK_BUF_DEFAULT} ${SOCK_BUF_MAX}"
  sysctl_set net.ipv4.tcp_notsent_lowat "16384"
  sysctl_set net.core.somaxconn "${TARGET_SOMAXCONN}"
  sysctl_set net.ipv4.tcp_max_syn_backlog "${TARGET_SYN_BACKLOG}"

  if [[ -n "${SYSCTL_PERSIST_FILE}" ]]; then
    log "writing persistent sysctl file: ${SYSCTL_PERSIST_FILE}"
    local dir
    dir="$(dirname "${SYSCTL_PERSIST_FILE}")"
    run "mkdir -p '${dir}'"
    if [[ "${DRY_RUN}" == "0" ]]; then
      cat >"${SYSCTL_PERSIST_FILE}" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=${CC_MODE}
net.ipv4.tcp_ecn=${TARGET_ECN}
net.ipv4.tcp_fastopen=${TARGET_FASTOPEN}
net.ipv4.tcp_mtu_probing=${TARGET_MTU_PROBING}
net.core.rmem_max=${SOCK_BUF_MAX}
net.core.wmem_max=${SOCK_BUF_MAX}
net.ipv4.tcp_rmem=4096 ${SOCK_BUF_DEFAULT} ${SOCK_BUF_MAX}
net.ipv4.tcp_wmem=4096 ${SOCK_BUF_DEFAULT} ${SOCK_BUF_MAX}
net.ipv4.tcp_notsent_lowat=16384
net.core.somaxconn=${TARGET_SOMAXCONN}
net.ipv4.tcp_max_syn_backlog=${TARGET_SYN_BACKLOG}
EOF
    fi
  fi
}

apply_qdisc() {
  # Principle: shape slightly below the true egress rate so the bottleneck queue
  # sits on this VPS, where fq pacing can keep it shallow and stable.
  case "${QDISC_MODE}" in
    keep)
      log "keeping existing qdisc on ${IFACE}"
      ;;
    cake)
      run "tc qdisc replace dev '${IFACE}' root cake bandwidth ${SHAPED_RATE_KBIT}kbit diffserv3 triple-isolate nonat nowash no-ack-filter split-gso rtt ${RTT_MS}ms raw overhead 0"
      ;;
    htb)
      run "tc qdisc replace dev '${IFACE}' root handle 1: htb default 10"
      run "tc class replace dev '${IFACE}' parent 1: classid 1:10 htb rate ${SHAPED_RATE_KBIT}kbit ceil ${SHAPED_RATE_KBIT}kbit burst ${TBF_BURST_BYTES}"
      run "tc qdisc replace dev '${IFACE}' parent 1:10 handle 10: fq limit ${QUEUE_LIMIT_PACKETS} pacing"
      ;;
  esac
}

status() {
  print_summary
  printf '\nCurrent sysctl:\n'
  sysctl net.core.default_qdisc \
    net.ipv4.tcp_congestion_control \
    net.ipv4.tcp_ecn \
    net.ipv4.tcp_fastopen \
    net.ipv4.tcp_mtu_probing \
    net.core.rmem_max \
    net.core.wmem_max \
    net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem \
    net.ipv4.tcp_notsent_lowat \
    net.core.somaxconn \
    net.ipv4.tcp_max_syn_backlog 2>/dev/null || true

  printf '\nCurrent qdisc:\n'
  tc qdisc show dev "${IFACE}" 2>/dev/null || true
  printf '\nCurrent classes:\n'
  tc class show dev "${IFACE}" 2>/dev/null || true
}

restore() {
  [[ -f "${SYSCTL_BACKUP}" ]] || die "missing backup file: ${SYSCTL_BACKUP}"

  mapfile -t saved <"${SYSCTL_BACKUP}"
  [[ ${#saved[@]} -ge 12 ]] || die "backup file is incomplete"

  sysctl_set net.core.default_qdisc "${saved[0]}"
  sysctl_set net.ipv4.tcp_congestion_control "${saved[1]}"
  sysctl_set net.ipv4.tcp_ecn "${saved[2]}"
  sysctl_set net.ipv4.tcp_fastopen "${saved[3]}"
  sysctl_set net.ipv4.tcp_mtu_probing "${saved[4]}"
  sysctl_set net.core.rmem_max "${saved[5]}"
  sysctl_set net.core.wmem_max "${saved[6]}"
  sysctl_set net.ipv4.tcp_rmem "${saved[7]}"
  sysctl_set net.ipv4.tcp_wmem "${saved[8]}"
  sysctl_set net.ipv4.tcp_notsent_lowat "${saved[9]}"
  sysctl_set net.core.somaxconn "${saved[10]}"
  sysctl_set net.ipv4.tcp_max_syn_backlog "${saved[11]}"

  # tc qdisc show output is not a reversible config source, so restore removes
  # the accelerator root qdisc and relies on your own persisted network config,
  # service scripts, or reboot to reconstruct any previous custom tree exactly.
  run "tc qdisc del dev '${IFACE}' root || true"
  log "restore finished (sysctl restored; qdisc restore is best-effort)"
}

main() {
  require_cmd ip
  require_cmd tc
  require_cmd sysctl

  parse_args "$@"

  if [[ "${MODE}" != "restore" ]]; then
    detect_iface
    validate_numbers
    detect_current_state
    select_cc
    select_qdisc_mode
    calc_values
  else
    detect_iface
  fi

  case "${MODE}" in
    apply)
      print_summary
      backup_state
      apply_sysctls
      apply_qdisc
      log "applied principle-based TCP accelerator on ${IFACE}"
      ;;
    status)
      status
      ;;
    restore)
      restore
      ;;
    *)
      die "--mode must be apply, status, or restore"
      ;;
  esac
}

main "$@"
