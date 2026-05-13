#!/bin/bash
# Trojan-Go + 自动TCP最优 一键安装（已验证优化版）
set -e

echo "=== Trojan-Go + 自动TCP优化 一键安装 ==="
read -p "请输入你的域名（已解析到本VPS）: " DOMAIN
read -p "请输入Trojan密码（推荐强密码）: " PASSWORD

[[ -z "$DOMAIN" || -z "$PASSWORD" ]] && { echo "域名和密码不能为空！"; exit 1; }

# 改进后的系统&内存检测
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
  [[ -z "$OS" && -n "$ID_LIKE" ]] && OS=$(echo "$ID_LIKE" | cut -d' ' -f1 | tr '[:upper:]' '[:lower:]')
else
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
fi

MEM=$(free -m 2>/dev/null | awk '/Mem:/{print $2}' || echo 1024)
echo "检测到系统: $OS，内存: ${MEM}MB"

# 依赖安装
if [[ "$OS" == *"debian"* || "$OS" == *"ubuntu"* ]]; then
  apt-get update && apt-get install -y curl unzip socat
elif [[ "$OS" == *"centos"* || "$OS" == *"rhel"* || "$OS" == *"rocky"* || "$OS" == *"fedora"* ]]; then
  yum install -y curl unzip socat || dnf install -y curl unzip socat
else
  echo "⚠️ 不支持的系统，请手动安装 curl unzip socat"
fi

# 1. 下载最新版
VERSION=$(curl -s https://api.github.com/repos/p4gefau1t/trojan-go/releases/latest | grep '"tag_name"' | cut -d'"' -f4 || echo "v0.10.6")
echo "下载版本: $VERSION"
wget -q --show-progress "https://github.com/p4gefau1t/trojan-go/releases/download/${VERSION}/trojan-go-linux-amd64.zip" -O trojan-go.zip
unzip -o trojan-go.zip
install -Dm755 trojan-go /usr/local/bin/trojan-go
mkdir -p /etc/trojan-go

# 2. 证书
curl -s https://get.acme.sh | sh -s --
if ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --key-file /etc/trojan-go/private.key --fullchain-file /etc/trojan-go/fullchain.cer; then
  echo "证书申请成功"
else
  echo "⚠️ 证书申请失败！请检查域名解析到本机IP及80端口空闲"
fi

# 3. 配置（mux已开）
cat > /etc/trojan-go/config.json <<'EOF'
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 443,
  "remote_addr": "127.0.0.1",
  "remote_port": 80,
  "password": ["PASSWORD_PLACEHOLDER"],
  "ssl": {
    "cert": "/etc/trojan-go/fullchain.cer",
    "key": "/etc/trojan-go/private.key",
    "sni": "DOMAIN_PLACEHOLDER"
  },
  "mux": {"enabled": true, "concurrency": 8},
  "tcp": {"prefer_ipv4": true}
}
EOF
sed -i "s|PASSWORD_PLACEHOLDER|$PASSWORD|g" /etc/trojan-go/config.json
sed -i "s|DOMAIN_PLACEHOLDER|$DOMAIN|g" /etc/trojan-go/config.json

# 4. 自动TCP优化（按内存分级）
cat > /etc/sysctl.d/99-trojan-tcp.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF

if [ "$MEM" -gt 4096 ]; then
  cat >> /etc/sysctl.d/99-trojan-tcp.conf <<EOF
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
EOF
elif [ "$MEM" -gt 2048 ]; then
  cat >> /etc/sysctl.d/99-trojan-tcp.conf <<EOF
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF
else
  cat >> /etc/sysctl.d/99-trojan-tcp.conf <<EOF
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608
EOF
fi

cat >> /etc/sysctl.d/99-trojan-tcp.conf <<EOF
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 8192
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_keepalive_time = 300
EOF

sysctl -p /etc/sysctl.d/99-trojan-tcp.conf > /dev/null

# 5. systemd
cat > /etc/systemd/system/trojan-go.service <<EOF
[Unit]
Description=Trojan-Go Service
After=network.target

[Service]
ExecStart=/usr/local/bin/trojan-go -config /etc/trojan-go/config.json
Restart=always
User=root
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now trojan-go

echo "=== 安装完成！ ==="
echo "域名: $DOMAIN | 端口: 443 | 密码: $PASSWORD"
echo "TCP已自动优化（${MEM}MB适配）"
echo "查看日志: journalctl -u trojan-go -f"
echo "卸载命令: systemctl stop trojan-go && rm -rf /usr/local/bin/trojan-go /etc/trojan-go /etc/systemd/system/trojan-go.service /etc/sysctl.d/99-trojan-tcp.conf"