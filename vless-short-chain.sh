#!/usr/bin/env bash
# VLESS + Reality 短连接双跳 — 完整单文件
# 不依赖同目录的其他脚本。安装、客户端配置、网络优化、回滚都在这里。
#
# 一条短流的时间 ≈ 各段握手 RTT 之和，字节数不决定它。
# 推出来的结构:
#   1. Client→Entry、Entry→Exit 各保持少量长寿命 Reality 承载
#   2. 短流（以及 DNS）复用在承载上，Mux 只开在客户端一侧，服务端自动适配
#   3. 在飞短流按浏览器量级 N=16；Xray 突发后倾向维持 2 条外层 TCP，
#      所以每条承载的并发子流 = N/2 = 8（协议上限 128，不取满）
#   4. UDP 走独立 XUDP 管道，避免和 TCP 短流共用一个队头阻塞域
#   5. UDP/443 拒绝走 Mux，浏览器回落到 TCP
#   6. 不设置 flow。Vision 只接受原始 TCP 和 XUDP，会拒绝 TCP Mux
#   7. 目的地握手省不掉。Exit 的 freedom 打开 TFO，只对支持的目的地少一次 RTT
#   8. 入站 Keep-Alive 默认关闭，承载会在两次短流之间被中间设备拆掉，所以入站显式打开
#   9. shortId 只放生成值。Exit 私钥留在 Exit，拷走的 handoff 只有公钥
#  网络性能（同一脚本内）:
#  10. 承载是少数长 TCP。有 bbrplus 就用它，否则用 bbr，再否则 cubic，
#      并把出口队列换成 fq，BBR 的 pacing 才在当前网卡上生效
#  11. 短流在用户态默认有 512KB 缓冲，响应会在里面多待一轮。Xray bufferSize 收到 8KB
#  12. 连接表只跟角色有关：Entry 放大监听队列，Exit 放大 conntrack 和包积压
#  13. 套接字上限和 HTB/cake 整形只在上行与对端时延都实测之后写入
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
STATE_FILE="${XRAY_DIR}/chain-credentials.env"
HANDOFF_FILE="${XRAY_DIR}/chain-handoff.env"
CLIENT_JSON="${XRAY_DIR}/short-client.json"
LOG_DIR="/var/log/xray"
SERVICE_NAME="xray"
PORT=443

# N=16, 外层管道数=2 → 每条承载 8 条子流
MUX_CONCURRENCY=8
XUDP_CONCURRENCY=16
XUDP_UDP443="reject"
KEEPALIVE_IDLE=45
KEEPALIVE_INTERVAL=45
# Xray 每条连接的用户态缓冲，单位 KB。短响应远小于默认 512KB。
XRAY_BUFFER_KB=8
NET_STATE_DIR="/var/lib/vless-short/net"
NET_SYSCTL_FILE="/etc/sysctl.d/99-vless-short-net.conf"
XRAY_UNIT="/etc/systemd/system/xray.service"
PRIOR_B_ENTRY=1000
PRIOR_B_EXIT=1000
PRIOR_T_ENTRY=150
PRIOR_T_EXIT=80

MODE=""
CRED_FILE=""
ENTRY_IP=""
EXIT_IP=""
EXIT_UUID=""
EXIT_PUBLIC_KEY=""
EXIT_SHORT_ID=""
EXIT_REALITY_DEST="www.cloudflare.com:443"
EXIT_REALITY_SNI="www.cloudflare.com"
ENTRY_REALITY_DEST="www.microsoft.com:443"
ENTRY_REALITY_SNI="www.microsoft.com"
ENTRY_UUID=""
ENTRY_PRIVATE_KEY=""
ENTRY_PUBLIC_KEY=""
ENTRY_SHORT_ID=""
EXIT_PRIVATE_KEY=""
NET_TUNE="1"
UPLINK_MBIT=""
RTT_MS=""
NONINTERACTIVE="0"
ROLE=""
IFACE=""
PEER_IP=""
DRY_RUN="0"
PROBE_BANDWIDTH="1"
PROBE_RTT="1"
RESTART_XRAY="1"
CONF_BAND=0
CONF_RTT=0
APPLY_BDP=0
APPLY_SHAPE=0
QDISC_ACTION="keep"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

短连接双跳: Client → Entry(VLESS+Reality+Mux) → Exit(VLESS+Reality+Mux) → Internet
本文件自包含：链路安装、客户端 JSON、网络优化、回滚。

Commands:
  install-exit    安装 Exit（第一步，出口 VPS）
  install-entry   安装 Entry（第二步，入口 VPS）
  net-stack       只做网络优化（安装时已自动做）
  status          xray + 凭据 + 网络优化
  client          输出客户端 JSON（含 Mux）与链接
  restore-net     回滚本脚本写入的网络优化
  self-test       校验配置与推导（不需要 root）

快速部署:
  sudo bash $(basename "$0") install-exit --entry-ip <Entry公网IP>
  # 把 /usr/local/etc/xray/chain-handoff.env 拷到 Entry（没有私钥）
  sudo bash $(basename "$0") install-entry --cred-file ./chain-handoff.env

Exit:
  --entry-ip IP             Entry 公网 IP（防火墙白名单，必填）
  --reality-dest HOST:PORT  默认 ${EXIT_REALITY_DEST}
  --reality-sni NAME        默认 ${EXIT_REALITY_SNI}

Entry:
  --cred-file PATH          Exit 的 chain-handoff.env
  --exit-ip / --exit-uuid / --exit-public-key / --exit-short-id
  --exit-reality-sni NAME
  --reality-dest HOST:PORT  默认 ${ENTRY_REALITY_DEST}
  --reality-sni NAME        默认 ${ENTRY_REALITY_SNI}

