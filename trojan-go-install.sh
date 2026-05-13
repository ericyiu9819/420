#!/bin/bash
# Trojan-Go 安全优化一键安装 v3（强制Let's Encrypt + 邮箱自动注册）
set -e

echo "=== Trojan-Go 安全版一键安装 v3 ==="
read -p "请输入你的域名（已解析到本VPS）: " DOMAIN
read -p "请输入Trojan密码（推荐强密码）: " PASSWORD
read -p "请输入你的邮箱（用于Let's Encrypt证书）: " EMAIL

[[ -z "$DOMAIN" || -z "$PASSWORD" || -z "$EMAIL" ]] && { echo "域名、密码、邮箱都不能为空！"; exit 1; }

# 系统&内存检测
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
  [[ -z "$OS" && -n "$ID_LIKE" ]] && OS=$(echo "$ID_LIKE" | cut -d' ' -f1 | tr '[:upper:]' '[:lower:]')
fi
MEM=$(free -m 2>/dev/null | awk '/Mem:/{print $2}' || echo 1024)
echo "检测到系统: $OS，内存: ${MEM}MB"

# 依赖安装
if [[ "$OS" == *"debian"* || "$OS" == *"ubuntu"* ]]; then
  apt-get update && apt-get install -y curl unzip socat
elif [[ "$OS" == *"centos"* || "$OS" == *"rhel"* || "$OS" == *"rocky"* || "$OS" == *"fedora"* ]]; then
  yum install -y curl unzip socat || dnf install -y curl unzip socat
fi

# 1. 下载 Trojan-Go
VERSION="v0.10.6"
wget -q --show-progress "https://github.com/p4gefau1t/trojan-go/releases/download/${VERSION}/trojan-go-linux-amd64.zip" -O trojan-go.zip
unzip -o trojan-go.zip
install -Dm755 trojan-go /usr/local/bin/trojan-go
mkdir -p /etc/trojan-go

# 2. acme.sh + 强制Let's Encrypt
echo "安装/更新 acme.sh..."
curl -s https://get.acme.sh | sh -s --
/root/.acme.sh/acme.sh --register-account -m "$EMAIL" --force || true

echo "申请证书（强制使用Let's Encrypt）..."
/root/.acme.sh/acme.sh --issue -d "$DOMAIN" \
  --standalone \
  --key-file /etc/trojan-go/private.key \
  --fullchain-file /etc/trojan-go/fullchain.cer \
  --server letsencrypt \
  --force || echo "⚠️ 证书申请失败！请检查域名解析和80端口是否空闲"

# 3. 配置
cat > /etc/trojan-go/config.json <<'EOL'
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
EOL
sed -i "s|PASSWORD_PLACEHOLDER|$(printf '%q' "$PASSWORD")|g" /etc/trojan-go/config.json
sed -i "s|DOMAIN_PLACEHOLDER|$DOMAIN|g" /etc/trojan-go/config.json

# 4. TCP自动优化（BBR完整开启）
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

echo "=== 安装完成（v3）！ ==="
echo "域名: $DOMAIN | 端口: 443 | 密码: $PASSWORD | 邮箱: $EMAIL"
echo "BBR已开启，TCP已优化"
echo "日志命令: journalctl -u trojan-go -f"