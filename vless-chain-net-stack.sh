#!/usr/bin/env bash
# VLESS 链式节点网络栈 — 从 B/T/R 基本量推导
#
# 杠杆优先级（第一性原理）:
#   P0  BBR + fq
#   P0  BDP → socket 缓冲 (2×BDP, 受内存 10% 约束)
#   P0  角色 R → somaxconn / conntrack / port_range
#   P1  长连接代理 sysctl (slow_start_after_idle=0, tw_reuse, ...)
#   P1  出口 HTB+fq 整形 (仅带宽置信度 ≥ 40%)
#   P2  Xray LimitNOFILE
#
# --profile short:
#   外层承载仍是少量长 TCP，内层是短流。B×T 只有在上行和对端时延都实测时
#   才写套接字上限；默认缓冲保持小值。连接表按角色写，不靠带宽先验。
set -euo pipefail

STATE_DIR="/var/lib/vless-chain/net-stack"
SYSCTL_FILE="/etc/sysctl.d/99-vless-chain-net-stack.conf"
UNIT_FILE="/etc/systemd/system/xray.service"

ROLE=""
MODE="apply"
PROFILE="long"
UPLINK_MBIT=""
RTT_MS=""
PEER_IP=""
IFACE=""
DRY_RUN="0"
PROBE_BANDWIDTH="1"
PROBE_RTT="1"
SKIP_QDISC_ON_LOW_CONF="1"
CONF_BAND="0"
CONF_RTT="0"
APPLY_QDISC="0"

PRIOR_B_ENTRY="1000"
PRIOR_B_EXIT="1000"
PRIOR_T_ENTRY="150"
PRIOR_T_EXIT="80"

SHAPE_FACTOR="950"
BUF_BDP_MULT="2"
MTU="1500"

usage() {
  cat <<'EOF'
Usage: vless-chain-net-stack.sh --role entry|exit [options]

从 B(带宽)、T(RTT)、R(角色) 推导内核参数。无需手动输入 B/T。

Modes:
  apply     探测 + 推导 + 应用（默认）
  status    显示推导过程与当前内核
  restore   回滚 sysctl/tc（依赖 apply 前备份）

Options:
  --role entry|exit
  --profile long|short  long=低连接（默认），short=短连接承载
  --uplink-mbit N       覆盖自动探测带宽
  --rtt-ms N            覆盖自动探测 RTT
  --peer-ip IP          RTT 首选 ping 目标
  --iface NAME          出口网卡
  --no-probe-bandwidth  直接用角色带宽先验
  --no-probe-rtt        直接用角色 RTT 先验
  --dry-run
  -h, --help
EOF
}

log()  { echo "[net-stack] $*"; }
die()  { echo "[net-stack] ERROR: $*" >&2; exit 1; }

run() {
  [[ "$DRY_RUN" == "1" ]] && { echo "[dry-run] $*"; return 0; }
  eval "$@"
}

require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "需要 root"; }

require_cmds() {
  local c
  for c in ip sysctl awk; do
    command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c（请安装 iproute2）"
  done
  if [[ "${APPLY_QDISC:-0}" == "1" ]]; then
    command -v tc >/dev/null 2>&1 || die "缺少 tc（请安装 iproute2）"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role) ROLE="$2"; shift 2 ;;
      --mode) MODE="$2"; shift 2 ;;
      --profile) PROFILE="$2"; shift 2 ;;
      --uplink-mbit) UPLINK_MBIT="$2"; shift 2 ;;
      --rtt-ms) RTT_MS="$2"; shift 2 ;;
      --peer-ip) PEER_IP="$2"; shift 2 ;;
      --iface) IFACE="$2"; shift 2 ;;
      --no-probe-bandwidth) PROBE_BANDWIDTH="0"; shift ;;
      --no-probe-rtt) PROBE_RTT="0"; shift ;;
      --dry-run) DRY_RUN="1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [[ "$ROLE" == "entry" || "$ROLE" == "exit" ]] || die "必须 --role entry|exit"
  [[ "$PROFILE" == "long" || "$PROFILE" == "short" ]] || die "必须 --profile long|short"
}

detect_iface() {
  [[ -n "$IFACE" ]] && return 0
  IFACE="$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')"
  [[ -n "$IFACE" ]] || die "无法检测网卡，请 --iface 指定"
}

mem_kb() { awk '/MemTotal/ {print $2}' /proc/meminfo; }

clamp() {
  local v="$1" lo="$2" hi="$3"
  (( v < lo )) && v=$lo
  (( v > hi )) && v=$hi
  echo "$v"
}