Common:
  --no-net-tune             只装链路
  --uplink-mbit N           已测出口速率。和实测时延同时具备才写 BDP、才整形
  --rtt-ms N                覆盖对端承载时延
  --role entry|exit         未安装节点时，net-stack / restore-net 需要
  --peer-ip IP              承载对端，用于测量时延
  --iface NAME
  --dry-run
  --noninteractive
  -h, --help

也接受 --mode exit|entry|optimize|status|client|restore-net|self-test
EOF
}

log() { echo "[short-chain] $*"; }
die() { echo "[short-chain] ERROR: $*" >&2; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请 sudo 运行"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) MODE="$2"; shift 2 ;;
      --entry-ip) ENTRY_IP="$2"; shift 2 ;;
      --exit-ip) EXIT_IP="$2"; shift 2 ;;
      --exit-uuid) EXIT_UUID="$2"; shift 2 ;;
      --exit-public-key) EXIT_PUBLIC_KEY="$2"; shift 2 ;;
      --exit-short-id) EXIT_SHORT_ID="$2"; shift 2 ;;
      --exit-reality-sni) EXIT_REALITY_SNI="$2"; shift 2 ;;
      --cred-file) CRED_FILE="$2"; shift 2 ;;
      --reality-dest)
        [[ "$MODE" == "exit" ]] && EXIT_REALITY_DEST="$2" || ENTRY_REALITY_DEST="$2"
        shift 2 ;;
      --reality-sni)
        [[ "$MODE" == "exit" ]] && EXIT_REALITY_SNI="$2" || ENTRY_REALITY_SNI="$2"
        shift 2 ;;
      --no-net-tune) NET_TUNE="0"; shift ;;
      --uplink-mbit) UPLINK_MBIT="$2"; shift 2 ;;
      --rtt-ms) RTT_MS="$2"; shift 2 ;;
      --role) ROLE="$2"; shift 2 ;;
      --peer-ip) PEER_IP="$2"; shift 2 ;;
      --iface) IFACE="$2"; shift 2 ;;
      --dry-run) DRY_RUN="1"; shift ;;
      --no-probe-bandwidth) PROBE_BANDWIDTH="0"; shift ;;
      --no-probe-rtt) PROBE_RTT="0"; shift ;;
      --noninteractive) NONINTERACTIVE="1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [[ -n "$MODE" ]] || die "必须 --mode exit|entry|status|client|optimize|restore-net|net-status|self-test"
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS="$(echo "${ID:-unknown}" | tr '[:upper:]' '[:lower:]')"
  else
    OS="unknown"
  fi
}

install_deps() {
  detect_os
  local pkgs=(curl qrencode jq openssl ca-certificates iproute2 iputils-ping ethtool)
  if [[ "$OS" == *"debian"* || "$OS" == *"ubuntu"* ]]; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" ufw
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}" firewalld || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}" firewalld || true
  else
    log "未识别 OS，请确保已安装: ${pkgs[*]}"
  fi
}

install_xray() {
  if command -v xray >/dev/null 2>&1 && [[ -x /usr/local/bin/xray ]]; then
    log "Xray 已安装，跳过"
    return
  fi
  log "安装 Xray-core ..."
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
}

gen_uuid() { xray uuid | awk '{print $NF}'; }

parse_x25519() {
  local output priv pub
  output="$(xray x25519)"
  priv="$(echo "$output" | awk -F': ' '/Private/ {print $2}' | tr -d ' \r')"
  pub="$(echo "$output" | awk -F': ' '/Public/ {print $2}' | tr -d ' \r')"
  [[ -n "$priv" && -n "$pub" ]] || die "x25519 失败"
  echo "$priv $pub"
}

gen_short_id() { openssl rand -hex 4; }

validate_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "无效 IP: $1"
}

prompt_if_empty() {
  local var_name="$1" prompt_text="$2" current
  current="$(eval "echo \${$var_name}")"
  if [[ -z "$current" && "$NONINTERACTIVE" != "1" ]]; then
    read -r -p "$prompt_text: " current
    eval "$var_name=\"\$current\""
  fi
  current="$(eval "echo \${$var_name}")"
  [[ -n "$current" ]] || die "缺少: $var_name"
}

load_exit_credentials() {
  [[ -f "$CRED_FILE" ]] || die "凭据不存在: $CRED_FILE"
  # shellcheck disable=SC1090
  source "$CRED_FILE"
  EXIT_IP="${EXIT_IP:-}"; EXIT_UUID="${EXIT_UUID:-}"
  EXIT_PUBLIC_KEY="${EXIT_PUBLIC_KEY:-}"; EXIT_SHORT_ID="${EXIT_SHORT_ID:-}"
  EXIT_REALITY_SNI="${EXIT_REALITY_SNI:-www.cloudflare.com}"
  if grep -q 'PRIVATE_KEY' "$CRED_FILE"; then
    die "handoff 不应包含私钥。请使用 Exit 上的 ${HANDOFF_FILE}"
  fi
}

bearer_sockopt() {
  cat <<EOF
"sockopt": { "tcpKeepAliveIdle": ${KEEPALIVE_IDLE}, "tcpKeepAliveInterval": ${KEEPALIVE_INTERVAL}, "tcpFastOpen": true }
EOF
}

policy_json() {
  cat <<EOF
"policy": { "levels": { "0": { "handshake": 4, "connIdle": 300, "uplinkOnly": 2, "downlinkOnly": 5, "bufferSize": ${XRAY_BUFFER_KB} } } }
EOF
}

