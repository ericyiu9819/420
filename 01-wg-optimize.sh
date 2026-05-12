#!/bin/bash
# 01-wg-optimize.sh (稳定优先版 v2)
# 用途：以【稳定不断流】为核心，速度为辅，优化 WireGuard 服务器
# 重点：保守缓冲区 + BBR + fq + MTU 友好设置
# 必须在安装 WireGuard 之前运行！

set -e

echo -e "\033[36m========================================\033[0m"
echo -e "\033[36m   WireGuard 系统级参数优化脚本（稳定优先版）\033[0m"
echo -e "\033[36m========================================\033[0m"

[ "$(id -u)" -ne 0 ] && { echo "请用 sudo 运行"; exit 1; }

echo "正在检测服务器参数..."
CPU=$(nproc)
MEM_MB=$(free -m | awk 'NR==2{print $2}')
IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5}' | head -1)

echo "  CPU 核心数: ${CPU}"
echo "  内存大小 : ${MEM_MB}MB"
echo "  主网卡   : ${IFACE}"

# 稳定优先的保守参数（减少断流风险）
# - 降低 backlog 和缓冲区乘数，避免网络栈过载
# - 保留 BBR + fq（兼顾稳定与性能）
# - 开启 MTU 探测（适应不同网络路径）

cat > /etc/sysctl.d/99-wg-optimize.conf << EOF
# 队列与拥塞控制（稳定核心）
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 保守 backlog（原 8192 太激进，易导致丢包断流）
net.core.netdev_max_backlog = $((CPU * 4096))
net.ipv4.tcp_max_syn_backlog = $((CPU * 4096))

# 适度缓冲区（避免大缓冲区在弱网下造成延迟和丢包）
net.ipv4.tcp_rmem = 4096 87380 $((MEM_MB * 512))
net.ipv4.tcp_wmem = 4096 87380 $((MEM_MB * 512))

# 全局最大缓冲区上限（防止极端情况）
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728

# 连接与快速打开
net.core.somaxconn = 32768
net.ipv4.tcp_fastopen = 3

# MTU 相关（关键！帮助适应不同网络，减少碎片断流）
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024

# 转发与 keepalive（辅助稳定）
net.ipv4.ip_forward = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
EOF

sysctl --system >/dev/null
echo -e "\033[32m✅ 稳定优先优化完成！（BBR + fq + 保守缓冲区）\033[0m"
echo "重点：降低丢包风险，适应弱网/移动网络，减少断流"
echo "建议重启后继续安装 WireGuard（可选，但推荐）"