curl_speed_mbit() {
  local url="$1" secs="$2" out bytes elapsed
  out="$(curl -fsS --max-time "$secs" -o /dev/null -w '%{size_download} %{time_total}' "$url" 2>/dev/null || true)"
  bytes="$(awk '{print $1}' <<<"$out")"
  elapsed="$(awk '{print $2}' <<<"$out")"
  awk -v b="$bytes" -v t="$elapsed" 'BEGIN {
    if (b > 500000 && t > 0.3) printf "%.0f", (b * 8 / t) / 1000000;
  }'
}

use_bandwidth_prior() {
  if [[ "$ROLE" == "entry" ]]; then UPLINK_MBIT="$PRIOR_B_ENTRY"; else UPLINK_MBIT="$PRIOR_B_EXIT"; fi
  CONF_BAND=20
  log "带宽: 使用 ${ROLE} 先验 ${UPLINK_MBIT} Mbps"
}

probe_bandwidth_short() {
  local link_mbit=""
  if [[ "$PROBE_BANDWIDTH" != "1" ]]; then
    use_bandwidth_prior
    UPLINK_MBIT="$(clamp "$UPLINK_MBIT" 10 10000)"
    return
  fi
  if [[ -r "/sys/class/net/${IFACE}/speed" ]]; then
    link_mbit="$(cat "/sys/class/net/${IFACE}/speed" 2>/dev/null || true)"
    [[ "$link_mbit" =~ ^[0-9]+$ ]] && (( link_mbit > 0 )) || link_mbit=""
  fi
  use_bandwidth_prior
  if [[ -n "$link_mbit" && "$link_mbit" -ge 10 && "$link_mbit" -lt 10000 ]]; then
    log "带宽: 网卡 ${link_mbit}Mbps 只是出口上限，短连接剖面不用它冒充已测上行"
  else
    log "带宽: 没有已测上行，保持 ${ROLE} 先验 ${UPLINK_MBIT}Mbps"
  fi
  UPLINK_MBIT="$(clamp "$UPLINK_MBIT" 10 10000)"
}

probe_bandwidth_mbit() {
  local link_mbit="" samples=() s best from_link

  if [[ "$PROFILE" == "short" ]]; then
    probe_bandwidth_short
    return
  fi

  if [[ "$PROBE_BANDWIDTH" != "1" ]]; then use_bandwidth_prior; UPLINK_MBIT="$(clamp "$UPLINK_MBIT" 10 10000)"; return; fi

  if [[ -r "/sys/class/net/${IFACE}/speed" ]]; then
    link_mbit="$(cat "/sys/class/net/${IFACE}/speed" 2>/dev/null || true)"
    [[ "$link_mbit" =~ ^[0-9]+$ ]] && (( link_mbit > 0 )) || link_mbit=""
  fi

  if command -v curl >/dev/null 2>&1; then
    s="$(curl_speed_mbit "https://speed.cloudflare.com/__down?bytes=10000000" 8 || true)"
    [[ -n "$s" ]] && samples+=("$s")
    s="$(curl_speed_mbit "https://speed.cloudflare.com/__down?bytes=25000000" 10 || true)"
    [[ -n "$s" ]] && samples+=("$s")
  fi

  best=0
  for s in "${samples[@]}"; do [[ "$s" =~ ^[0-9]+$ ]] && (( s > best )) && best=$s; done

  if [[ -n "$link_mbit" ]]; then
    from_link=$(( link_mbit * 70 / 100 ))
    UPLINK_MBIT=$from_link
    if (( best > UPLINK_MBIT )); then UPLINK_MBIT=$best; CONF_BAND=70; else CONF_BAND=50; fi
    log "带宽: 网卡 ${link_mbit}M×0.7=${from_link}M, 采样 ${best:-N/A}M → ${UPLINK_MBIT}M"
  elif (( best > 0 )); then
    UPLINK_MBIT=$best; CONF_BAND=60
    log "带宽: 下载采样 → ${UPLINK_MBIT}M"
  else
    use_bandwidth_prior
  fi
  UPLINK_MBIT="$(clamp "$UPLINK_MBIT" 10 10000)"
}

measure_uplink_mbit() {
  [[ -n "$UPLINK_MBIT" ]] && { CONF_BAND=100; return 0; }
  probe_bandwidth_mbit
}