write_exit_config() {
  mkdir -p "$XRAY_DIR" "$LOG_DIR"
  cat >"$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning", "access": "${LOG_DIR}/access.log", "error": "${LOG_DIR}/error.log" },
  $(policy_json),
  "inbounds": [{
    "tag": "vless-from-entry", "listen": "0.0.0.0", "port": ${PORT},
    "protocol": "vless",
    "settings": { "clients": [{ "id": "${EXIT_UUID}" }], "decryption": "none" },
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "show": false, "dest": "${EXIT_REALITY_DEST}", "xver": 0,
        "serverNames": ["${EXIT_REALITY_SNI}"],
        "privateKey": "${EXIT_PRIVATE_KEY}",
        "shortIds": ["${EXIT_SHORT_ID}"]
      },
      $(bearer_sockopt)
    }
  }],
  "outbounds": [
    {
      "tag": "direct", "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" },
      "streamSettings": { "sockopt": { "tcpFastOpen": true } }
    },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [{ "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }]
  }
}
EOF
}

write_entry_config() {
  mkdir -p "$XRAY_DIR" "$LOG_DIR"
  cat >"$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning", "access": "${LOG_DIR}/access.log", "error": "${LOG_DIR}/error.log" },
  $(policy_json),
  "inbounds": [{
    "tag": "vless-in", "listen": "0.0.0.0", "port": ${PORT},
    "protocol": "vless",
    "settings": { "clients": [{ "id": "${ENTRY_UUID}" }], "decryption": "none" },
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "show": false, "dest": "${ENTRY_REALITY_DEST}", "xver": 0,
        "serverNames": ["${ENTRY_REALITY_SNI}"],
        "privateKey": "${ENTRY_PRIVATE_KEY}",
        "shortIds": ["${ENTRY_SHORT_ID}"]
      },
      $(bearer_sockopt)
    }
  }],
  "outbounds": [
    {
      "tag": "to-exit", "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "${EXIT_IP}", "port": ${PORT},
          "users": [{ "id": "${EXIT_UUID}", "encryption": "none" }]
        }]
      },
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": {
          "show": false, "serverName": "${EXIT_REALITY_SNI}",
          "fingerprint": "chrome", "publicKey": "${EXIT_PUBLIC_KEY}",
          "shortId": "${EXIT_SHORT_ID}", "spiderX": "/"
        },
        $(bearer_sockopt)
      },
      "mux": {
        "enabled": true,
        "concurrency": ${MUX_CONCURRENCY},
        "xudpConcurrency": ${XUDP_CONCURRENCY},
        "xudpProxyUDP443": "${XUDP_UDP443}"
      }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "direct" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "to-exit" }
    ]
  }
}
EOF
}

firewall_allow_ssh() {
  if command -v ufw >/dev/null 2>&1; then
    ufw --force enable || true
    ufw allow OpenSSH || true
  fi
}

setup_firewall_exit() {
  validate_ip "$ENTRY_IP"
  firewall_allow_ssh
  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "${PORT}/tcp" 2>/dev/null || true
    ufw allow from "${ENTRY_IP}" to any port "${PORT}" proto tcp comment 'vless-short-exit' || true
    ufw reload || true
    log "UFW: ${PORT} 仅 ${ENTRY_IP}"
  elif command -v nft >/dev/null 2>&1; then
    nft list table inet vless_chain >/dev/null 2>&1 || \
      nft add table inet vless_chain
    nft list chain inet vless_chain input >/dev/null 2>&1 || \
      nft 'add chain inet vless_chain input { type filter hook input priority 0; policy accept; }'
    nft add rule inet vless_chain input tcp dport "${PORT}" ip saddr "${ENTRY_IP}" accept 2>/dev/null || true
    nft add rule inet vless_chain input tcp dport "${PORT}" drop 2>/dev/null || true
    log "nftables: ${PORT} 仅 ${ENTRY_IP}"
  else
    log "请手动限制 ${PORT}/tcp 来源为 ${ENTRY_IP}"
  fi
}

setup_firewall_entry() {
  firewall_allow_ssh
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PORT}/tcp" comment 'vless-short-entry' || true
    ufw reload || true
    log "UFW: 开放 ${PORT}"
  fi
}

net_run() {
  [[ "$DRY_RUN" == "1" ]] && { echo "[dry-run] $*"; return 0; }
  eval "$@"
}

net_clamp() {
  local v="$1" lo="$2" hi="$3"
  (( v < lo )) && v=$lo
  (( v > hi )) && v=$hi
  echo "$v"
}

net_detect_iface() {
  [[ -n "$IFACE" ]] && return 0
  command -v ip >/dev/null 2>&1 || die "缺少 ip"
  IFACE="$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')"
  [[ -n "$IFACE" ]] || die "无法检测网卡，请 --iface"
}

net_mem_kb() { awk '/MemTotal/ {print $2}' /proc/meminfo; }

net_pick_cc() {
  local avail active
  if [[ "$DRY_RUN" != "1" ]]; then
    modprobe tcp_bbr 2>/dev/null || true
  else
    echo "[dry-run] modprobe tcp_bbr"
  fi
  avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo cubic)"
  active="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")"
  if grep -qw bbrplus <<<"$avail"; then CC="bbrplus"
  elif grep -qw bbr <<<"$avail"; then CC="bbr"
  elif grep -qw cubic <<<"$avail"; then CC="cubic"
  else CC="${active:-cubic}"; fi
  [[ -n "$CC" ]] || CC="cubic"
}

net_bandwidth_prior() {
  if [[ "$ROLE" == "entry" ]]; then UPLINK_MBIT="$PRIOR_B_ENTRY"; else UPLINK_MBIT="$PRIOR_B_EXIT"; fi
  CONF_BAND=20
}

net_rtt_prior() {
  if [[ "$ROLE" == "entry" ]]; then RTT_MS="$PRIOR_T_ENTRY"; else RTT_MS="$PRIOR_T_EXIT"; fi
  CONF_RTT=20
}

