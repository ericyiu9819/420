#!/usr/bin/env bash
# VLESS + Reality 低连接双跳安装（Entry → Exit）
# 协议: VLESS + Reality + TCP + xtls-rprx-vision
# 网络栈: 默认调用 vless-chain-net-stack.sh（可 --no-net-tune 跳过）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_DIR="/usr/local/etc/xray"
CRED_FILE="${XRAY_DIR}/chain-credentials.env"
SERVICE_NAME="xray"
PORT=443

MODE=""
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

低连接双跳: Client → Entry(VLESS+Reality) → Exit(VLESS+Reality) → Internet

Modes:
  exit       安装 Exit（第一步，出口 VPS）
  entry      安装 Entry（第二步，入口 VPS）
  net-stack  单独刷新网络栈（等同 --mode net-tune）
  net-tune   同上
  status     xray + 凭据 + 网络栈状态
  client     输出客户端链接/二维码

Exit:
  --entry-ip IP             Entry 公网 IP（防火墙白名单，必填）
  --reality-dest HOST:PORT  默认 ${EXIT_REALITY_DEST}
  --reality-sni NAME        默认 ${EXIT_REALITY_SNI}

Entry:
  --cred-file PATH          Exit 凭据文件（推荐）
  --exit-ip / --exit-uuid / --exit-public-key / --exit-short-id
  --exit-reality-sni NAME
  --reality-dest HOST:PORT  默认 ${ENTRY_REALITY_DEST}
  --reality-sni NAME        默认 ${ENTRY_REALITY_SNI}

Common:
  --no-net-tune             只装链路，不应用网络栈
  --uplink-mbit N           可选覆盖带宽探测
  --rtt-ms N                可选覆盖 RTT 探测
  --noninteractive
  -h, --help

部署示例:
  sudo bash vless-chain.sh install-exit --entry-ip 1.2.3.4
  sudo bash vless-chain.sh install-entry --cred-file ./chain-credentials.env
EOF
}

log() { echo "[chain-install] $*"; }
die() { echo "[chain-install] ERROR: $*" >&2; exit 1; }

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
  [[ -n "$MODE" ]] || die "必须 --mode exit|entry|net-stack|status|client"
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
}

