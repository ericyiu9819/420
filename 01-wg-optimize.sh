#!/bin/bash
# 01-wg-optimize.sh
# 用途：检测服务器参数并应用最优内核网络优化（BBR + fq + 缓冲区）
# 必须在安装 WireGuard 之前运行！

set -e

echo -e "\033[36m========================================\033[0m"
echo -e "\033[36m   WireGuard 系统级参数优化脚本\033[0m"
echo -e "\033[36m========================================\033[0m"

[ "$(id -u)" -ne 0 ] && { echo "请用 sudo 运行"; exit 1; }

echo "正在检测服务器参数..."
CPU=$(nproc)
MEM_MB=$(free -m | awk 'NR==2{print $2}')
IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5}' | head -1)

echo "  CPU 核心数: ${CPU}"
echo "  内存大小 : ${MEM_MB}MB"
echo "  主网卡   : ${IFACE}"

cat > /etc/sysctl.d/99-wg-optimize.conf << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.netdev_max_backlog = $((CPU * 8192))
net.ipv4.tcp_max_syn_backlog = $((CPU * 8192))
net.ipv4.tcp_rmem = 4096 87380 $((MEM_MB * 1024))
net.ipv4.tcp_wmem = 4096 87380 $((MEM_MB * 1024))
net.core.somaxconn = 65535
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system >/dev/null
echo -e "\033[32m✅ 系统优化完成！（BBR + fq 已启用）\033[0m"
echo "建议重启后继续安装 WireGuard（可选，但推荐）"