net_ping_ms() {
  local avg
  avg="$(ping -c 4 -i 0.2 -W 1 "$1" 2>/dev/null | awk -F'/' '/min\/avg/ {print $5}' | cut -d. -f1)"
  [[ "$avg" =~ ^[0-9]+$ ]] && (( avg > 0 )) || return 1
  echo "$avg"
}

net_measure() {
  if [[ -n "${UPLINK_SET:-}" ]]; then
    CONF_BAND=100
  else
    net_bandwidth_prior
    log "上行未实测，不用网卡速率或下载采样代替"
  fi
  if [[ -n "${RTT_SET:-}" ]]; then
    CONF_RTT=100
  elif [[ "$PROBE_RTT" == "1" && -n "$PEER_IP" ]] && command -v ping >/dev/null 2>&1; then
    local ms
    ms="$(net_ping_ms "$PEER_IP" || true)"
    if [[ "$ms" =~ ^[0-9]+$ ]]; then
      RTT_MS="$ms"
      CONF_RTT=80
      log "时延: 对端承载 ${PEER_IP} → ${RTT_MS}ms"
    else
      net_rtt_prior
    fi
  else
    net_rtt_prior
  fi
}

net_derive() {
  local mem n_sock per_cap
  mem="$(net_mem_kb)"
  net_pick_cc
  BDP_BYTES=$(( UPLINK_MBIT * 1000000 * RTT_MS / 1000 / 8 ))
  SOCK_MAX=$(( BDP_BYTES * 2 ))
  if [[ "$ROLE" == "entry" ]]; then
    n_sock=64
    SOMAXCONN=4096; SYN_BACKLOG=4096; CT_MAX=8192; DEV_BACKLOG=4096
  else
    n_sock=1024
    SOMAXCONN=1024; SYN_BACKLOG=1024; CT_MAX=262144; DEV_BACKLOG=16384
  fi
  if (( mem < 1048576 )); then
    if [[ "$ROLE" == "entry" ]]; then
      SOMAXCONN=1024; SYN_BACKLOG=1024; CT_MAX=4096; DEV_BACKLOG=1024
    else
      SOMAXCONN=512; SYN_BACKLOG=512; CT_MAX=32768; DEV_BACKLOG=4096
    fi
  fi
  per_cap=$(( mem * 1024 / n_sock ))
  SOCK_MAX="$(net_clamp "$SOCK_MAX" 65536 "$per_cap")"
  SOCK_DEF=16384
  SOCK_DEF="$(net_clamp "$SOCK_DEF" 4096 "$SOCK_MAX")"
  SHAPED_MBIT=$(( UPLINK_MBIT * 95 / 100 ))
  (( SHAPED_MBIT < 1 )) && SHAPED_MBIT=1
  SHAPED_KBIT=$(( SHAPED_MBIT * 1000 ))
  BURST_BYTES="$(net_clamp $(( SHAPED_KBIT * 1000 / 8 / 100 )) 32768 1048576)"
  FQ_LIMIT="$(net_clamp $(( BDP_BYTES / 1500 )) 128 4096)"
  FILE_MAX=$(( CT_MAX * 4 ))
  (( FILE_MAX < 65536 )) && FILE_MAX=65536
  XRAY_NOFILE=$(( CT_MAX * 2 ))
  (( XRAY_NOFILE < 65536 )) && XRAY_NOFILE=65536
  TW_BUCKETS="$CT_MAX"
}

net_decide() {
  local root=""
  APPLY_BDP=0
  APPLY_SHAPE=0
  if [[ "$CONF_BAND" -ge 40 && "$CONF_RTT" -ge 40 ]]; then
    APPLY_BDP=1
    APPLY_SHAPE=1
  fi
  if command -v tc >/dev/null 2>&1 && [[ -n "$IFACE" ]]; then
    root="$(tc qdisc show dev "$IFACE" 2>/dev/null | awk 'NR==1 {print $2}')"
  fi
  ROOT_QDISC="$root"
  if [[ "$APPLY_SHAPE" == "1" ]]; then
    if [[ "$root" == "cake" ]]; then QDISC_ACTION="cake"; else QDISC_ACTION="htb"; fi
  else
    case "$root" in
      cake|fq|htb) QDISC_ACTION="keep" ;;
      *) QDISC_ACTION="fq" ;;
    esac
  fi
}

net_print() {
  local buf="套接字缓冲:  保持内核默认"
  local q="出口队列:    ${QDISC_ACTION}"
  [[ "$APPLY_BDP" == "1" ]] && buf="套接字缓冲:  默认 ${SOCK_DEF}，上限 ${SOCK_MAX}"
  [[ "$QDISC_ACTION" == "htb" ]] && q="出口队列:    HTB+fq @ ${SHAPED_MBIT}Mbps"
  [[ "$QDISC_ACTION" == "cake" ]] && q="出口队列:    cake @ ${SHAPED_MBIT}Mbps"
  [[ "$QDISC_ACTION" == "fq" ]] && q="出口队列:    fq（不限速，只做 pacing）"
  [[ "$QDISC_ACTION" == "keep" ]] && q="出口队列:    保持现有 ${ROOT_QDISC:-队列}"
  cat <<EOF

=== 短连接网络优化 ===
  角色:          ${ROLE}
  拥塞控制:      ${CC}
  上行:          ${UPLINK_MBIT} Mbps（置信度 ${CONF_BAND}%）
  对端时延:      ${RTT_MS} ms（置信度 ${CONF_RTT}%）
  ${buf}
  ${q}
  somaxconn:     ${SOMAXCONN}
  conntrack:     ${CT_MAX}
  网卡积压:      ${DEV_BACKLOG}
  Xray 缓冲:     ${XRAY_BUFFER_KB} KB/连接
  Xray NOFILE:   ${XRAY_NOFILE}

EOF
}

