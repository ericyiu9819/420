#!/bin/bash
# 02-wg-install.sh
# 用途：一键安装 WireGuard（基于成熟 hwdsl2 脚本，精简版）
# 已在 01 脚本优化后运行效果最佳

set -e

echo -e "\033[36m========================================\033[0m"
echo -e "\033[36m   WireGuard 一键安装脚本（优化后版本）\033[0m"
echo -e "\033[36m========================================\033[0m"

[ "$(id -u)" -ne 0 ] && { echo "请用 sudo 运行"; exit 1; }

wget -qO /tmp/wg-install.sh https://raw.githubusercontent.com/hwdsl2/wireguard-install/master/wireguard-install.sh
chmod +x /tmp/wg-install.sh

echo "即将以 --auto 模式安装 WireGuard..."
/tmp/wg-install.sh --auto

echo -e "\033[32m✅ WireGuard 安装完成！\033[0m"
echo "下一步请运行： sudo bash 03-wg-tls.sh"