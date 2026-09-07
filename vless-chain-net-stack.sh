#!/usr/bin/env bash
# VLESS 链式节点网络栈 — 从基本物理量推导，不依赖外部调优脚本
#
# 推导链：
#   1. BDP = 带宽 × RTT                    → socket 缓冲上界
#   2. 瓶颈应在本机可控队列                 → 出口整形速率 ≈ 0.95 × 实测上行
#   3. 排队长度 ∝ 到达率 × 驻留时间         → fq 浅队列 + pacing
#   4. 角色差异（Entry 扇入 / Exit 扇出）   → 连接表 vs 端口池权重
set -euo pipefail

STATE_DIR="/var/lib/vless-chain/net-stack"
SYSCTL_FILE="/etc/sysctl.d/99-vless-chain-net-stack.conf"
UNIT_FILE="/etc/systemd/system/xray.service"

ROLE=""
MODE="apply"
UPLINK_MBIT=""
RTT_MS=""
PEER_IP=""
IFACE=""
DRY_RUN="0"
NONINTERACTIVE="1"
PROBE_BANDWIDTH="1"
PROBE_RTT="1"
SKIP_QDISC_ON_LOW_CONF="1"

# 探测失败时的角色先验（用户无需提供）
PRIOR_B_ENTRY="1000"
PRIOR_B_EXIT="1000"
PRIOR_T_ENTRY="150"
PRIOR_T_EXIT="80"

# 推导结果置信度 0-100（内部）
CONF_BAND="0"
CONF_RTT="0"

# 推导常量（可调）
SHAPE_FACTOR="950"    # 整形为真实上行的 95.0%（千分比）
BUF_BDP_MULT="2"      # socket max = BDP × 此系数
QDISC_BDP_MULT="1"    # fq limit ≈ BDP / MTU × 此系数
MTU="1500"

usage() {
  cat <<EOF
Usage: $(basename "$0") --role entry|exit [options]

从带宽(B)、时延(T)、角色(R) 三个基本量推导内核参数，专为 VLESS 双跳代理设计。
无需手动提供 B/T — 安装时自动探测；探测失败则按角色使用保守先验值。

Modes:
  apply     计算并应用（默认）
  status    显示推导结果与当前内核状态
  restore   回滚至 apply 前快照

Options:
  --role entry|exit       节点角色（必填）
  --uplink-mbit N         可选：手动覆盖自动探测的带宽
  --rtt-ms N              可选：手动覆盖自动探测的 RTT
  --peer-ip IP            RTT 探测首选对端（entry→exit，exit→entry）
  --iface NAME            出口网卡（默认路由网卡）
  --no-probe-bandwidth    跳过带宽探测，直接用角色先验
  --no-probe-rtt          跳过 RTT 探测，直接用角色先验
  --dry-run               只输出将执行的变更
  -h, --help
EOF
}

log()  { echo "[net-stack] $*"; }
die()  { echo "[net-stack] ERROR: $*" >&2; exit 1; }

run() {
  [[ "$DRY_RUN" == "1" ]] && { echo "[dry-run] $*"; return 0; }
  eval "$@"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role) ROLE="$2"; shift 2 ;;
      --mode) MODE="$2"; shift 2 ;;
      --uplink-mbit) UPLINK_MBIT="$2"; shift 2 ;;
      --rtt-ms) RTT_MS="$2"; shift 2 ;;
      --peer-ip) PEER_IP="$2"; shift 2 ;;
      --iface) IFACE="$2"; shift 2 ;;
      --no-probe-bandwidth) PROBE_BANDWIDTH="0"; shift ;;
      --no-probe-rtt) PROBE_RTT="0"; shift ;;
      --noninteractive) NONINTERACTIVE="1"; shift ;;
      --dry-run) DRY_RUN="1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [[ "$ROLE" == "entry" || "$ROLE" == "exit" ]] || die "必须指定 --role entry|exit"
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "需要 root"
}

detect_iface() {
  [[ -n "$IFACE" ]] && return 0
  IFACE="$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')"
  [[ -n "$IFACE" ]] || die "无法检测默认网卡，请 --iface 指定"
}

mem_kb() { awk '/MemTotal/ {print $2}' /proc/meminfo; }