net_plan() {
  net_detect_iface
  net_measure
  net_derive
  net_decide
  net_print
}

net_sysctl_lines() {
  cat <<EOF
# vless-short role=${ROLE} $(date -u +"%FT%TZ")
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${CC}
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = ${TW_BUCKETS}
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}
net.core.netdev_max_backlog = ${DEV_BACKLOG}
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = ${FILE_MAX}
EOF
  if [[ "$APPLY_BDP" == "1" ]]; then
    cat <<EOF
net.core.rmem_max = ${SOCK_MAX}
net.core.wmem_max = ${SOCK_MAX}
net.ipv4.tcp_rmem = 4096 ${SOCK_DEF} ${SOCK_MAX}
net.ipv4.tcp_wmem = 4096 ${SOCK_DEF} ${SOCK_MAX}
EOF
  fi
}

net_backup() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  mkdir -p "$NET_STATE_DIR"
  [[ -f "${NET_STATE_DIR}/sysctl.before" ]] && return 0
  local k
  {
    echo "IFACE=${IFACE}"
    for k in net.core.default_qdisc net.ipv4.tcp_congestion_control net.ipv4.tcp_ecn \
      net.ipv4.tcp_fastopen net.ipv4.tcp_mtu_probing net.ipv4.tcp_slow_start_after_idle \
      net.ipv4.tcp_notsent_lowat net.ipv4.tcp_fin_timeout net.ipv4.tcp_tw_reuse \
      net.ipv4.tcp_max_tw_buckets net.core.somaxconn net.ipv4.tcp_max_syn_backlog \
      net.core.netdev_max_backlog net.ipv4.ip_local_port_range fs.file-max \
      net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem; do
      echo "${k}=$(sysctl -n "$k" 2>/dev/null || true)"
    done
  } >"${NET_STATE_DIR}/sysctl.before"
  tc qdisc show dev "$IFACE" >"${NET_STATE_DIR}/tc.before" 2>/dev/null || true
}

net_apply_sysctl() {
  log "写入 ${NET_SYSCTL_FILE}"
  if [[ "$DRY_RUN" == "1" ]]; then
    net_sysctl_lines | sed 's/^/[dry-run] /'
    return 0
  fi
  mkdir -p "$(dirname "$NET_SYSCTL_FILE")"
  net_sysctl_lines >"$NET_SYSCTL_FILE"
  sysctl -p "$NET_SYSCTL_FILE" >/dev/null
  if [[ -w /proc/sys/net/netfilter/nf_conntrack_max ]]; then
    sysctl -w "net.netfilter.nf_conntrack_max=${CT_MAX}" >/dev/null
    echo "net.netfilter.nf_conntrack_max = ${CT_MAX}" >>"$NET_SYSCTL_FILE"
  fi
}

net_apply_qdisc() {
  case "$QDISC_ACTION" in
    keep) log "保持现有出口队列 ${ROOT_QDISC:-}" ;;
    fq)
      log "出口 ${IFACE} 换为 fq"
      net_run "tc qdisc replace dev '${IFACE}' root fq"
      ;;
    htb)
      log "出口 ${IFACE} 整形 ${SHAPED_MBIT}Mbps"
      net_run "tc qdisc replace dev '${IFACE}' root handle 1: htb default 10"
      net_run "tc class replace dev '${IFACE}' parent 1: classid 1:10 htb rate ${SHAPED_KBIT}kbit ceil ${SHAPED_KBIT}kbit burst ${BURST_BYTES}"
      net_run "tc qdisc replace dev '${IFACE}' parent 1:10 handle 10: fq limit ${FQ_LIMIT}"
      ;;
    cake)
      log "出口 ${IFACE} cake 带宽 ${SHAPED_MBIT}Mbps"
      net_run "tc qdisc replace dev '${IFACE}' root cake bandwidth ${SHAPED_KBIT}kbit rtt ${RTT_MS}ms"
      ;;
  esac
}

net_tune_unit() {
  [[ -f "$XRAY_UNIT" ]] || return 0
  log "Xray LimitNOFILE=${XRAY_NOFILE}"
  [[ "$DRY_RUN" == "1" ]] && return 0
  if grep -q '^LimitNOFILE=' "$XRAY_UNIT"; then
    sed -i "s/^LimitNOFILE=.*/LimitNOFILE=${XRAY_NOFILE}/" "$XRAY_UNIT"
  else
    sed -i "/^\[Service\]/a LimitNOFILE=${XRAY_NOFILE}" "$XRAY_UNIT"
  fi
  systemctl daemon-reload
  if [[ "$RESTART_XRAY" == "1" ]] && systemctl is-active --quiet xray 2>/dev/null; then
    systemctl restart xray || true
  fi
}

optimize_net() {
  [[ "$ROLE" == "entry" || "$ROLE" == "exit" ]] || die "网络优化需要 --role entry|exit"
  command -v sysctl >/dev/null 2>&1 || die "缺少 sysctl"
  UPLINK_SET="$UPLINK_MBIT"
  RTT_SET="$RTT_MS"
  net_plan
  net_backup
  net_apply_sysctl
  net_apply_qdisc
  net_tune_unit
  log "网络优化完成"
}

net_status() {
  [[ "$ROLE" == "entry" || "$ROLE" == "exit" ]] || return 0
  UPLINK_SET="$UPLINK_MBIT"
  RTT_SET="$RTT_MS"
  net_plan || true
  echo "=== 当前内核 ==="
  sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control \
    net.ipv4.tcp_slow_start_after_idle net.core.somaxconn \
    net.ipv4.ip_local_port_range net.core.rmem_max 2>/dev/null || true
  echo
  tc qdisc show dev "$IFACE" 2>/dev/null || true
}