ping_median_ms() {
  local targets=("$@") results=() t avg
  for t in "${targets[@]}"; do
    [[ -z "$t" ]] && continue
    avg="$(ping -c 4 -i 0.2 -W 1 "$t" 2>/dev/null | awk -F'/' '/min\/avg/ {print $5}' | cut -d. -f1)"
    [[ "$avg" =~ ^[0-9]+$ ]] && (( avg > 0 )) && results+=("$avg")
  done
  ((${#results[@]} == 0)) && return 1
  printf '%s\n' "${results[@]}" | sort -n | awk '{
    a[NR]=$1
  } END {
    if (NR==0) exit 1;
    if (NR%2) print a[(NR+1)/2]; else print int((a[NR/2]+a[NR/2+1])/2)
  }'
}

use_rtt_prior() {
  if [[ "$ROLE" == "entry" ]]; then RTT_MS="$PRIOR_T_ENTRY"; else RTT_MS="$PRIOR_T_EXIT"; fi
  CONF_RTT=20
  log "时延: 使用 ${ROLE} 先验 ${RTT_MS}ms"
}

probe_rtt_short() {
  local median=""
  if [[ "$PROBE_RTT" != "1" ]]; then use_rtt_prior; return; fi
  if [[ -z "$PEER_IP" ]]; then
    use_rtt_prior
    log "时延: 短连接剖面只测对端承载，未提供 --peer-ip"
    return
  fi
  if command -v ping >/dev/null 2>&1; then
    median="$(ping_median_ms "$PEER_IP" || true)"
    if [[ "$median" =~ ^[0-9]+$ ]] && (( median > 0 )); then
      RTT_MS="$median"
      CONF_RTT=80
      log "时延: 对端承载 ${PEER_IP} → ${RTT_MS}ms"
      return
    fi
  fi
  use_rtt_prior
}

probe_rtt_ms() {
  local gw median targets=()
  if [[ "$PROFILE" == "short" ]]; then
    probe_rtt_short
    return
  fi
  if [[ "$PROBE_RTT" != "1" ]]; then use_rtt_prior; return; fi

  gw="$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $3}')"
  [[ -n "$PEER_IP" ]] && targets+=("$PEER_IP")
  [[ -n "$gw" ]] && targets+=("$gw")
  targets+=("1.1.1.1" "8.8.8.8")

  if command -v ping >/dev/null 2>&1; then
    median="$(ping_median_ms "${targets[@]}" || true)"
    if [[ "$median" =~ ^[0-9]+$ ]] && (( median > 0 )); then
      RTT_MS="$median"
      CONF_RTT=$([[ -n "$PEER_IP" ]] && echo 80 || echo 50)
      log "时延: ping 中位数 → ${RTT_MS}ms"
      return
    fi
  fi
  use_rtt_prior
}

measure_rtt_ms() {
  [[ -n "$RTT_MS" ]] && { CONF_RTT=100; return 0; }
  probe_rtt_ms
}

pick_congestion_control() {
  local avail
  avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")"
  if grep -qw bbr <<<"$avail"; then CC="bbr"
  elif grep -qw cubic <<<"$avail"; then CC="cubic"
  else CC="$(awk '{print $1}' <<<"$avail")"; fi
  [[ -n "$CC" ]] || CC="cubic"
  QDISC="fq"
}

derive_params() {
  local mem max_mem_buf
  mem="$(mem_kb)"
  max_mem_buf=$(( mem * 1024 / 10 ))

  BDP_BYTES=$(( UPLINK_MBIT * 1000000 * RTT_MS / 1000 / 8 ))
  SOCK_MAX=$(( BDP_BYTES * BUF_BDP_MULT ))
  SOCK_MAX="$(clamp "$SOCK_MAX" 262144 "$max_mem_buf")"
  SOCK_DEF=$(( BDP_BYTES / 2 ))
  SOCK_DEF="$(clamp "$SOCK_DEF" 131072 "$SOCK_MAX")"

  SHAPED_MBIT=$(( UPLINK_MBIT * SHAPE_FACTOR / 1000 ))
  (( SHAPED_MBIT < 1 )) && SHAPED_MBIT=1
  SHAPED_KBIT=$(( SHAPED_MBIT * 1000 ))

  BURST_BYTES=$(( SHAPED_KBIT * 1000 / 8 / 100 ))
  BURST_BYTES="$(clamp "$BURST_BYTES" 32768 1048576)"

  FQ_LIMIT=$(( BDP_BYTES / MTU ))
  FQ_LIMIT="$(clamp "$FQ_LIMIT" 128 4096)"

  if [[ "$ROLE" == "entry" ]]; then
    SOMAXCONN=65535; SYN_BACKLOG=65535; CT_MAX=131072
  else
    SOMAXCONN=32768; SYN_BACKLOG=32768; CT_MAX=262144
  fi
  (( mem < 1048576 )) && { SOMAXCONN=16384; SYN_BACKLOG=8192; CT_MAX=65536; }

  FILE_MAX=$(( SOMAXCONN * 32 )); (( FILE_MAX < 1048576 )) && FILE_MAX=1048576
  XRAY_NOFILE=$(( SOMAXCONN * 4 )); (( XRAY_NOFILE < 524288 )) && XRAY_NOFILE=524288

  if [[ "$PROFILE" == "short" ]]; then
    local n_sock=64 per_cap
    [[ "$ROLE" == "exit" ]] && n_sock=1024
    per_cap=$(( mem * 1024 / n_sock ))
    SOCK_MAX="$(clamp "$SOCK_MAX" 65536 "$per_cap")"
    SOCK_DEF=16384
    SOCK_DEF="$(clamp "$SOCK_DEF" 4096 "$SOCK_MAX")"
    if [[ "$ROLE" == "entry" ]]; then
      SOMAXCONN=4096; SYN_BACKLOG=4096; CT_MAX=8192
    else
      SOMAXCONN=1024; SYN_BACKLOG=1024; CT_MAX=262144
    fi
    if (( mem < 1048576 )); then
      if [[ "$ROLE" == "entry" ]]; then
        SOMAXCONN=1024; SYN_BACKLOG=1024; CT_MAX=4096
      else
        SOMAXCONN=512; SYN_BACKLOG=512; CT_MAX=32768
      fi
    fi
    FILE_MAX=$(( CT_MAX * 4 ))
    (( FILE_MAX < 65536 )) && FILE_MAX=65536
    XRAY_NOFILE=$(( CT_MAX * 2 ))
    (( XRAY_NOFILE < 65536 )) && XRAY_NOFILE=65536
    TW_BUCKETS="$CT_MAX"
  fi

  pick_congestion_control
}

decide_qdisc() {
  if [[ "$PROFILE" == "short" ]]; then
    if [[ "$CONF_BAND" -ge 40 && "$CONF_RTT" -ge 40 ]]; then
      APPLY_BDP=1
      APPLY_QDISC=1
    else
      APPLY_BDP=0
      APPLY_QDISC=0
    fi
    return
  fi
  APPLY_BDP=1
  if [[ "$SKIP_QDISC_ON_LOW_CONF" == "1" && "$CONF_BAND" -lt 40 ]]; then
    APPLY_QDISC=0
  else
    APPLY_QDISC=1
  fi
}

print_derivation() {
  local qnote="出口整形:      跳过（带宽置信度 ${CONF_BAND}% < 40%，仅 sysctl）"
  local sockline="socket max:    ${SOCK_MAX} bytes"
  [[ "$APPLY_QDISC" == "1" ]] && qnote="出口整形:      已启用 HTB+fq @ ${SHAPED_MBIT}Mbps"
  if [[ "$PROFILE" == "short" && "${APPLY_BDP:-0}" != "1" ]]; then
    qnote="出口整形:      跳过（上行或对端时延未经实测）"
    sockline="socket max:    保持内核默认"
  fi
  cat <<EOF

=== 网络栈推导 (B×T×R) ===
  剖面:          ${PROFILE}
  R 角色:        ${ROLE}
  B 带宽:        ${UPLINK_MBIT} Mbps  (置信度 ${CONF_BAND}%)
  T 时延:        ${RTT_MS} ms         (置信度 ${CONF_RTT}%)
  BDP:           ${BDP_BYTES} bytes
  ${sockline}
  fq limit:      ${FQ_LIMIT} pkts
  CC + qdisc:    ${CC} + ${QDISC}
  somaxconn:     ${SOMAXCONN}
  ${qnote}

EOF
}

backup_state() {
  run "mkdir -p '${STATE_DIR}'"
  [[ "$DRY_RUN" == "1" ]] && return 0
  {
    echo "IFACE=${IFACE}"
    sysctl -n net.core.default_qdisc 2>/dev/null || true
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true
    sysctl -n net.core.rmem_max 2>/dev/null || true
    sysctl -n net.core.wmem_max 2>/dev/null || true
    sysctl -n net.ipv4.tcp_rmem 2>/dev/null || true
    sysctl -n net.ipv4.tcp_wmem 2>/dev/null || true
    sysctl -n net.core.somaxconn 2>/dev/null || true
    sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || true
  } >"${STATE_DIR}/sysctl.before"
  tc qdisc show dev "$IFACE" >"${STATE_DIR}/tc.before" 2>/dev/null || true
}

apply_sysctl_short() {
  log "短连接 sysctl → ${SYSCTL_FILE}（BDP 写入=${APPLY_BDP}）"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run] profile=short role=${ROLE} apply_bdp=${APPLY_BDP} ct=${CT_MAX} somaxconn=${SOMAXCONN} nofile=${XRAY_NOFILE}"
    return 0
  fi
  cat >"$SYSCTL_FILE" <<EOF
# profile=short R=${ROLE} $(date -u +"%FT%TZ")
net.core.default_qdisc = ${QDISC}
net.ipv4.tcp_congestion_control = ${CC}
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = ${TW_BUCKETS}
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = ${FILE_MAX}
EOF
  if [[ "$APPLY_BDP" == "1" ]]; then
    cat >>"$SYSCTL_FILE" <<EOF
# B=${UPLINK_MBIT}Mbps T=${RTT_MS}ms 均为实测
net.core.rmem_max = ${SOCK_MAX}
net.core.wmem_max = ${SOCK_MAX}
net.ipv4.tcp_rmem = 4096 ${SOCK_DEF} ${SOCK_MAX}
net.ipv4.tcp_wmem = 4096 ${SOCK_DEF} ${SOCK_MAX}
EOF
  fi
  sysctl -p "$SYSCTL_FILE" >/dev/null
  if [[ -w /proc/sys/net/netfilter/nf_conntrack_max ]]; then
    run "sysctl -w net.netfilter.nf_conntrack_max=${CT_MAX}"
    echo "net.netfilter.nf_conntrack_max = ${CT_MAX}" >>"$SYSCTL_FILE"
  fi
}

apply_sysctl() {
  if [[ "$PROFILE" == "short" ]]; then
    apply_sysctl_short
    return
  fi
  log "P0+P1 sysctl → ${SYSCTL_FILE}"
  if [[ "$DRY_RUN" == "0" ]]; then
    cat >"$SYSCTL_FILE" <<EOF
# B=${UPLINK_MBIT}Mbps T=${RTT_MS}ms R=${ROLE} $(date -u +"%FT%TZ")
net.core.default_qdisc = ${QDISC}
net.ipv4.tcp_congestion_control = ${CC}
net.core.rmem_max = ${SOCK_MAX}
net.core.wmem_max = ${SOCK_MAX}
net.ipv4.tcp_rmem = 4096 ${SOCK_DEF} ${SOCK_MAX}
net.ipv4.tcp_wmem = 4096 ${SOCK_DEF} ${SOCK_MAX}
net.ipv4.tcp_notsent_lowat = 16384
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}
net.core.netdev_max_backlog = $(( FQ_LIMIT * 4 ))
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 1
fs.file-max = ${FILE_MAX}
vm.swappiness = 10
EOF
    sysctl -p "$SYSCTL_FILE" >/dev/null
  fi
  if [[ -w /proc/sys/net/netfilter/nf_conntrack_max ]]; then
    run "sysctl -w net.netfilter.nf_conntrack_max=${CT_MAX}"
    [[ "$DRY_RUN" == "0" ]] && echo "net.netfilter.nf_conntrack_max = ${CT_MAX}" >>"$SYSCTL_FILE"
  fi
}

