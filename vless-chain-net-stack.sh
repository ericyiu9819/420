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
NONINTERACTIVE="0"

# 推导常量（可调）
SHAPE_FACTOR="950"    # 整形为真实上行的 95.0%（千分比）
BUF_BDP_MULT="2"      # socket max = BDP × 此系数
QDISC_BDP_MULT="1"    # fq limit ≈ BDP / MTU × 此系数
MTU="1500"

usage() {
  cat <<EOF
Usage: $(basename "$0") --role entry|exit [options]

从带宽(B)、时延(T)、角色(R) 三个基本量推导内核参数，专为 VLESS 双跳代理设计。

Modes:
  apply     计算并应用（默认）
  status    显示推导结果与当前内核状态
  restore   回滚至 apply 前快照

Options:
  --role entry|exit       节点角色（必填）
  --uplink-mbit N         可持续上行 Mbps（未给则探测）
  --rtt-ms N              基线 RTT ms（未给则 ping 对端）
  --peer-ip IP            RTT 探测对端（entry→exit IP，exit→entry IP）
  --iface NAME            出口网卡（默认路由网卡）
  --noninteractive        探测失败时用保守默认值，不交互
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

# --- 基本量 1：带宽 B (Mbps) ---
measure_uplink_mbit() {
  [[ -n "$UPLINK_MBIT" ]] && return 0

  local link_mbit="" sample_mbit="" target url

  # 物理链路速率（若 hypervisor 暴露）
  if [[ -r "/sys/class/net/${IFACE}/speed" ]]; then
    link_mbit="$(cat "/sys/class/net/${IFACE}/speed" 2>/dev/null || true)"
    [[ "$link_mbit" =~ ^[0-9]+$ ]] && (( link_mbit > 0 )) || link_mbit=""
  fi

  # 短时下载采样：吞吐 ≈ min(路径带宽, 对端限速)
  target="${PEER_IP:-1.1.1.1}"
  url="http://${target}/" 
  if command -v curl >/dev/null 2>&1; then
    local bytes elapsed bps
    bytes="$(curl -fsS --max-time 4 -o /dev/null -w '%{size_download}' "$url" 2>/dev/null || echo 0)"
    elapsed="$(curl -fsS --max-time 4 -o /dev/null -w '%{time_total}' "$url" 2>/dev/null || echo 0)"
    if awk -v b="$bytes" -v t="$elapsed" 'BEGIN { exit !(b > 100000 && t > 0.2) }'; then
      sample_mbit="$(awk -v b="$bytes" -v t="$elapsed" 'BEGIN { printf "%.0f", (b * 8 / t) / 1000000 }')"
    fi
  fi

  if [[ -n "$link_mbit" ]]; then
    # 链路速率通常高于 VPS 套餐出口；取链路 70% 与采样较大值，再 cap
    local from_link=$(( link_mbit * 70 / 100 ))
    UPLINK_MBIT="$from_link"
    if [[ -n "$sample_mbit" ]] && (( sample_mbit > UPLINK_MBIT )); then
      UPLINK_MBIT="$sample_mbit"
    fi
    log "带宽推导: 链路 ${link_mbit}M × 0.7 → ${from_link}M，采样 ${sample_mbit:-N/A}M → 采用 ${UPLINK_MBIT}M"
  elif [[ -n "$sample_mbit" ]]; then
    UPLINK_MBIT="$sample_mbit"
    log "带宽推导: 下载采样 ${UPLINK_MBIT}M"
  else
    UPLINK_MBIT="500"
    log "带宽推导: 无法探测，保守默认 ${UPLINK_MBIT}M（可用 --uplink-mbit 覆盖）"
  fi

  UPLINK_MBIT="$(clamp "$UPLINK_MBIT" 10 10000)"
}

# --- 基本量 2：时延 T (ms) ---
measure_rtt_ms() {
  [[ -n "$RTT_MS" ]] && return 0
  local target="${PEER_IP:-1.1.1.1}" avg
  if command -v ping >/dev/null 2>&1; then
    avg="$(ping -c 6 -i 0.2 -W 1 "$target" 2>/dev/null | awk -F'/' '/min\/avg/ {print $5}' | cut -d. -f1)"
    if [[ "$avg" =~ ^[0-9]+$ ]] && (( avg > 0 )); then
      RTT_MS="$avg"
      log "时延推导: ping ${target} → ${RTT_MS}ms"
      return 0
    fi
  fi
  RTT_MS="80"
  log "时延推导: ping 失败，默认 ${RTT_MS}ms"
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

print_derivation() {
  cat <<EOF

=== 推导过程 ===
  角色 R:        ${ROLE}
  带宽 B:        ${UPLINK_MBIT} Mbps（可持续上行）
  时延 T:        ${RTT_MS} ms
  BDP=B×T:       ${BDP_BYTES} bytes  (= ${UPLINK_MBIT}M × ${RTT_MS}ms)
  整形出口:      ${SHAPED_MBIT} Mbps (${SHAPE_FACTOR}/1000 × B)
  socket max:    ${SOCK_MAX} bytes (BDP×${BUF_BDP_MULT}, 受内存约束)
  fq limit:      ${FQ_LIMIT} packets (≈ BDP/${MTU})
  拥塞控制:      ${CC} + ${QDISC}
  somaxconn:     ${SOMAXCONN} (${ROLE} 扇入/扇出模型)

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
  # 把瓶颈队列钉在本机出口：HTB 限速 + fq pacing，队列深度由 BDP 推导
  log "配置出口队列 ${IFACE}: ${SHAPED_MBIT}Mbps burst=${BURST_BYTES} fq_limit=${FQ_LIMIT}"
  run "tc qdisc replace dev '${IFACE}' root handle 1: htb default 10"
  run "tc class replace dev '${IFACE}' parent 1: classid 1:10 htb rate ${SHAPED_KBIT}kbit ceil ${SHAPED_KBIT}kbit burst ${BURST_BYTES}"
  run "tc qdisc replace dev '${IFACE}' parent 1:10 handle 10: fq limit ${FQ_LIMIT} pacing"
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
  print_derivation
  backup_state
  apply_sysctl
  apply_qdisc
  tune_xray_unit
  log "网络栈推导配置已应用"
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