restore_net() {
  [[ "$ROLE" == "entry" || "$ROLE" == "exit" ]] || die "回滚需要 --role entry|exit"
  net_detect_iface
  [[ -f "${NET_STATE_DIR}/sysctl.before" ]] || die "没有网络优化备份"
  local line key val
  while IFS= read -r line; do
    [[ "$line" == IFACE=* ]] && { IFACE="${line#IFACE=}"; continue; }
    key="${line%%=*}"
    val="${line#*=}"
    [[ -n "$key" && -n "$val" ]] || continue
    net_run "sysctl -w ${key}='${val}'"
  done <"${NET_STATE_DIR}/sysctl.before"
  net_run "rm -f '${NET_SYSCTL_FILE}'"
  net_run "tc qdisc del dev '${IFACE}' root 2>/dev/null || true"
  rm -f "${NET_STATE_DIR}/sysctl.before"
  log "网络优化已回滚"
}

apply_optimize() {
  [[ "$NET_TUNE" == "1" ]] || { log "跳过网络优化 (--no-net-tune)"; return 0; }
  ROLE="$1"
  RESTART_XRAY=0
  if [[ "$ROLE" == "entry" && -z "$PEER_IP" ]]; then PEER_IP="${EXIT_IP:-}"; fi
  if [[ "$ROLE" == "exit" && -z "$PEER_IP" ]]; then PEER_IP="${ENTRY_IP:-}"; fi
  log "应用短连接网络优化 role=${ROLE}"
  optimize_net
}

restart_xray() {
  xray run -test -config "$XRAY_CONFIG" || die "配置校验失败"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
  systemctl is-active --quiet "$SERVICE_NAME" || die "xray 启动失败"
}

get_public_ip() {
  curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null \
    || curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null \
    || hostname -I | awk '{print $1}'
}

build_client_link() {
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
    "$ENTRY_UUID" "$1" "$PORT" "$ENTRY_REALITY_SNI" "$ENTRY_PUBLIC_KEY" "$ENTRY_SHORT_ID" "${2:-VLESS-Short}"
}

write_client_json() {
  local ip="$1"
  cat >"$CLIENT_JSON" <<EOF
{
  "log": { "loglevel": "warning" },
  $(policy_json),
  "inbounds": [{
    "listen": "127.0.0.1", "port": 10808, "protocol": "socks",
    "settings": { "udp": true }
  }],
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "${ip}", "port": ${PORT},
        "users": [{ "id": "${ENTRY_UUID}", "encryption": "none" }]
      }]
    },
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "serverName": "${ENTRY_REALITY_SNI}", "fingerprint": "chrome",
        "publicKey": "${ENTRY_PUBLIC_KEY}", "shortId": "${ENTRY_SHORT_ID}"
      },
      $(bearer_sockopt)
    },
    "mux": {
      "enabled": true,
      "concurrency": ${MUX_CONCURRENCY},
      "xudpConcurrency": ${XUDP_CONCURRENCY},
      "xudpProxyUDP443": "${XUDP_UDP443}"
    }
  }]
}
EOF
}

save_exit_files() {
  local ip
  ip="$(get_public_ip)"
  mkdir -p "$XRAY_DIR"
  cat >"$STATE_FILE" <<EOF
NODE_ROLE=exit
PROFILE=short
EXIT_IP=${ip}
EXIT_UUID=${EXIT_UUID}
EXIT_PUBLIC_KEY=${EXIT_PUBLIC_KEY}
EXIT_PRIVATE_KEY=${EXIT_PRIVATE_KEY}
EXIT_SHORT_ID=${EXIT_SHORT_ID}
EXIT_REALITY_DEST=${EXIT_REALITY_DEST}
EXIT_REALITY_SNI=${EXIT_REALITY_SNI}
ENTRY_IP=${ENTRY_IP}
MUX_CONCURRENCY=${MUX_CONCURRENCY}
GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
  cat >"$HANDOFF_FILE" <<EOF
NODE_ROLE=exit
PROFILE=short
EXIT_IP=${ip}
EXIT_UUID=${EXIT_UUID}
EXIT_PUBLIC_KEY=${EXIT_PUBLIC_KEY}
EXIT_SHORT_ID=${EXIT_SHORT_ID}
EXIT_REALITY_SNI=${EXIT_REALITY_SNI}
ENTRY_IP=${ENTRY_IP}
MUX_CONCURRENCY=${MUX_CONCURRENCY}
GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
  chmod 600 "$STATE_FILE" "$HANDOFF_FILE"
}

save_entry_files() {
  local ip link
  ip="$(get_public_ip)"
  link="$(build_client_link "$ip")"
  mkdir -p "$XRAY_DIR"
  write_client_json "$ip"
  chmod 600 "$CLIENT_JSON"
  cat >"$STATE_FILE" <<EOF
NODE_ROLE=entry
PROFILE=short
ENTRY_IP=${ip}
ENTRY_UUID=${ENTRY_UUID}
ENTRY_PUBLIC_KEY=${ENTRY_PUBLIC_KEY}
ENTRY_PRIVATE_KEY=${ENTRY_PRIVATE_KEY}
ENTRY_SHORT_ID=${ENTRY_SHORT_ID}
ENTRY_REALITY_DEST=${ENTRY_REALITY_DEST}
ENTRY_REALITY_SNI=${ENTRY_REALITY_SNI}
EXIT_IP=${EXIT_IP}
EXIT_UUID=${EXIT_UUID}
EXIT_PUBLIC_KEY=${EXIT_PUBLIC_KEY}
EXIT_SHORT_ID=${EXIT_SHORT_ID}
EXIT_REALITY_SNI=${EXIT_REALITY_SNI}
MUX_CONCURRENCY=${MUX_CONCURRENCY}
CLIENT_LINK=${link}
CLIENT_JSON=${CLIENT_JSON}
GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
  chmod 600 "$STATE_FILE"
}