apply_qdisc() {
  [[ "$APPLY_QDISC" == "1" ]] || { log "跳过 tc 整形"; return 0; }
  log "P1 出口整形 ${IFACE}: ${SHAPED_MBIT}Mbps burst=${BURST_BYTES} fq=${FQ_LIMIT}"
  run "tc qdisc replace dev '${IFACE}' root handle 1: htb default 10"
  run "tc class replace dev '${IFACE}' parent 1: classid 1:10 htb rate ${SHAPED_KBIT}kbit ceil ${SHAPED_KBIT}kbit burst ${BURST_BYTES}"
  run "tc qdisc replace dev '${IFACE}' parent 1:10 handle 10: fq limit ${FQ_LIMIT} pacing"
}

save_probe_snapshot() {
  run "mkdir -p '${STATE_DIR}'"
  [[ "$DRY_RUN" == "1" ]] && return 0
  cat >"${STATE_DIR}/probe.env" <<EOF
ROLE=${ROLE}
PROFILE=${PROFILE}
UPLINK_MBIT=${UPLINK_MBIT}
RTT_MS=${RTT_MS}
CONF_BAND=${CONF_BAND}
CONF_RTT=${CONF_RTT}
APPLY_QDISC=${APPLY_QDISC}
PEER_IP=${PEER_IP:-}
PROBED_AT=$(date -u +"%FT%TZ")
EOF
}

