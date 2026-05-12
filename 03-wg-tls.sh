#!/bin/bash
# ============================================================
# 03-wg-tls.sh  —— WireGuard TLS 伪装 + 443 端口脚本（最终优化版 v2.1 - 修复 unbound variable）
# ============================================================

set -eo pipefail   # 移除 -u 避免 read 失败时 unbound variable 错误

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DOMAIN=""
EMAIL=""


echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   WireGuard TLS 伪装 + 443 端口（最终优化版）${NC}"
echo -e "${BLUE}========================================${NC}"

echo -e "${YELLOW}此脚本将帮助你实现：\n  • TLS 伪装（浏览器看到普通网站\uff09\n  • 443 端口（隐蔽性最强\uff09\n  • 强烈推荐：客户端 PersistentKeepalive = 25${NC}"
echo ""

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：请使用 sudo 运行此脚本${NC}"
    exit 1
fi

if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo -e "${RED}错误：未检测到 WireGuard 配置${NC}"
    echo -e "${YELLOW}请先运行 02-wg-install.sh${NC}"
    exit 1
fi

read -rp "请输入你的域名（例如：wg.example.com）: " DOMAIN
read -rp "请输入邮箱（用于 Let's Encrypt 证书）: " EMAIL

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    echo -e "${RED}错误：域名和邮箱不能为空${NC}"
    exit 1
fi

echo -e "${YELLOW}正在验证域名解析...${NC}"
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip)
DOMAIN_IP=$(dig +short "$DOMAIN" | tail -1)

if [ -z "$DOMAIN_IP" ] || [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
    echo -e "${YELLOW}警告：域名解析 IP 与服务器 IP 不一致${NC}"
    read -rp "是否继续？(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 1
fi

echo -e "${GREEN}域名验证通过${NC}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y nginx certbot python3-certbot-nginx

mkdir -p /var/www/fake-site
cat > /var/www/fake-site/index.html << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body { font-family: system-ui, -apple-system, sans-serif; text-align: center; padding: 50px; background: #f5f5f5; }
        h1 { color: #333; }
        p { color: #666; }
    </style>
</head>
<body>
    <h1>这是一个普通的网站</h1>
    <p>Nothing suspicious here. Just a normal website.</p>
</body>
</html>
EOF

echo -e "${YELLOW}正在申请 Let's Encrypt 证书...${NC}"
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect || {
    echo -e "${RED}证书申请失败！${NC}"
    echo -e "${YELLOW}请检查：1. 域名是否解析正确  2. 80 端口是否开放${NC}"
    exit 1
}

cat > /etc/nginx/sites-available/wg-tls << EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    root /var/www/fake-site;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
    server_tokens off;
}
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF

ln -sf /etc/nginx/sites-available/wg-tls /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/wg-fake 2>/dev/null || true
nginx -t && systemctl reload nginx

echo -e "${GREEN}✅ Nginx TLS 配置完成${NC}"

echo -e "${YELLOW}正在将 WireGuard 端口切换到 443...${NC}"
sed -i 's/ListenPort = .*/ListenPort = 443/' /etc/wireguard/wg0.conf
wg-quick down wg0 2>/dev/null || true
wg-quick up wg0
echo -e "${GREEN}✅ WireGuard 已切换到 443 UDP 端口${NC}"

ufw allow 443/tcp comment 'WG TLS' 2>/dev/null || true
ufw allow 443/udp comment 'WG TLS' 2>/dev/null || true
ufw reload 2>/dev/null || true

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}🎉 TLS 伪装部署成功！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "域名          : ${BLUE}$DOMAIN${NC}"
echo -e "Endpoint      : ${BLUE}$DOMAIN:443${NC}"
echo -e "浏览器测试    : ${BLUE}https://$DOMAIN${NC}"
echo -e "客户端配置    : 把 Endpoint 改为 ${BLUE}$DOMAIN:443${NC}"
echo -e "推荐 MTU      : 1380 ~ 1420"
echo ""
# ==================== PersistentKeepalive 强烈推荐 ====================
echo -e "${YELLOW}【强烈推荐：客户端 PersistentKeepalive 设置】${NC}"
echo "这是解决手机、弱网、NAT 环境断流的最重要参数！"
echo ""
echo -e "在客户端配置文件中找到 [Peer] 部分，添加下面这一行："
echo -e "${GREEN}PersistentKeepalive = 25${NC}"
echo ""
echo -e "推荐值："
echo "  • 手机用户：25（最常用）"
echo "  • 电脑用户：15~25"
echo "  • 极差网络：10"
echo ""
echo -e "${YELLOW}重要提示：${NC}"
echo "1. 客户端连接后可通过 https://$DOMAIN 验证伪装是否生效"
echo "2. 如需恢复原端口，编辑 /etc/wireguard/wg0.conf 把 443 改回原值"
echo "3. 证书自动续期已由 certbot 配置"
echo "4. 添加 PersistentKeepalive = 25 后，重启客户端即可生效"
echo -e "${GREEN}========================================${NC}"