show_client() {
  local ip link
  # shellcheck disable=SC1090
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
  ip="${ENTRY_IP:-$(get_public_ip)}"
  link="${CLIENT_LINK:-$(build_client_link "$ip")}"
  [[ -f "$CLIENT_JSON" ]] || write_client_json "$ip"
  echo
  echo "=== 客户端配置（Mux 已打开，这是短连接方案本身）==="
  echo "$CLIENT_JSON"
  echo
  echo "=== vless 链接（导入后仍需自行打开 Mux，concurrency=${MUX_CONCURRENCY}）==="
  echo "$link"
  echo
  command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$link" || true
  echo
  echo "推荐客户端: Xray / v2rayN / Nekoray / sing-box（对应 multiplex）"
}

show_status() {
  systemctl is-active --quiet xray 2>/dev/null && echo "xray: active" || echo "xray: inactive"
  local role=""
  if [[ -f "$STATE_FILE" ]]; then
    echo "--- ${STATE_FILE} ---"
    grep -v 'PRIVATE_KEY' "$STATE_FILE" || true
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    role="${NODE_ROLE:-}"
  fi
  if [[ -n "$role" ]]; then
    echo
    ROLE="$role"
    PEER_IP=""
    UPLINK_MBIT=""
    RTT_MS=""
    [[ "$role" == "entry" ]] && PEER_IP="${EXIT_IP:-}"
    [[ "$role" == "exit" ]] && PEER_IP="${ENTRY_IP:-}"
    net_status || true
  fi
}

install_exit() {
  prompt_if_empty ENTRY_IP "Entry VPS 公网 IP"
  validate_ip "$ENTRY_IP"
  install_deps; install_xray
  EXIT_UUID="$(gen_uuid)"; EXIT_SHORT_ID="$(gen_short_id)"
  read -r EXIT_PRIVATE_KEY EXIT_PUBLIC_KEY < <(parse_x25519)
  write_exit_config; setup_firewall_exit
  apply_optimize exit
  restart_xray
  save_exit_files
  cat <<EOF

=== Exit 安装完成（短连接）===
出口 IP: $(get_public_ip)
UUID: ${EXIT_UUID}
Reality 公钥: ${EXIT_PUBLIC_KEY}
shortId: ${EXIT_SHORT_ID}
SNI: ${EXIT_REALITY_SNI}
防火墙: ${PORT} ← ${ENTRY_IP} only

下一步 — 只复制 handoff（无私钥）到 Entry VPS:
  ${HANDOFF_FILE}

  sudo bash vless-short-chain.sh install-entry --cred-file ${HANDOFF_FILE}
EOF
}

install_entry() {
  [[ -n "$CRED_FILE" ]] && load_exit_credentials
  prompt_if_empty EXIT_IP "Exit VPS IP"
  prompt_if_empty EXIT_UUID "Exit UUID"
  prompt_if_empty EXIT_PUBLIC_KEY "Exit Reality 公钥"
  prompt_if_empty EXIT_SHORT_ID "Exit Reality shortId"
  install_deps; install_xray
  ENTRY_UUID="$(gen_uuid)"; ENTRY_SHORT_ID="$(gen_short_id)"
  read -r ENTRY_PRIVATE_KEY ENTRY_PUBLIC_KEY < <(parse_x25519)
  write_entry_config; setup_firewall_entry
  apply_optimize entry
  restart_xray
  save_entry_files
  show_client
  echo "=== Entry 安装完成（短连接）=== 日志: journalctl -u xray -f"
}

assert_json() {
  local file="$1"
  python3 - "$file" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    json.load(f)
PY
}

