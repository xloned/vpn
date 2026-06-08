#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root${NC}"; exit 1; }

echo -e "${RED}This will remove all VPN components.${NC}"
read -rp "Continue? (y/N): " confirm
[[ "$confirm" != "y" ]] && exit 0

echo "Stopping services..."
systemctl stop vpn-bot xray hysteria-server 2>/dev/null || true
systemctl disable vpn-bot xray hysteria-server 2>/dev/null || true

echo "Removing Hysteria2..."
rm -f /usr/local/bin/hysteria
rm -rf /etc/hysteria
rm -f /etc/systemd/system/hysteria-server.service

echo "Removing Xray..."
bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove 2>/dev/null || true

echo "Removing bot..."
rm -f /etc/systemd/system/vpn-bot.service

echo "Removing cron..."
crontab -l 2>/dev/null | grep -v "monitor.sh" | crontab - 2>/dev/null || true

echo "Removing data..."
rm -rf /opt/vpn

systemctl daemon-reload

echo -e "${GREEN}Uninstalled.${NC}"
