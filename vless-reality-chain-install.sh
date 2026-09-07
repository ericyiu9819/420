#!/usr/bin/env bash
# VLESS + Reality 低冗余双跳链式安装（Entry → Exit）
# 主方案：VLESS + Reality + TCP + xtls-rprx-vision
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
TCP_TUNE="0"
UPLINK_MBIT=""
RTT_MS="80"
NONINTERACTIVE="0"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") --mode exit|entry [options]

低冗余双跳：客户端 → Entry(VLESS+Reality) → Exit(VLESS+Reality) → Internet

部署顺序：
  1. 在出口 VPS 上：$(basename "$0") --mode exit
  2. 在入口 VPS 上：$(basename "$0") --mode entry --cred-file /path/to/exit-credentials.env

Modes:
  exit    安装出口节点（仅允许 Entry IP 访问 443）
  entry   安装入口节点（转发到 Exit，并输出客户端链接）
  status  查看 xray 服务与已保存凭据
  client  根据已保存凭据重新输出客户端链接

Exit options:
  --entry-ip IP              入口 VPS 公网 IP（用于防火墙白名单）
  --reality-dest HOST:PORT   Exit 侧 Reality 伪装目标，默认 ${EXIT_REALITY_DEST}
  --reality-sni NAME         Exit 侧 SNI，默认 ${EXIT_REALITY_SNI}

Entry options:
  --exit-ip IP               出口 VPS IP
  --exit-uuid UUID           出口 VLESS UUID
  --exit-public-key KEY      出口 Reality 公钥
  --exit-short-id ID         出口 Reality shortId
  --exit-reality-sni NAME    出口 Reality SNI
  --cred-file PATH           从 Exit 安装生成的凭据文件读取
  --reality-dest HOST:PORT   Entry 侧 Reality 伪装目标，默认 ${ENTRY_REALITY_DEST}
  --reality-sni NAME         Entry 侧 SNI，默认 ${ENTRY_REALITY_SNI}

Common options:
  --tcp-tune                 安装后调用 vps-tcp-accelerator.sh
  --uplink-mbit N            TCP 调优上行带宽（Mbit/s）
  --rtt-ms N                 TCP 调优基线 RTT，默认 80
  --noninteractive           非交互模式（需补全必填参数）
  -h, --help                 显示帮助

示例：
  sudo bash $(basename "$0") --mode exit --entry-ip 1.2.3.4
  sudo bash $(basename "$0") --mode entry --cred-file ./exit-credentials.env
EOF
}

log() { echo "[vless-chain] $*"; }
die() { echo "[vless-chain] ERROR: $*" >&2; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 运行：sudo bash $0 ..."
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
        if [[ "$MODE" == "exit" ]]; then
          EXIT_REALITY_DEST="$2"
        else
          ENTRY_REALITY_DEST="$2"
        fi
        shift 2
        ;;
      --reality-sni)
        if [[ "$MODE" == "exit" ]]; then
          EXIT_REALITY_SNI="$2"
        else
          ENTRY_REALITY_SNI="$2"
        fi
        shift 2
        ;;
      --tcp-tune) TCP_TUNE="1"; shift ;;
      --uplink-mbit) UPLINK_MBIT="$2"; shift 2 ;;
      --rtt-ms) RTT_MS="$2"; shift 2 ;;
      --noninteractive) NONINTERACTIVE="1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [[ -n "$MODE" ]] || die "必须指定 --mode exit|entry|status|client"
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
  if [[ "$OS" == *"debian"* || "$OS" == *"ubuntu"* ]]; then
    apt-get update -qq
    apt-get install -y curl qrencode ufw jq openssl ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl qrencode firewalld jq openssl ca-certificates || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl qrencode firewalld jq openssl ca-certificates || true
  else
    log "未能识别包管理器，请确保已安装 curl / jq / qrencode"
  fi
}

install_xray() {
  if command -v xray >/dev/null 2>&1 && [[ -x /usr/local/bin/xray ]]; then
    log "检测到已安装 Xray，跳过安装"
    return
  fi
  log "安装 Xray-core ..."
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
}

gen_uuid() {
  xray uuid | awk '{print $NF}'
}

parse_x25519() {
  local output priv pub
  output="$(xray x25519)"
  priv="$(echo "$output" | awk -F': ' '/Private/ {print $2}' | tr -d ' \r')"
  pub="$(echo "$output" | awk -F': ' '/Public/ {print $2}' | tr -d ' \r')"
  [[ -n "$priv" && -n "$pub" ]] || die "x25519 密钥生成失败"
  echo "$priv $pub"
}

gen_short_id() {
  openssl rand -hex 4
}

validate_ip() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "无效 IP: $ip"
}