run_self_test() {
  local tmp
  tmp="$(mktemp -d)"
  XRAY_DIR="$tmp"
  XRAY_CONFIG="${tmp}/config.json"
  STATE_FILE="${tmp}/chain-credentials.env"
  HANDOFF_FILE="${tmp}/chain-handoff.env"
  CLIENT_JSON="${tmp}/short-client.json"
  LOG_DIR="$tmp"
  get_public_ip() { echo "203.0.113.10"; }

  EXIT_UUID="11111111-1111-1111-1111-111111111111"
  EXIT_PRIVATE_KEY="exit-priv"
  EXIT_PUBLIC_KEY="exit-pub"
  EXIT_SHORT_ID="aabbccdd"
  ENTRY_IP="203.0.113.20"
  write_exit_config
  assert_json "$XRAY_CONFIG"
  python3 - "$XRAY_CONFIG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
inbound = cfg["inbounds"][0]
assert "flow" not in inbound["settings"]["clients"][0]
assert "xtls-rprx-vision" not in json.dumps(cfg)
ids = inbound["streamSettings"]["realitySettings"]["shortIds"]
assert ids == ["aabbccdd"], ids
assert "sniffing" not in inbound
assert cfg["outbounds"][0]["streamSettings"]["sockopt"]["tcpFastOpen"] is True
assert inbound["streamSettings"]["sockopt"]["tcpKeepAliveIdle"] == 45
assert cfg["policy"]["levels"]["0"]["bufferSize"] == 8
PY

  save_exit_files
  grep -q 'EXIT_PRIVATE_KEY=exit-priv' "$STATE_FILE"
  if grep -q 'PRIVATE_KEY' "$HANDOFF_FILE"; then
    die "handoff 含私钥"
  fi
  grep -q 'EXIT_PUBLIC_KEY=exit-pub' "$HANDOFF_FILE"

  EXIT_IP="203.0.113.30"
  ENTRY_UUID="22222222-2222-2222-2222-222222222222"
  ENTRY_PRIVATE_KEY="entry-priv"
  ENTRY_PUBLIC_KEY="entry-pub"
  ENTRY_SHORT_ID="11223344"
  write_entry_config
  assert_json "$XRAY_CONFIG"
  python3 - "$XRAY_CONFIG" "$MUX_CONCURRENCY" "$XUDP_CONCURRENCY" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
inbound = cfg["inbounds"][0]
assert "flow" not in inbound["settings"]["clients"][0]
assert inbound["streamSettings"]["realitySettings"]["shortIds"] == ["11223344"]
ob = cfg["outbounds"][0]
user = ob["settings"]["vnext"][0]["users"][0]
assert "flow" not in user
mux = ob["mux"]
assert mux["enabled"] is True
assert mux["concurrency"] == int(sys.argv[2])
assert mux["xudpConcurrency"] == int(sys.argv[3])
assert mux["xudpProxyUDP443"] == "reject"
assert "xtls-rprx-vision" not in json.dumps(cfg)
assert "sniffing" not in json.dumps(cfg)
assert cfg["policy"]["levels"]["0"]["bufferSize"] == 8
PY

  write_client_json "203.0.113.20"
  assert_json "$CLIENT_JSON"
  python3 - "$CLIENT_JSON" "$MUX_CONCURRENCY" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
user = cfg["outbounds"][0]["settings"]["vnext"][0]["users"][0]
assert "flow" not in user
mux = cfg["outbounds"][0]["mux"]
assert mux["enabled"] is True and mux["concurrency"] == int(sys.argv[2])
assert cfg["inbounds"][0]["settings"]["udp"] is True
assert cfg["policy"]["levels"]["0"]["bufferSize"] == 8
PY

  CRED_FILE="$HANDOFF_FILE"
  load_exit_credentials
  [[ "$EXIT_PUBLIC_KEY" == "exit-pub" ]] || die "handoff 公钥未读出"

  local bad="${tmp}/bad.env"
  echo 'EXIT_PRIVATE_KEY=secret' >"$bad"
  echo 'EXIT_IP=203.0.113.30' >>"$bad"
  if (CRED_FILE="$bad" load_exit_credentials) >/dev/null 2>&1; then
    die "含私钥的 handoff 应被拒绝"
  fi

  ROLE=exit
  IFACE=lo
  UPLINK_MBIT=200
  RTT_MS=40
  UPLINK_SET=200
  RTT_SET=40
  PEER_IP=""
  PROBE_BANDWIDTH=0
  PROBE_RTT=0
  net_plan >/dev/null
  [[ "$APPLY_BDP" == "1" && "$APPLY_SHAPE" == "1" ]] || die "实测 B×T 应开启缓冲和整形"
  [[ "$SOCK_MAX" == "2000000" ]] || die "SOCK_MAX=${SOCK_MAX}"
  [[ "$SOCK_DEF" == "16384" ]] || die "短流默认缓冲应为 16384，实际 ${SOCK_DEF}"
  [[ "$SOMAXCONN" == "1024" && "$CT_MAX" == "262144" ]] || die "exit 连接表不符合角色"
  [[ "$SHAPED_MBIT" == "190" ]] || die "整形应为上行的 95%"

  UPLINK_MBIT=""
  RTT_MS=""
  UPLINK_SET=""
  RTT_SET=""
  net_plan >/dev/null
  [[ "$APPLY_BDP" == "0" && "$APPLY_SHAPE" == "0" ]] || die "未实测不应写 BDP"
  [[ "$SOMAXCONN" == "1024" ]] || die "未实测时 exit 监听队列被改掉"

  UPLINK_MBIT=200
  UPLINK_SET=200
  RTT_MS=""
  RTT_SET=""
  net_plan >/dev/null
  [[ "$APPLY_BDP" == "0" ]] || die "只有上行、没有时延时不应写缓冲"

  ROLE=entry
  UPLINK_MBIT=""
  UPLINK_SET=""
  net_plan >/dev/null
  [[ "$SOMAXCONN" == "4096" && "$CT_MAX" == "8192" && "$DEV_BACKLOG" == "4096" ]] || die "entry 连接表不符合角色"

  rm -rf "$tmp"
  log "self-test 通过"
}

ensure_role() {
  [[ -n "$ROLE" ]] && return 0
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    ROLE="${NODE_ROLE:-}"
  fi
  [[ -n "$ROLE" ]] || die "请指定 --role entry|exit，或先完成节点安装"
}

main() {
  local argv=("$@")
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" || "$1" == "help" ]]; then
    usage
    exit 0
  fi
  case "$1" in
    install-exit) argv=(--mode exit "${@:2}") ;;
    install-entry) argv=(--mode entry "${@:2}") ;;
    net-stack|optimize) argv=(--mode optimize "${@:2}") ;;
    status) argv=(--mode status "${@:2}") ;;
    client) argv=(--mode client "${@:2}") ;;
    restore-net) argv=(--mode restore-net "${@:2}") ;;
    net-status) argv=(--mode net-status "${@:2}") ;;
    self-test) argv=(--mode self-test "${@:2}") ;;
  esac
  parse_args "${argv[@]}"
  case "$MODE" in
    self-test)
      run_self_test
      return
      ;;
    optimize|net-status|restore-net)
      ensure_role
      ;;
  esac
  if [[ "$MODE" == "optimize" && "$DRY_RUN" == "1" ]]; then
    optimize_net
    return
  fi
  require_root
  case "$MODE" in
    exit) install_exit ;;
    entry) install_entry ;;
    status) show_status ;;
    optimize) optimize_net ;;
    net-status) net_status ;;
    restore-net) restore_net ;;
    client)
      # shellcheck disable=SC1090
      [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
      [[ -n "${ENTRY_UUID:-}" ]] || die "请先安装 entry"
      show_client ;;
    *) die "未知 mode: $MODE" ;;
  esac
}

main "$@"