write_exit_config() {
  mkdir -p "$XRAY_DIR" /var/log/xray
  cat >"$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log" },
  "inbounds": [{
    "tag": "vless-from-entry", "listen": "0.0.0.0", "port": ${PORT},
    "protocol": "vless",
    "settings": { "clients": [{ "id": "${EXIT_UUID}", "flow": "xtls-rprx-vision" }], "decryption": "none" },
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "show": false, "dest": "${EXIT_REALITY_DEST}", "xver": 0,
        "serverNames": ["${EXIT_REALITY_SNI}"],
        "privateKey": "${EXIT_PRIVATE_KEY}",
        "shortIds": ["", "${EXIT_SHORT_ID}"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
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
  mkdir -p "$XRAY_DIR" /var/log/xray
  cat >"$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log" },
  "inbounds": [{
    "tag": "vless-in", "listen": "0.0.0.0", "port": ${PORT},
    "protocol": "vless",
    "settings": { "clients": [{ "id": "${ENTRY_UUID}", "flow": "xtls-rprx-vision" }], "decryption": "none" },
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "show": false, "dest": "${ENTRY_REALITY_DEST}", "xver": 0,
        "serverNames": ["${ENTRY_REALITY_SNI}"],
        "privateKey": "${ENTRY_PRIVATE_KEY}",
        "shortIds": ["", "${ENTRY_SHORT_ID}"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [
    {
      "tag": "to-exit", "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "${EXIT_IP}", "port": ${PORT},
          "users": [{ "id": "${EXIT_UUID}", "encryption": "none", "flow": "xtls-rprx-vision" }]
        }]
      },
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": {
          "show": false, "serverName": "${EXIT_REALITY_SNI}",
          "fingerprint": "chrome", "publicKey": "${EXIT_PUBLIC_KEY}",
          "shortId": "${EXIT_SHORT_ID}", "spiderX": "/"
        }
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
    ufw allow from "${ENTRY_IP}" to any port "${PORT}" proto tcp comment 'vless-exit' || true
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
    ufw allow "${PORT}/tcp" comment 'vless-entry' || true
    ufw reload || true
    log "UFW: 开放 ${PORT}"
  fi
}

apply_net_stack() {
  local role="$1" script="${SCRIPT_DIR}/vless-chain-net-stack.sh" args=(--role "$role" --mode apply)
  [[ "$NET_TUNE" == "1" ]] || { log "跳过网络栈 (--no-net-tune)"; return 0; }
  [[ -f "$script" ]] || { log "缺少 ${script}"; return 0; }
  [[ -n "$UPLINK_MBIT" ]] && args+=(--uplink-mbit "$UPLINK_MBIT")
  [[ -n "$RTT_MS" ]] && args+=(--rtt-ms "$RTT_MS")
  [[ "$role" == "entry" && -n "$EXIT_IP" ]] && args+=(--peer-ip "$EXIT_IP")
  [[ "$role" == "exit" && -n "$ENTRY_IP" ]] && args+=(--peer-ip "$ENTRY_IP")
  log "应用网络栈 role=${role} ..."
  bash "$script" "${args[@]}"
}

run_net_stack_only() {
  local role="" cred="/usr/local/etc/xray/chain-credentials.env"
  [[ -f "$CRED_FILE" ]] && cred="$CRED_FILE"
  if [[ -f "$cred" ]]; then
    # shellcheck disable=SC1090
    source "$cred"
    role="${NODE_ROLE:-}"
  fi
  if [[ -z "$role" ]]; then
    [[ "$NONINTERACTIVE" == "1" ]] && die "需要 role，请先安装节点"
    read -r -p "节点角色 (entry/exit): " role
  fi
  NET_TUNE=1
  apply_net_stack "$role"
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
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
    "$ENTRY_UUID" "$1" "$PORT" "$ENTRY_REALITY_SNI" "$ENTRY_PUBLIC_KEY" "$ENTRY_SHORT_ID" "${2:-VLESS-Chain}"
}

save_exit_credentials() {
  cat >"$CRED_FILE" <<EOF
NODE_ROLE=exit
EXIT_IP=$(get_public_ip)
EXIT_UUID=${EXIT_UUID}
EXIT_PUBLIC_KEY=${EXIT_PUBLIC_KEY}
EXIT_PRIVATE_KEY=${EXIT_PRIVATE_KEY}
EXIT_SHORT_ID=${EXIT_SHORT_ID}
EXIT_REALITY_DEST=${EXIT_REALITY_DEST}
EXIT_REALITY_SNI=${EXIT_REALITY_SNI}
ENTRY_IP=${ENTRY_IP}
GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
  chmod 600 "$CRED_FILE"
}

save_entry_credentials() {
  local ip link
  ip="$(get_public_ip)"
  link="$(build_client_link "$ip")"
  cat >"$CRED_FILE" <<EOF
NODE_ROLE=entry
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
CLIENT_LINK=${link}
GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
  chmod 600 "$CRED_FILE"
}

show_client_link() {
  local ip link
  # shellcheck disable=SC1090
  [[ -f "$CRED_FILE" ]] && source "$CRED_FILE"
  ip="${ENTRY_IP:-$(get_public_ip)}"
  link="${CLIENT_LINK:-$(build_client_link "$ip")}"
  echo; echo "=== 客户端 VLESS 链接 ==="; echo "$link"; echo
  command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$link"
  echo; echo "推荐客户端: v2rayN / Nekoray / Clash Meta / Shadowrocket / sing-box"
}

show_status() {
  systemctl is-active --quiet xray 2>/dev/null && echo "xray: active" || echo "xray: inactive"
  if [[ -f "$CRED_FILE" ]]; then
    echo "--- ${CRED_FILE} ---"
    grep -v 'PRIVATE_KEY' "$CRED_FILE" || true
    # shellcheck disable=SC1090
    source "$CRED_FILE"
  fi
  local ns="${SCRIPT_DIR}/vless-chain-net-stack.sh" role="${NODE_ROLE:-}"
  if [[ -f "$ns" && -n "$role" ]]; then
    echo
    local a=(--role "$role" --mode status)
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
  save_exit_credentials
  cat <<EOF

=== Exit 安装完成 ===
出口 IP: $(get_public_ip)
UUID: ${EXIT_UUID}
Reality 公钥: ${EXIT_PUBLIC_KEY}
shortId: ${EXIT_SHORT_ID}
SNI: ${EXIT_REALITY_SNI}
防火墙: 443 ← ${ENTRY_IP} only

下一步 — 复制凭据到 Entry VPS:
  ${CRED_FILE}

  sudo bash vless-chain.sh install-entry --cred-file ${CRED_FILE}
EOF
}

install_entry() {
  [[ -f "$CRED_FILE" ]] && load_exit_credentials
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
  save_entry_credentials
  show_client_link
  echo "=== Entry 安装完成 === 日志: journalctl -u xray -f"
}

main() {
  parse_args "$@"
  require_root
  case "$MODE" in
    exit) install_exit ;;
    entry) install_entry ;;
    net-stack|net-tune) run_net_stack_only ;;
    status) show_status ;;
    client)
      # shellcheck disable=SC1090
      [[ -f "$CRED_FILE" ]] && source "$CRED_FILE"
      [[ -n "${ENTRY_UUID:-}" ]] || die "请先安装 entry"
      show_client_link ;;
    *) die "未知 mode: $MODE" ;;
  esac
}

main "$@"
