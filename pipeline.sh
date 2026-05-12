cd 420

cat > pipeline.sh << 'EOF'
#!/bin/bash
# pipeline.sh - WireGuard 稳定一键流水线
set -e
echo "=== WireGuard 稳定流水线 ==="
echo "1. stable-setup.sh"
echo "2. 02-wg-install.sh"
echo "3. 03-wg-tls.sh"
read -rp "开始部署？(y/N): " c
[[ ! "$c" =~ ^[Yy]$ ]] && exit 0
echo "[1/3] 执行稳定配置..."
sudo bash stable-setup.sh
echo "[2/3] 安装 WireGuard..."
sudo bash 02-wg-install.sh
echo "[3/3] 配置 TLS 伪装..."
sudo bash 03-wg-tls.sh
echo "✅ 全部完成！"
EOF

chmod +x pipeline.sh
git add pipeline.sh
git commit -m "Add pipeline.sh - stable deployment"
git push
