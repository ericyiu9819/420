#!/bin/bash
# deploy.sh - WireGuard 一键部署脚本（极致稳定版 v1.0）
# 自动按顺序执行 01 → 02 → 03

set -e

echo -e "\033[36m========================================\033[0m"
echo -e "\033[36m   WireGuard 一键部署脚本（极致稳定版）\033[0m"
echo -e "\033[36m========================================\033[0m"
echo ""

[ "$(id -u)" -ne 0 ] && { echo -e "\033[31m请用 sudo 运行此脚本\033[0m"; exit 1; }

echo -e "\033[33m即将按以下顺序执行：\033[0m"
echo "  1. 01-wg-optimize.sh  （系统极致稳定优化）"
echo "  2. 02-wg-install.sh   （安装 WireGuard）"
echo "  3. 03-wg-tls.sh       （TLS 伪装 + 443 端口）"
echo ""

read -rp "确认开始部署？(y/N): " confirm
[[ ! "$confirm" =~ ^[Yy]$ ]] && { echo -e "\033[33m已取消\033[0m"; exit 0; }

echo ""
echo -e "\033[36m[1/3] 执行系统优化...\033[0m"
sudo bash 01-wg-optimize.sh

echo ""
echo -e "\033[36m[2/3] 安装 WireGuard...\033[0m"
sudo bash 02-wg-install.sh

echo ""
echo -e "\033[36m[3/3] 配置 TLS 伪装...\033[0m"
sudo bash 03-wg-tls.sh

echo ""
echo -e "\033[32m========================================\033[0m"
echo -e "\033[32mἸ9 部署完成！\033[0m"
echo -e "\033[32m========================================\033[0m"
echo ""
echo -e "\033[33m提示：\033[0m"
echo "  • 浏览器访问你的域名应该显示假网站"
echo "  • 客户端 Endpoint 改为你的域名:443"
echo "  • 如需恢复原端口，编辑 /etc/wireguard/wg0.conf 把 443 改回原值"
echo ""