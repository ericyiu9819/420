#!/bin/bash
# 2号脚本：TLS 伪装 + 自适应最优参数优化
# 在 WireGuard 安装完成后运行

set -e
echo "=========================================="
echo "   WireGuard TLS 伪装 + 自适应优化"
echo "=========================================="

exiterr() { echo "Error: $1" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] && exiterr "请使用 sudo 执行此脚本"

# ====================== 输入域名 ======================
read -rp "请输入你的域名 (例如: wg.us.eric402.fcd.com): " DOMAIN
read -rp "请输入邮箱 (用于申请 Let's Encrypt 证书): " EMAIL

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    exiterr "域名和邮箱不能为空！"
fi

# ====================== 自适应优化 ======================
echo "正在检测服务器并应用最优参数..."
cpu=$(nproc)
mem=$(free -m | awk 'NR==2{print $2}')
iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5}' | head -1)

cat > /etc/sysctl.d/99-wg-optimize.conf << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.netdev_max_backlog = $((cpu * 8192))
net.ipv4.tcp_max_syn_backlog = $((cpu * 8192))
net.ipv4.tcp_rmem = 4096 87380 $((mem * 1024))
net.ipv4.tcp_wmem = 4096 87380 $((mem * 1024))
net.core.somaxconn = 65535
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
EOF

sysctl -p /etc/sysctl.d/99-wg-optimize.conf >/dev/null
echo "✅ 自适应优化完成（CPU ${cpu}核 | 内存 ${mem}MB）"

# ====================== TLS 伪装 ======================
echo "正在部署 Nginx + TLS 伪装..."
apt-get update -qq
apt-get install -y nginx certbot python3-certbot-nginx

mkdir -p /var/www/fake-site
cat > /var/www/fake-site/index.html << 'EOF'
<!DOCTYPE html>
<html><head><title>Welcome</title></head>
<body><h1>这是一个普通的网站</h1><p>Nothing suspicious here.</p></body></html>
EOF

certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" || {
    echo "证书申请失败！请确认域名已正确解析到本机 IP，且 80 端口开放"
    exit 1
}

cat > /etc/nginx/sites-available/wg-fake << EOF
server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    root /var/www/fake-site;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF

ln -sf /etc/nginx/sites-available/wg-fake /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# ====================== 修改 WireGuard 端口为 443 ======================
if [ -f /etc/wireguard/wg0.conf ]; then
    sed -i "s/ListenPort = .*/ListenPort = 443/" /etc/wireguard/wg0.conf
    wg-quick down wg0 2>/dev/null || true
    wg-quick up wg0
    echo "✅ WireGuard 已切换到 443 UDP"
fi

ufw allow 443/tcp 2>/dev/null || true
ufw allow 443/udp 2>/dev/null || true
ufw reload 2>/dev/null || true

echo "=========================================="
echo "🎉 2号优化全部完成！"
echo "域名: $DOMAIN"
echo "WireGuard Endpoint: $DOMAIN:443"
echo "测试方法："
echo "   浏览器打开 https://$DOMAIN  → 应看到假网站"
echo "   客户端 Endpoint 改成 $DOMAIN:443"
echo "   MTU 推荐 1380~1420"
echo "=========================================="
