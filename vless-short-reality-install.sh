#!/usr/bin/env bash
# VLESS + Reality 短连接双跳
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

usage() {
  cat <<EOF
Usage: $(basename "$0") --mode <mode> [options]

短连接双跳: Client → Entry(VLESS+Reality+Mux) → Exit(VLESS+Reality+Mux) → Internet

Modes:
  exit       安装 Exit（第一步）
  entry      安装 Entry（第二步）
  status     xray + 凭据 + 网络栈
  client     输出客户端 JSON 与链接
  self-test  校验配置生成（不需要 root）

Exit:
  --entry-ip IP             Entry 公网 IP（防火墙白名单，必填）
  --reality-dest HOST:PORT  默认 ${EXIT_REALITY_DEST}
  --reality-sni NAME        默认 ${EXIT_REALITY_SNI}

Entry:
  --cred-file PATH          Exit 的 chain-handoff.env（推荐）
  --exit-ip / --exit-uuid / --exit-public-key / --exit-short-id
  --exit-reality-sni NAME
  --reality-dest HOST:PORT  默认 ${ENTRY_REALITY_DEST}
  --reality-sni NAME        默认 ${ENTRY_REALITY_SNI}

Common:
  --no-net-tune
  --uplink-mbit N           已测出口速率，才会写 BDP 缓冲并整形
  --rtt-ms N                覆盖对端承载时延
  --noninteractive
  -h, --help
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
      --noninteractive) NONINTERACTIVE="1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [[ -n "$MODE" ]] || die "必须 --mode exit|entry|status|client|self-test"
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

write_exit_config() {
  mkdir -p "$XRAY_DIR" "$LOG_DIR"
  cat >"$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning", "access": "${LOG_DIR}/access.log", "error": "${LOG_DIR}/error.log" },
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

apply_net_stack() {
  local role="$1" script="${SCRIPT_DIR}/vless-chain-net-stack.sh" args=(--profile short --role "$role" --mode apply)
  [[ "$NET_TUNE" == "1" ]] || { log "跳过网络栈 (--no-net-tune)"; return 0; }
  [[ -f "$script" ]] || { log "缺少 ${script}"; return 0; }
  [[ -n "$UPLINK_MBIT" ]] && args+=(--uplink-mbit "$UPLINK_MBIT")
  [[ -n "$RTT_MS" ]] && args+=(--rtt-ms "$RTT_MS")
  [[ "$role" == "entry" && -n "$EXIT_IP" ]] && args+=(--peer-ip "$EXIT_IP")
  [[ "$role" == "exit" && -n "$ENTRY_IP" ]] && args+=(--peer-ip "$ENTRY_IP")
  log "应用短连接网络栈 role=${role} ..."
  bash "$script" "${args[@]}"
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
  local ns="${SCRIPT_DIR}/vless-chain-net-stack.sh"
  if [[ -f "$ns" && -n "$role" ]]; then
    echo
    local a=(--profile short --role "$role" --mode status)
    [[ "$role" == "entry" && -n "${EXIT_IP:-}" ]] && a+=(--peer-ip "$EXIT_IP")
    [[ "$role" == "exit" && -n "${ENTRY_IP:-}" ]] && a+=(--peer-ip "$ENTRY_IP")
    bash "$ns" "${a[@]}" 2>/dev/null || true
  fi
}

install_exit() {
  prompt_if_empty ENTRY_IP "Entry VPS 公网 IP"
  validate_ip "$ENTRY_IP"
  install_deps; install_xray
  EXIT_UUID="$(gen_uuid)"; EXIT_SHORT_ID="$(gen_short_id)"
  read -r EXIT_PRIVATE_KEY EXIT_PUBLIC_KEY < <(parse_x25519)
  write_exit_config; setup_firewall_exit
  restart_xray
  apply_net_stack exit
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
  restart_xray
  apply_net_stack entry
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

  rm -rf "$tmp"
  log "self-test 通过"
}

main() {
  parse_args "$@"
  if [[ "$MODE" == "self-test" ]]; then
    run_self_test
    return
  fi
  require_root
  case "$MODE" in
    exit) install_exit ;;
    entry) install_entry ;;
    status) show_status ;;
    client)
      # shellcheck disable=SC1090
      [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
      [[ -n "${ENTRY_UUID:-}" ]] || die "请先安装 entry"
      show_client ;;
    *) die "未知 mode: $MODE" ;;
  esac
}

main "$@"
