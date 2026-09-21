#!/usr/bin/env bash
# VLESS 短连接双跳 — 统一入口
#
# 成本在握手，不在稳态带宽:
#   内层短流 multiplex 到少量 VLESS+Reality 外层承载
#   不使用 xtls-rprx-vision（Vision 拒绝 TCP Mux）
#
# 子脚本:
#   vless-short-reality-install.sh  — 链路安装，网络优化也在这个脚本里
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/vless-short-reality-install.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

短连接双跳: Client → Entry(VLESS+Reality+Mux) → Exit(VLESS+Reality+Mux) → Internet

Commands:
  install-exit    安装 Exit（第一步，出口 VPS）
  install-entry   安装 Entry（第二步，入口 VPS）
  net-stack       应用短连接网络优化（承载 pacing、连接表、条件 BDP）
  status          查看 xray + 凭据 + 网络栈
  client          输出客户端 JSON（含 Mux）与链接
  restore-net     回滚网络栈
  self-test       本地校验生成的配置（不改系统）

快速部署:
  # 1. Exit VPS
  sudo bash $(basename "$0") install-exit --entry-ip <Entry公网IP>

  # 2. 复制 /usr/local/etc/xray/chain-handoff.env 到 Entry VPS
  #    这个文件没有私钥

  # 3. Entry VPS
  sudo bash $(basename "$0") install-entry --cred-file ./chain-handoff.env

说明:
  - 安装时会做网络优化：bbrplus/bbr + 出口 fq，Entry/Exit 连接表按角色设置，
    Xray 每连接缓冲 8KB。给出 --uplink-mbit 且测到对端时延后，才写 BDP 并整形
  - 客户端必须打开 Mux。只导入 vless:// 链接不会启用 Mux
  - 跳过网络优化: install-exit/install-entry 加 --no-net-tune

EOF
}

die() { echo "[vless-short] ERROR: $*" >&2; exit 1; }

require_scripts() {
  [[ -f "$INSTALL_SH" ]] || die "缺少 ${INSTALL_SH}"
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
      bash "$INSTALL_SH" --mode optimize --role "$role" "${args[@]}"
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
      bash "$INSTALL_SH" --mode restore-net --role "$role"
      ;;
    self-test)
      require_scripts
      bash "$INSTALL_SH" --mode self-test
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