clamp() {
  local v="$1" lo="$2" hi="$3"
  (( v < lo )) && v=$lo
  (( v > hi )) && v=$hi
  echo "$v"
}

# --- 基本量 1：带宽 B (Mbps) — 全自动，无需用户提供 ---
curl_speed_mbit() {
  local url="$1" secs="$2"
  [[ -n "$url" ]] || return 1
  local out bytes elapsed
  out="$(curl -fsS --max-time "$secs" -o /dev/null -w '%{size_download} %{time_total}' "$url" 2>/dev/null || true)"
  bytes="$(awk '{print $1}' <<<"$out")"
  elapsed="$(awk '{print $2}' <<<"$out")"
  awk -v b="$bytes" -v t="$elapsed" 'BEGIN {
    if (b > 500000 && t > 0.3) printf "%.0f", (b * 8 / t) / 1000000;
  }'
}

probe_bandwidth_mbit() {
  local link_mbit="" samples=() s best i

  if [[ -r "/sys/class/net/${IFACE}/speed" ]]; then
    link_mbit="$(cat "/sys/class/net/${IFACE}/speed" 2>/dev/null || true)"
    [[ "$link_mbit" =~ ^[0-9]+$ ]] && (( link_mbit > 0 )) || link_mbit=""
  fi

  if [[ "$PROBE_BANDWIDTH" == "1" ]] && command -v curl >/dev/null 2>&1; then
    s="$(curl_speed_mbit "https://speed.cloudflare.com/__down?bytes=10000000" 8 || true)"
    [[ -n "$s" ]] && samples+=("$s")
    s="$(curl_speed_mbit "https://speed.cloudflare.com/__down?bytes=25000000" 10 || true)"
    [[ -n "$s" ]] && samples+=("$s")
  fi

  best=0
  for s in "${samples[@]}"; do
    [[ "$s" =~ ^[0-9]+$ ]] && (( s > best )) && best=$s
  done

  if [[ -n "$link_mbit" ]]; then
    local from_link=$(( link_mbit * 70 / 100 ))
    UPLINK_MBIT="$from_link"
    if (( best > UPLINK_MBIT )); then
      UPLINK_MBIT=$best
      CONF_BAND=70
    else
      CONF_BAND=50
    fi
    log "带宽: 网卡 ${link_mbit}M×0.7=${from_link}M，下载采样 ${best:-N/A}M → ${UPLINK_MBIT}M"
  elif (( best > 0 )); then
    UPLINK_MBIT=$best
    CONF_BAND=60
    log "带宽: 下载采样 → ${UPLINK_MBIT}M"
  else
    if [[ "$ROLE" == "entry" ]]; then
      UPLINK_MBIT="$PRIOR_B_ENTRY"
    else
      UPLINK_MBIT="$PRIOR_B_EXIT"
    fi
    CONF_BAND=20
    log "带宽: 探测不可用，使用 ${ROLE} 先验 ${UPLINK_MBIT}M（不限制 sysctl 上界）"
  fi

  UPLINK_MBIT="$(clamp "$UPLINK_MBIT" 10 10000)"
}

measure_uplink_mbit() {
  [[ -n "$UPLINK_MBIT" ]] && { CONF_BAND=100; return 0; }
  probe_bandwidth_mbit
}

# --- 基本量 2：时延 T (ms) — 多目标 ping 取中位数 ---
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

probe_rtt_ms() {
  local gw median targets=()

  gw="$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $3}')"
  [[ -n "$PEER_IP" ]] && targets+=("$PEER_IP")
  [[ -n "$gw" ]] && targets+=("$gw")
  targets+=("1.1.1.1" "8.8.8.8")

  if [[ "$PROBE_RTT" == "1" ]] && command -v ping >/dev/null 2>&1; then
    median="$(ping_median_ms "${targets[@]}" || true)"
    if [[ "$median" =~ ^[0-9]+$ ]] && (( median > 0 )); then
      RTT_MS="$median"
      if [[ -n "$PEER_IP" ]]; then
        CONF_RTT=80
        log "时延: ping 对端/网关/DNS 中位数 → ${RTT_MS}ms（含 ${PEER_IP}）"
      else
        CONF_RTT=50
        log "时延: ping 网关/DNS 中位数 → ${RTT_MS}ms"
      fi
      return 0
    fi
  fi

  if [[ "$ROLE" == "entry" ]]; then
    RTT_MS="$PRIOR_T_ENTRY"
  else
    RTT_MS="$PRIOR_T_EXIT"
  fi
  CONF_RTT=20
  log "时延: 探测不可用，使用 ${ROLE} 先验 ${RTT_MS}ms"
}

