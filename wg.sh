#!/bin/bash
# WireGuard 完整交互式管理脚本
# 1号：从你的仓库安装 WireGuard
# 2号：TLS 伪装 + 自适应优化

set -e
echo "=========================================="
echo "   WireGuard 交互式管理工具"
echo "   (你的专属版本)"
echo "=========================================="

exiterr() { echo "Error: $1" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] && exiterr "请使用 sudo 或 root 执行此脚本"

while true; do
    echo
    echo "请选择操作："
    echo "1) 安装 WireGuard（从你的仓库下载）"
    echo "2) 安装 TLS 伪装 + 自适应最优参数"
    echo "3) 退出"
    read -rp "请输入选项 [1-3]: " choice

    case $choice in
        1)
            echo "正在从你的仓库下载并安装 WireGuard..."
            wget -4 https://raw.githubusercontent.com/ericyiu9819/420/main/wg-install.sh -O /tmp/wg-install.sh
            
            if [ ! -f /tmp/wg-install.sh ]; then
                echo "下载失败！请检查仓库是否已上传 wg-install.sh"
                continue
            fi
            
            chmod +x /tmp/wg-install.sh
            bash /tmp/wg-install.sh --auto
            echo "✅ WireGuard 安装完成！"
            ;;

        2)
            echo "=== 执行 TLS 伪装 + 自适应优化 ==="

            read -rp "请输入你的域名 (例如: wg.us.eric402.fcd.com): " DOMAIN
            read -rp "请输入邮箱 (用于申请证书): " EMAIL

            if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
                echo "域名和邮箱不能为空！"
                continue
            fi

            # 自适应优化
            echo "正在进行自适应参数优化..."
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

            # TLS 伪装
            echo "正在部署 Nginx TLS 伪装..."
            apt-get update -qq
            apt-get install -y nginx certbot python3-certbot-nginx

            mkdir -p /var/www/fake-site
            cat > /var/www/fake-site/index.html << 'EOF'
<!DOCTYPE html>
<html><head><title>Welcome</title></head>
<body><h1>这是一个普通的网站</h1><p>Nothing suspicious here.</p></body></html>
EOF

            certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" || {
                echo "证书申请失败！请确认域名已解析到本机IP且80端口开放"
                continue
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

            # 修改 WireGuard 为 443 端口
            if [ -f /etc/wireguard/wg0.conf ]; then
                sed -i "s/ListenPort = .*/ListenPort = 443/" /etc/wireguard/wg0.conf
                wg-quick down wg0 2>/dev/null || true
                wg-quick up wg0
                echo "✅ WireGuard 已切换到 443 UDP"
            fi

            ufw allow 443/tcp 2>/dev/null || true
            ufw allow 443/udp 2>/dev/null || true

            echo "=========================================="
            echo "🎉 2号优化全部完成！"
            echo "域名: $DOMAIN"
            echo "Endpoint: $DOMAIN:443"
            echo "测试：浏览器打开 https://$DOMAIN"
            echo "=========================================="
            ;;

        3)
            echo "已退出。"
            exit 0
            ;;

        *)
            echo "输入错误，请输入 1、2 或 3"
            ;;
    esac
done