prompt_if_empty() {
  local var_name="$1"
  local prompt_text="$2"
  local current
  current="$(eval "echo \${$var_name}")"
  if [[ -z "$current" && "$NONINTERACTIVE" != "1" ]]; then
    read -r -p "$prompt_text: " current
    eval "$var_name=\"\$current\""
  fi
  current="$(eval "echo \${$var_name}")"
  [[ -n "$current" ]] || die "缺少必填项: $var_name"
}

load_exit_credentials() {
  [[ -f "$CRED_FILE" ]] || die "凭据文件不存在: $CRED_FILE"
  # shellcheck disable=SC1090
  source "$CRED_FILE"
  EXIT_IP="${EXIT_IP:-}"
  EXIT_UUID="${EXIT_UUID:-}"
  EXIT_PUBLIC_KEY="${EXIT_PUBLIC_KEY:-}"
  EXIT_SHORT_ID="${EXIT_SHORT_ID:-}"
  EXIT_REALITY_SNI="${EXIT_REALITY_SNI:-$EXIT_REALITY_SNI}"
}

write_exit_config() {
  mkdir -p "$XRAY_DIR"
  cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-from-entry",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${EXIT_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${EXIT_REALITY_DEST}",
          "xver": 0,
          "serverNames": ["${EXIT_REALITY_SNI}"],
          "privateKey": "${EXIT_PRIVATE_KEY}",
          "shortIds": ["", "${EXIT_SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
}

write_entry_config() {
  mkdir -p "$XRAY_DIR"
  cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${ENTRY_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${ENTRY_REALITY_DEST}",
          "xver": 0,
          "serverNames": ["${ENTRY_REALITY_SNI}"],
          "privateKey": "${ENTRY_PRIVATE_KEY}",
          "shortIds": ["", "${ENTRY_SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "to-exit",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${EXIT_IP}",
            "port": ${PORT},
            "users": [
              {
                "id": "${EXIT_UUID}",
                "encryption": "none",
                "flow": "xtls-rprx-vision"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "serverName": "${EXIT_REALITY_SNI}",
          "fingerprint": "chrome",
          "publicKey": "${EXIT_PUBLIC_KEY}",
          "shortId": "${EXIT_SHORT_ID}",
          "spiderX": "/"
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "to-exit"
      }
    ]
  }
}
EOF
}

setup_firewall_exit() {
  validate_ip "$ENTRY_IP"
  if command -v ufw >/dev/null 2>&1; then
    ufw --force enable || true
    ufw allow OpenSSH || true
    ufw delete allow "${PORT}/tcp" 2>/dev/null || true
    ufw allow from "${ENTRY_IP}" to any port "${PORT}" proto tcp comment 'vless-chain-entry' || true
    ufw reload || true
    log "UFW 已限制 ${PORT}/tcp 仅允许 ${ENTRY_IP}"
  else
    log "未检测到 ufw，请手动限制 ${PORT}/tcp 仅允许 Entry IP: ${ENTRY_IP}"
  fi
}

setup_firewall_entry() {
  if command -v ufw >/dev/null 2>&1; then
    ufw --force enable || true
    ufw allow OpenSSH || true
    ufw allow "${PORT}/tcp" comment 'vless-chain-client' || true
    ufw reload || true
    log "UFW 已开放 ${PORT}/tcp 供客户端接入"
  fi
}

maybe_tcp_tune() {
  local tune_script="${SCRIPT_DIR}/vps-tcp-accelerator.sh"
  [[ "$TCP_TUNE" == "1" ]] || return 0
  [[ -f "$tune_script" ]] || { log "未找到 ${tune_script}，跳过 TCP 调优"; return 0; }
  prompt_if_empty UPLINK_MBIT "请输入真实上行带宽(Mbit/s)"
  log "应用 TCP 调优 uplink=${UPLINK_MBIT} rtt=${RTT_MS} ..."
  bash "$tune_script" --uplink-mbit "$UPLINK_MBIT" --rtt-ms "$RTT_MS" \
    --persist-sysctl /etc/sysctl.d/99-vless-chain-tcp.conf
}

restart_xray() {
  mkdir -p /var/log/xray
  if ! xray run -test -config "$XRAY_CONFIG"; then
    die "Xray 配置校验失败，请检查 ${XRAY_CONFIG}"
  fi
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
  systemctl is-active --quiet "$SERVICE_NAME" || die "xray 服务启动失败"
}

get_public_ip() {
  curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null \
    || curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null \
    || hostname -I | awk '{print $1}'
}

build_client_link() {
  local entry_ip="$1"
  local name="${2:-VLESS-Chain-Entry}"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
    "$ENTRY_UUID" "$entry_ip" "$PORT" "$ENTRY_REALITY_SNI" "$ENTRY_PUBLIC_KEY" "$ENTRY_SHORT_ID" "$name"
}

save_exit_credentials() {
  local exit_public_ip
  exit_public_ip="$(get_public_ip)"
  cat > "$CRED_FILE" <<EOF
# Exit node credentials — copy to Entry VPS for --mode entry
NODE_ROLE=exit
EXIT_IP=${exit_public_ip}
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
  local entry_public_ip link
  entry_public_ip="$(get_public_ip)"
  link="$(build_client_link "$entry_public_ip" "VLESS-Chain")"
  cat > "$CRED_FILE" <<EOF
# Entry node credentials + client link
NODE_ROLE=entry
ENTRY_IP=${entry_public_ip}
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
  local entry_ip link
  # shellcheck disable=SC1090
  [[ -f "$CRED_FILE" ]] && source "$CRED_FILE"
  entry_ip="${ENTRY_IP:-$(get_public_ip)}"
  link="${CLIENT_LINK:-$(build_client_link "$entry_ip")}"
  echo
  echo "=== 客户端 VLESS 链接 ==="
  echo "$link"
  echo
  if command -v qrencode >/dev/null 2>&1; then
    echo "=== 二维码 ==="
    qrencode -t ANSIUTF8 "$link"
  fi
  echo
  echo "客户端推荐：v2rayN / Nekoray / Clash Meta / Shadowrocket / sing-box"
}

install_exit() {
  prompt_if_empty ENTRY_IP "请输入 Entry VPS 公网 IP（用于防火墙白名单）"
  validate_ip "$ENTRY_IP"

  install_deps
  install_xray

  EXIT_UUID="$(gen_uuid)"
  EXIT_SHORT_ID="$(gen_short_id)"
  read -r EXIT_PRIVATE_KEY EXIT_PUBLIC_KEY < <(parse_x25519)

  write_exit_config
  setup_firewall_exit
  maybe_tcp_tune
  restart_xray
  save_exit_credentials

  echo
  echo "=== Exit 节点安装完成 ==="
  echo "出口 IP: $(get_public_ip)"
  echo "VLESS UUID: ${EXIT_UUID}"
  echo "Reality 公钥: ${EXIT_PUBLIC_KEY}"
  echo "Reality shortId: ${EXIT_SHORT_ID}"
  echo "Reality SNI: ${EXIT_REALITY_SNI}"
  echo "防火墙: 443 仅允许 ${ENTRY_IP}"
  echo
  echo "请将凭据文件复制到 Entry VPS："
  echo "  ${CRED_FILE}"
  echo
  echo "Entry 安装命令示例："
  echo "  sudo bash vless-reality-chain-install.sh --mode entry --cred-file ${CRED_FILE}"
}

install_entry() {
  if [[ -f "$CRED_FILE" ]]; then
    load_exit_credentials
  fi

  prompt_if_empty EXIT_IP "请输入 Exit VPS IP"
  prompt_if_empty EXIT_UUID "请输入 Exit VLESS UUID"
  prompt_if_empty EXIT_PUBLIC_KEY "请输入 Exit Reality 公钥"
  prompt_if_empty EXIT_SHORT_ID "请输入 Exit Reality shortId"
  [[ -n "$EXIT_REALITY_SNI" ]] || EXIT_REALITY_SNI="www.cloudflare.com"

  install_deps
  install_xray

  ENTRY_UUID="$(gen_uuid)"
  ENTRY_SHORT_ID="$(gen_short_id)"
  read -r ENTRY_PRIVATE_KEY ENTRY_PUBLIC_KEY < <(parse_x25519)

  write_entry_config
  setup_firewall_entry
  maybe_tcp_tune
  restart_xray
  save_entry_credentials
  show_client_link

  echo "=== Entry 节点安装完成 ==="
  echo "入口 IP: $(get_public_ip)"
  echo "转发目标: ${EXIT_IP}:${PORT}"
  echo "凭据已保存: ${CRED_FILE}"
  echo "日志: journalctl -u xray -f"
}

show_status() {
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "xray: active"
  else
    echo "xray: inactive"
  fi
  if [[ -f "$CRED_FILE" ]]; then
    echo "--- ${CRED_FILE} ---"
    grep -v 'PRIVATE_KEY' "$CRED_FILE" || true
  else
    echo "未找到凭据文件: ${CRED_FILE}"
  fi
}

main() {
  parse_args "$@"
  require_root

  case "$MODE" in
    exit) install_exit ;;
    entry) install_entry ;;
    status) show_status ;;
    client)
      # shellcheck disable=SC1090
      [[ -f "$CRED_FILE" ]] && source "$CRED_FILE"
      ENTRY_UUID="${ENTRY_UUID:-}"
      ENTRY_PUBLIC_KEY="${ENTRY_PUBLIC_KEY:-}"
      ENTRY_SHORT_ID="${ENTRY_SHORT_ID:-}"
      ENTRY_REALITY_SNI="${ENTRY_REALITY_SNI:-$ENTRY_REALITY_SNI}"
      [[ -n "$ENTRY_UUID" ]] || die "缺少 Entry 凭据，请先安装 entry 或指定 --cred-file"
      show_client_link
      ;;
    *) die "未知 mode: $MODE" ;;
  esac
}

main "$@"