measure_rtt_ms() {
  [[ -n "$RTT_MS" ]] && { CONF_RTT=100; return 0; }
  probe_rtt_ms
}

# --- 由 B、T 推导 BDP 与各参数 ---
derive_params() {
  local mem max_mem_buf

  mem="$(mem_kb)"
  max_mem_buf=$(( mem * 1024 / 10 ))   # 缓冲总量不超过内存 10%

  # BDP (bytes) = B(bit/s) × T(s) / 8
  BDP_BYTES=$(( UPLINK_MBIT * 1000000 * RTT_MS / 1000 / 8 ))

  SOCK_MAX=$(( BDP_BYTES * BUF_BDP_MULT ))
  SOCK_MAX="$(clamp "$SOCK_MAX" 262144 "$max_mem_buf")"
  SOCK_DEF=$(( BDP_BYTES / 2 ))
  SOCK_DEF="$(clamp "$SOCK_DEF" 131072 "$SOCK_MAX")"

  SHAPED_MBIT=$(( UPLINK_MBIT * SHAPE_FACTOR / 1000 ))
  (( SHAPED_MBIT < 1 )) && SHAPED_MBIT=1
  SHAPED_KBIT=$(( SHAPED_MBIT * 1000 ))

  # burst ≈ 10ms 整形速率对应字节
  BURST_BYTES=$(( SHAPED_KBIT * 1000 / 8 / 100 ))
  BURST_BYTES="$(clamp "$BURST_BYTES" 32768 1048576)"

  FQ_LIMIT=$(( BDP_BYTES / MTU * QDISC_BDP_MULT ))
  FQ_LIMIT="$(clamp "$FQ_LIMIT" 128 4096)"

  # 角色 R：Entry 扇入多连接，Exit 扇出多目标
  if [[ "$ROLE" == "entry" ]]; then
    SOMAXCONN=65535
    SYN_BACKLOG=65535
    PORT_MIN=1024
    PORT_MAX=65535
    CT_MAX=131072
  else
    SOMAXCONN=32768
    SYN_BACKLOG=32768
    PORT_MIN=1024
    PORT_MAX=65535
    CT_MAX=262144
  fi
  (( mem < 1048576 )) && { SOMAXCONN=16384; SYN_BACKLOG=8192; CT_MAX=65536; }

  FILE_MAX=$(( SOMAXCONN * 32 ))
  (( FILE_MAX < 1048576 )) && FILE_MAX=1048576

  XRAY_NOFILE=$(( SOMAXCONN * 4 ))
  (( XRAY_NOFILE < 524288 )) && XRAY_NOFILE=524288

  pick_congestion_control
}

pick_congestion_control() {
  local avail
  avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")"
  if grep -qw bbr <<<"$avail"; then
    CC="bbr"
  elif grep -qw cubic <<<"$avail"; then
    CC="cubic"
  else
    CC="$(awk '{print $1}' <<<"$avail")"
  fi
  [[ -n "$CC" ]] || CC="cubic"
  QDISC="fq"
}

decide_qdisc() {
  if [[ "$SKIP_QDISC_ON_LOW_CONF" == "1" && "$CONF_BAND" -lt 40 ]]; then
    APPLY_QDISC=0
  else
    APPLY_QDISC=1
  fi
}

