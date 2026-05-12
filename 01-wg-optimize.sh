#!/bin/bash
# 01-wg-optimize.sh（极致稳定版 v3.0）
# 用途：以【极致稳定 + 不断流】为核心，速度损失控制在 10% 以内
# 必须在安装 WireGuard 之前运行！

set -e

echo -e "\033[36m========================================\033[0m"
echo -e "\033[36m   WireGuard 极致稳定优化脚本（v3.0）\033[0m"
echo -e "\033[36m========================================\033[0m"

[ "$(id -u)" -ne 0 ] && { echo "请用 sudo 运行"; exit 1; }

echo "正在检测服务器参数..."
CPU=$(nproc)
MEM_MB=$(free -m | awk 'NR==2{print $2}')
IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5}' | head -1)

echo "  CPU 核心数 : ${CPU}"
echo "  内存大小   : ${MEM_MB}MB"
echo "  主网卡     : ${IFACE}"

# ==================== 极致稳定 + 保速 参数 ====================
cat > /etc/sysctl.d/99-wg-optimize.conf << EOF
# ========== 队列与拥塞控制（稳定核心） ==========
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ========== 保守但不激进的 backlog（平衡稳定与性能） ==========
net.core.netdev_max_backlog = $((CPU * 6144))
net.ipv4.tcp_max_syn_backlog = $((CPU * 6144))

# ========== 适度缓冲区（比原版稍大，保证速度） ==========
net.ipv4.tcp_rmem = 4096 87380 $((MEM_MB * 768))
net.ipv4.tcp_wmem = 4096 87380 $((MEM_MB * 768))

# ========== 全局上限（防止极端情况） ==========
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728

# ========== 连接与快速打开 ==========
net.core.somaxconn = 65535
net.ipv4.tcp_fastopen = 3

# ========== MTU 相关（WireGuard 专用优化） ==========
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1280          # 比原版 1024 更适合 WireGuard

# ========== 稳定性增强参数（新增） ==========
net.ipv4.tcp_tw_reuse = 1             # 快速回收 TIME_WAIT，提升稳定性
net.ipv4.tcp_fin_timeout = 15         # 更快关闭无效连接
net.ipv4.tcp_slow_start_after_idle = 0 # 空闲后不降速
net.ipv4.tcp_notsent_lowat = 16384    # 减少发送缓冲区堆积，降低延迟

# ========== 转发与 keepalive ==========
net.ipv4.ip_forward = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
EOF

sysctl --system >/dev/null

echo -e "\033[32m✅ 极致稳定优化完成！\033[0m"
echo ""
echo "核心改进："
echo "  • backlog 提升到 CPU×6144（比原版更激进但仍安全）"
echo "  • 缓冲区提升到 MEM×768（速度损失极小）"
echo "  • 新增 tcp_tw_reuse + notsent_lowat（显著降低断流）"
echo "  • MTU base_mss 调整为 1280（更适合 WireGuard）"
echo ""
echo "下一步请运行："
echo "  sudo bash 02-wg-install.sh"