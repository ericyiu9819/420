#!/bin/bash
# ============================================================
# install.sh — WireGuard 一键部署脚本（自动按顺序执行 01+02+03）
# 用法： sudo bash install.sh
# ============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

clear
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   WireGuard 一键部署工具${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "此脚本将按以下顺序自动执行："
echo -e "  ${GREEN}1.${NC} 系统内核优化 (01-wg-optimize.sh)"
echo -e "  ${GREEN}2.${NC} WireGuard 安装 (02-wg-install.sh)"
echo -e "  ${GREEN}3.${NC} TLS 伪装 + 443 端口 (03-wg-tls.sh)"
echo ""
read -rp "是否继续？(y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "已取消"
    exit 0
fi

echo ""

echo -e "${YELLOW}[1/3] 正在执行系统优化...${NC}"
sudo bash 01-wg-optimize.sh || { echo -e "${RED}01 脚本执行失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 系统优化完成${NC}"
echo ""

read -rp "是否继续安装 WireGuard？(y/N): " confirm2
if [[ ! "$confirm2" =~ ^[Yy]$ ]]; then
    echo "已取消"
    exit 0
fi

echo -e "${YELLOW}[2/3] 正在安装 WireGuard...${NC}"
sudo bash 02-wg-install.sh || { echo -e "${RED}02 脚本执行失败${NC}"; exit 1; }
echo -e "${GREEN}✅ WireGuard 安装完成${NC}"
echo ""

read -rp "是否继续配置 TLS 伪装？(y/N): " confirm3
if [[ ! "$confirm3" =~ ^[Yy]$ ]]; then
    echo "已取消"
    exit 0
fi

echo -e "${YELLOW}[3/3] 正在配置 TLS 伪装...${NC}"
sudo bash 03-wg-tls.sh || { echo -e "${RED}03 脚本执行失败${NC}"; exit 1; }
echo -e "${GREEN}✅ TLS 伪装完成${NC}"
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}🎉 部署完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "下一步操作："
echo -e "  1. 浏览器访问 https://你的域名 验证伪装"
echo -e "  2. 使用客户端配置文件连接 (Endpoint 改为 域名:443)"
echo -e "  3. 添加新客户端： ${BLUE}sudo bash 02-wg-install.sh --addclient 名字${NC}"
echo ""
echo -e "${YELLOW}提示：如需重新安装，先执行： sudo bash 02-wg-install.sh --uninstall${NC}"