print_derivation() {
  local qdisc_note
  if [[ "${APPLY_QDISC:-0}" == "1" ]]; then
    qdisc_note="出口整形:      已启用"
  else
    qdisc_note="出口整形:      跳过（带宽探测置信度低，仅 sysctl）"
  fi
  cat <<EOF

=== 推导过程（全自动，无需手动输入）===
  角色 R:        ${ROLE}
  带宽 B:        ${UPLINK_MBIT} Mbps
  时延 T:        ${RTT_MS} ms
  BDP=B×T:       ${BDP_BYTES} bytes
  整形出口:      ${SHAPED_MBIT} Mbps (${SHAPE_FACTOR}/1000 × B)
  socket max:    ${SOCK_MAX} bytes
  fq limit:      ${FQ_LIMIT} packets
  拥塞控制:      ${CC} + ${QDISC}
  somaxconn:     ${SOMAXCONN}
  探测置信度:    带宽=${CONF_BAND}% 时延=${CONF_RTT}%
  ${qdisc_note}

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

apply_sysctl() {
  log "写入 sysctl: ${SYSCTL_FILE}"
  if [[ "$DRY_RUN" == "0" ]]; then
    cat >"$SYSCTL_FILE" <<EOF
# Derived: B=${UPLINK_MBIT}Mbps T=${RTT_MS}ms role=${ROLE} at $(date -u +"%FT%TZ")

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

net.ipv4.ip_local_port_range = ${PORT_MIN} ${PORT_MAX}
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
  [[ "${APPLY_QDISC:-0}" == "1" ]] || {
    log "跳过 tc 整形（见推导输出）"
    return 0
  }
  log "配置出口队列 ${IFACE}: ${SHAPED_MBIT}Mbps burst=${BURST_BYTES} fq_limit=${FQ_LIMIT}"
  run "tc qdisc replace dev '${IFACE}' root handle 1: htb default 10"
  run "tc class replace dev '${IFACE}' parent 1: classid 1:10 htb rate ${SHAPED_KBIT}kbit ceil ${SHAPED_KBIT}kbit burst ${BURST_BYTES}"
  run "tc qdisc replace dev '${IFACE}' parent 1:10 handle 10: fq limit ${FQ_LIMIT} pacing"
}

save_probe_snapshot() {
  run "mkdir -p '${STATE_DIR}'"
  [[ "$DRY_RUN" == "1" ]] && return 0
  cat >"${STATE_DIR}/probe.env" <<EOF
ROLE=${ROLE}
UPLINK_MBIT=${UPLINK_MBIT}
RTT_MS=${RTT_MS}
CONF_BAND=${CONF_BAND}
CONF_RTT=${CONF_RTT}
APPLY_QDISC=${APPLY_QDISC:-0}
PEER_IP=${PEER_IP:-}
PROBED_AT=$(date -u +"%FT%TZ")
EOF
}

tune_xray_unit() {
  [[ -f "$UNIT_FILE" ]] || return 0
  log "Xray LimitNOFILE=${XRAY_NOFILE}"
  [[ "$DRY_RUN" == "1" ]] && return 0
  if grep -q '^LimitNOFILE=' "$UNIT_FILE"; then
    sed -i "s/^LimitNOFILE=.*/LimitNOFILE=${XRAY_NOFILE}/" "$UNIT_FILE"
  else
    sed -i "/^\[Service\]/a LimitNOFILE=${XRAY_NOFILE}" "$UNIT_FILE"
  fi
  systemctl daemon-reload
  systemctl is-active --quiet xray 2>/dev/null && systemctl restart xray || true
}

show_status() {
  detect_iface
  echo "=== 当前内核 ==="
  sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control \
    net.core.rmem_max net.ipv4.tcp_rmem net.core.somaxconn \
    net.ipv4.ip_local_port_range 2>/dev/null || true
  echo
  tc qdisc show dev "$IFACE" 2>/dev/null || true
}

restore_state() {
  detect_iface
  [[ -f "${STATE_DIR}/sysctl.before" ]] || die "无备份，无法 restore"
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
  log "已回滚（复杂 tc 树请手动恢复）"
}

apply_all() {
  require_root
  detect_iface
  measure_uplink_mbit
  measure_rtt_ms
  derive_params
  decide_qdisc
  print_derivation
  backup_state
  apply_sysctl
  apply_qdisc
  save_probe_snapshot
  tune_xray_unit
  log "网络栈推导配置已应用（无需手动提供 B/T）"
}

main() {
  parse_args "$@"
  case "$MODE" in
    apply) apply_all ;;
    status)
      require_root
      detect_iface
      measure_uplink_mbit
      measure_rtt_ms
      derive_params
      decide_qdisc
      print_derivation
      show_status
      ;;
    restore)
      require_root
      restore_state
      ;;
    *) die "未知 mode: $MODE" ;;
  esac
}

main "$@"
