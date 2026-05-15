#!/bin/bash
# 激进网络性能优化脚本 - 自动检测 + BBR + 大缓冲区 + 收敛优化
# 警告：激进调优可能增加CPU和内存压力，生产环境请谨慎

set -e

echo "=== 网络激进优化脚本启动 ==="
echo "当前时间: $(date)"
echo ""

# 1. 自动检测系统信息
echo "[1/6] 检测系统信息..."
KERNEL_VERSION=$(uname -r | cut -d. -f1,2)
VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "unknown")
MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))

echo "  内核版本: $KERNEL_VERSION"
echo "  虚拟化类型: $VIRT_TYPE"
echo "  总内存: ${MEM_TOTAL_MB}MB"

# 安全检查
if [ "$VIRT_TYPE" = "openvz" ]; then
    echo "警告: 检测到 OpenVZ，激进调优可能无效或不稳定，建议退出。"
    read -p "是否继续? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消。"
        exit 0
    fi
fi

if [ "$MEM_TOTAL_MB" -lt 512 ]; then
    echo "警告: 内存小于512MB，激进缓冲区可能有风险。"
fi

# 2. 备份当前配置
echo ""
echo "[2/6] 备份当前sysctl配置..."
BACKUP_FILE="/etc/sysctl.d/99-aggressive-net-backup-$(date +%F_%H%M%S).conf"
sysctl -a | grep -E 'net\.(ipv4|core|ipv6)' > "$BACKUP_FILE" 2>/dev/null || true
echo "  备份已保存到: $BACKUP_FILE"

# 3. 准备激进配置
echo ""
echo "[3/6] 生成激进网络配置..."

CONF_FILE="/etc/sysctl.d/99-aggressive-network.conf"

cat > "$CONF_FILE" << 'EOF'
# === 激进网络性能 + BBR收敛优化 ===
# 由脚本自动生成 - 请谨慎使用

# BBR + fq (核心)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 大缓冲区 (提升高延迟线路吞吐和收敛空间)
net.core.rmem_max = 268435456
net.core.wmem_max = 268435456
net.ipv4.tcp_rmem = 4096 87380 268435456
net.ipv4.tcp_wmem = 4096 65536 268435456

# 连接队列与 backlog (提升并发和收敛能力)
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 65536
net.core.somaxconn = 65535

# TCP Fast Open + ECN (加速连接建立和探测)
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_ecn = 1

# 其他激进优化
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# 提升初始拥塞窗口 (帮助快速收敛)
net.ipv4.tcp_initial_cwnd = 20

# 内存相关
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF

echo "  配置已写入: $CONF_FILE"

# 4. 应用配置
echo ""
echo "[4/6] 应用配置..."
sysctl -p "$CONF_FILE"

# 5. 验证
echo ""
echo "[5/6] 验证关键参数..."
echo "  当前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "  当前qdisc: $(sysctl -n net.core.default_qdisc)"
echo "  rmem_max: $(sysctl -n net.core.rmem_max)"

# 6. 完成
echo ""
echo "[6/6] 完成！"
echo "激进网络优化已应用。"
echo "备份文件: $BACKUP_FILE"
echo ""
echo "建议：重启后测试速度，并观察CPU和内存使用情况。"
echo "如需回滚，执行: sysctl -p $BACKUP_FILE"