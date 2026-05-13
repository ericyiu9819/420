#!/bin/bash
# Trojan-Go v4 一键安装（带导入链接 + 二维码）
set -e

echo "=== Trojan-Go v4 安全安装（带二维码） ==="
read -p "请输入你的域名（已解析到本VPS）: " DOMAIN
read -p "请输入Trojan密码（推荐强密码）: " PASSWORD
read -p "请输入邮箱（用于证书）: " EMAIL

[[ -z "$DOMAIN" || -z "$PASSWORD" || -z "$EMAIL" ]] && { echo "所有字段不能为空！"; exit 1; }

# 系统检测
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
fi
MEM=$(free -m 2>/dev/null | awk '/Mem:/{print $2}' || echo 1024)
echo "系统: $OS  内存: ${MEM}MB"

# 安装依赖
if [[ "$OS" == *"debian"* || "$OS" == *"ubuntu"* ]]; then
  apt-get update && apt-get install -y curl unzip socat qrencode openssl
else
  yum install -y curl unzip socat qrencode openssl || dnf install -y curl unzip socat qrencode openssl
fi

# 下载 Trojan-Go
VERSION="v0.10.6"
wget -q --show-progress https://github.com/p4gefau1t/trojan-go/releases/download/${VERSION}/trojan-go-linux-amd64.zip -O trojan-go.zip
unzip -o trojan-go.zip
install -Dm755 trojan-go /usr/local/bin/trojan-go
mkdir -p /etc/trojan-go

# 生成自签名证书
echo "生成自签名证书..."
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/trojan-go/private.key -out /etc/trojan-go/fullchain.cer \
  -subj "/CN=$DOMAIN" -days 3650 -batch

# 创建最简纯代理配置
cat > /etc/trojan-go/config.json <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 443,
  "password": ["$PASSWORD"],
  "ssl": {
    "cert": "/etc/trojan-go/fullchain.cer",
    "key": "/etc/trojan-go/private.key",
    "sni": "$DOMAIN"
  },
  "mux": {
    "enabled": true,
    "concurrency": 8
  },
  "tcp": {
    "prefer_ipv4": true
  }
}
EOF

# TCP自动优化
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
EOF
sysctl -p /etc/sysctl.d/99-trojan-tcp.conf > /dev/null

# systemd
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

# 生成节点信息
echo "=== Trojan-Go v4 安装完成！ ==="
echo "域名: $DOMAIN"
echo "端口: 443"
echo "密码: $PASSWORD"

LINK="trojan://$PASSWORD@$DOMAIN:443?security=tls&sni=$DOMAIN&allowInsecure=0#$DOMAIN-Trojan-Go"

echo -e "\n=== 节点导入链接 ==="
echo "$LINK"

echo -e "\n=== 二维码（手机扫码导入） ==="
qrencode -t ANSIUTF8 "$LINK"

echo -e "\n客户端推荐：Clash Meta / v2rayN / Nekobox / Shadowrocket"
echo "日志查看：journalctl -u trojan-go -f"