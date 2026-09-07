#!/usr/bin/env bash
# VLESS 低连接双跳方案 — 统一入口
#
# 架构（从基本元素推导）:
#   Client → Entry[VLESS+Reality] → Exit[VLESS+Reality] → Internet
#   网络栈: B(带宽) × T(RTT) × R(角色) → BDP 缓冲 + BBR/fq + 条件 tc 整形
#
# 子脚本:
#   vless-reality-chain-install.sh  — 链路安装
#   vless-chain-net-stack.sh        — 网络栈杠杆
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/vless-reality-chain-install.sh"
NET_SH="${SCRIPT_DIR}/vless-chain-net-stack.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  install-exit    安装 Exit 节点（第一步，在出口 VPS 执行）
  install-entry   安装 Entry 节点（第二步，在入口 VPS 执行）
  net-stack       单独应用/刷新网络栈优化
  status          查看 xray + 凭据 + 网络栈状态
  client          输出客户端 VLESS 链接与二维码
  restore-net     回滚网络栈至 apply 前状态

快速部署:
  # 1. Exit VPS
  sudo bash $(basename "$0") install-exit --entry-ip <Entry公网IP>

  # 2. 复制 /usr/local/etc/xray/chain-credentials.env 到 Entry VPS

  # 3. Entry VPS
  sudo bash $(basename "$0") install-entry --cred-file ./chain-credentials.env

说明:
  - 无需提供带宽/RTT，网络栈全自动探测
  - 跳过网络栈: install-exit/install-entry 加 --no-net-tune
  - 详细参数: bash $(basename "$0") install-exit --help

EOF
}

die() { echo "[vless-chain] ERROR: $*" >&2; exit 1; }

require_scripts() {
  [[ -x "$INSTALL_SH" || -f "$INSTALL_SH" ]] || die "缺少 ${INSTALL_SH}"
  [[ -x "$NET_SH" || -f "$NET_SH" ]] || die "缺少 ${NET_SH}"
}

main() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { usage; exit 0; }

  case "$cmd" in
    install-exit)
      shift
      require_scripts
      bash "$INSTALL_SH" --mode exit "$@"
      ;;
    install-entry)
      shift
      require_scripts
      bash "$INSTALL_SH" --mode entry "$@"
      ;;
    net-stack)
      shift
      require_scripts
      local role="" args=()
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --role) role="$2"; shift 2 ;;
          *) args+=("$1"); shift ;;
        esac
      done
      if [[ -z "$role" ]]; then
        local cred="/usr/local/etc/xray/chain-credentials.env"
        if [[ -f "$cred" ]]; then
          # shellcheck disable=SC1090
          source "$cred"
          role="${NODE_ROLE:-}"
        fi
      fi
      [[ -n "$role" ]] || die "请指定 --role entry|exit，或先完成节点安装"
      bash "$NET_SH" --role "$role" --mode apply "${args[@]}"
      ;;
    status)
      shift
      require_scripts
      bash "$INSTALL_SH" --mode status "$@"
      ;;
    client)
      shift
      require_scripts
      bash "$INSTALL_SH" --mode client "$@"
      ;;
    restore-net)
      shift
      require_scripts
      local role="exit"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --role) role="$2"; shift 2 ;;
          *) die "未知参数: $1" ;;
        esac
      done
      bash "$NET_SH" --role "$role" --mode restore
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      die "未知命令: ${cmd}（运行 $(basename "$0") --help 查看）"
      ;;
  esac
}

main "$@"