tune_xray_unit() {
  [[ -f "$UNIT_FILE" ]] || return 0
  log "P2 Xray LimitNOFILE=${XRAY_NOFILE}"
  [[ "$DRY_RUN" == "1" ]] && return 0
  if grep -q '^LimitNOFILE=' "$UNIT_FILE"; then
    sed -i "s/^LimitNOFILE=.*/LimitNOFILE=${XRAY_NOFILE}/" "$UNIT_FILE"
  else
    sed -i "/^\[Service\]/a LimitNOFILE=${XRAY_NOFILE}" "$UNIT_FILE"
  fi
  systemctl daemon-reload
  systemctl is-active --quiet xray 2>/dev/null && systemctl restart xray || true
}

show_kernel() {
  echo "=== 当前内核 ==="
  sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control \
    net.core.rmem_max net.ipv4.tcp_rmem net.core.somaxconn \
    net.ipv4.ip_local_port_range 2>/dev/null || true
  echo; tc qdisc show dev "$IFACE" 2>/dev/null || true
}

restore_state() {
  detect_iface
  [[ -f "${STATE_DIR}/sysctl.before" ]] || die "无备份"
  mapfile -t s <"${STATE_DIR}/sysctl.before"
  [[ ${#s[@]} -ge 9 ]] || die "备份不完整"
  [[ "${s[0]}" =~ ^IFACE=(.+)$ ]] && IFACE="${BASH_REMATCH[1]}"
  run "sysctl -w net.core.default_qdisc='${s[1]}'"
  run "sysctl -w net.ipv4.tcp_congestion_control='${s[2]}'"
  run "sysctl -w net.core.rmem_max='${s[3]}'"
  run "sysctl -w net.core.wmem_max='${s[4]}'"
  run "sysctl -w net.ipv4.tcp_rmem='${s[5]}'"
  run "sysctl -w net.ipv4.tcp_wmem='${s[6]}'"
  run "sysctl -w net.core.somaxconn='${s[7]}'"
  run "sysctl -w net.ipv4.tcp_max_syn_backlog='${s[8]}'"
  rm -f "$SYSCTL_FILE"
  run "tc qdisc del dev '${IFACE}' root 2>/dev/null || true"
  log "已回滚"
}

apply_all() {
  require_root
  require_cmds
  detect_iface
  measure_uplink_mbit
  measure_rtt_ms
  derive_params
  decide_qdisc
  require_cmds
  print_derivation
  backup_state
  apply_sysctl
  apply_qdisc
  save_probe_snapshot
  tune_xray_unit
  log "完成"
}

delegate_short_profile() {
  [[ "$PROFILE" == "short" ]] || return 1
  local here target mode args
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  target="${here}/vless-short-chain.sh"
  [[ -f "$target" ]] || return 1
  mode="optimize"
  [[ "$MODE" == "restore" ]] && mode="restore-net"
  [[ "$MODE" == "status" ]] && mode="net-status"
  args=(--mode "$mode" --role "$ROLE")
  [[ -n "$UPLINK_MBIT" ]] && args+=(--uplink-mbit "$UPLINK_MBIT")
  [[ -n "$RTT_MS" ]] && args+=(--rtt-ms "$RTT_MS")
  [[ -n "$PEER_IP" ]] && args+=(--peer-ip "$PEER_IP")
  [[ -n "$IFACE" ]] && args+=(--iface "$IFACE")
  [[ "$DRY_RUN" == "1" ]] && args+=(--dry-run)
  [[ "$PROBE_BANDWIDTH" == "0" ]] && args+=(--no-probe-bandwidth)
  [[ "$PROBE_RTT" == "0" ]] && args+=(--no-probe-rtt)
  exec bash "$target" "${args[@]}"
}

main() {
  parse_args "$@"
  if delegate_short_profile; then
    return 0
  fi
  case "$MODE" in
    apply) apply_all ;;
    status)
      require_root; require_cmds; detect_iface
      measure_uplink_mbit; measure_rtt_ms; derive_params; decide_qdisc
      print_derivation; show_kernel
      ;;
    restore) require_root; restore_state ;;
    *) die "未知 mode: $MODE" ;;
  esac
}

main "$@"
