#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && err "Run as root"

INSTALL_DIR="/opt/vpn"
DATA_DIR="$INSTALL_DIR/data"
CONFIG_DIR="$INSTALL_DIR/configs"

[[ ! -f "$INSTALL_DIR/.env" ]] && err "Base VPN not installed. Run install.sh first"
source "$INSTALL_DIR/.env"

WS_PORT=10086

ask() {
    local prompt="$1" var="$2"
    if [[ -t 0 ]]; then
        read -rp "$prompt" "$var"
    elif [[ -e /dev/tty ]]; then
        read -rp "$prompt" "$var" < /dev/tty
    else
        err "Cannot read input"
    fi
}

echo ""
echo "=========================================="
echo "  VLESS + WebSocket + Cloudflare CDN Setup"
echo "=========================================="
echo ""
echo "This adds a CDN-proxied connection that bypasses IP-based blocking."
echo "TSPU will see traffic going to Cloudflare, not your server."
echo ""
echo "You need a domain managed through Cloudflare (free plan works)."
echo "A cheap .xyz/.site domain costs ~100 rub/year."
echo ""

if [[ -z "${CDN_DOMAIN:-}" ]]; then
    ask "Domain pointed to Cloudflare (e.g. myvpn.xyz): " CDN_DOMAIN
fi
[[ -z "$CDN_DOMAIN" ]] && err "Domain cannot be empty"

# Save to env
if ! grep -q "CDN_DOMAIN" "$INSTALL_DIR/.env" 2>/dev/null; then
    echo "CDN_DOMAIN=$CDN_DOMAIN" >> "$INSTALL_DIR/.env"
else
    sed -i "s|^CDN_DOMAIN=.*|CDN_DOMAIN=$CDN_DOMAIN|" "$INSTALL_DIR/.env"
fi

# ── Generate WS path (random, hard to detect) ──────────
WS_PATH="/$(openssl rand -hex 12)"
echo "$WS_PATH" > "$DATA_DIR/ws_path"
echo "$CDN_DOMAIN" > "$DATA_DIR/cdn_domain"

log "WS path: $WS_PATH"

# ── Build VLESS-WS users JSON ──────────────────────────
USERS_WS_JSON="[]"
for i in $(seq 1 5); do
    UUID_FILE="$DATA_DIR/user_${i}_uuid"
    [[ ! -f "$UUID_FILE" ]] && continue
    UUID=$(cat "$UUID_FILE")
    USERS_WS_JSON=$(echo "$USERS_WS_JSON" | jq --arg id "$UUID" --arg email "user${i}-ws@vpn" '. + [{"id": $id, "email": $email}]')
done

# ── Add WS inbound to Xray config ─────────────────────
log "Adding VLESS+WS inbound to Xray..."

XRAY_CONFIG="/usr/local/etc/xray/config.json"
[[ ! -f "$XRAY_CONFIG" ]] && err "Xray config not found at $XRAY_CONFIG"

WS_INBOUND=$(cat <<WSJSON
{
  "tag": "vless-ws",
  "listen": "127.0.0.1",
  "port": ${WS_PORT},
  "protocol": "vless",
  "settings": {
    "clients": ${USERS_WS_JSON},
    "decryption": "none"
  },
  "streamSettings": {
    "network": "ws",
    "wsSettings": {
      "path": "${WS_PATH}"
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls"]
  }
}
WSJSON
)

# Remove existing vless-ws inbound if any, then add new one
jq --argjson ws "$WS_INBOUND" '
  .inbounds = [.inbounds[] | select(.tag != "vless-ws")] + [$ws]
' "$XRAY_CONFIG" > /tmp/xray_cdn.json && mv /tmp/xray_cdn.json "$XRAY_CONFIG"

systemctl restart xray
log "Xray restarted with VLESS+WS on 127.0.0.1:${WS_PORT}"

# ── Install nginx as TLS terminator + WS proxy ────────
log "Installing nginx..."
apt-get install -y -qq nginx certbot python3-certbot-nginx > /dev/null

# Stop nginx for certbot standalone
systemctl stop nginx 2>/dev/null || true

# Get real TLS cert
log "Getting TLS certificate for $CDN_DOMAIN..."
certbot certonly --standalone --agree-tos --register-unsafely-without-email \
    -d "$CDN_DOMAIN" --non-interactive || {
    err "Certbot failed. Make sure:\n  1. Domain $CDN_DOMAIN has an A record pointing to $(curl -s ifconfig.me)\n  2. Cloudflare proxy (orange cloud) is TEMPORARILY OFF for cert issuance\n  3. Port 80 is open"
}

cat > /etc/nginx/sites-available/vpn-cdn <<NGEOF
server {
    listen 443 ssl http2;
    server_name ${CDN_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${CDN_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${CDN_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # WebSocket proxy for VLESS
    location ${WS_PATH} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 60s;
    }

    # Fake website for everything else
    location / {
        proxy_pass https://www.google.com;
        proxy_set_header Host www.google.com;
        proxy_ssl_server_name on;
    }
}

server {
    listen 80;
    server_name ${CDN_DOMAIN};
    return 301 https://\$server_name\$request_uri;
}
NGEOF

ln -sf /etc/nginx/sites-available/vpn-cdn /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Hysteria uses 443/UDP, nginx uses 443/TCP — no conflict
nginx -t && systemctl restart nginx
systemctl enable nginx
log "Nginx configured as TLS+WS proxy"

# ── Firewall ───────────────────────────────────────────
if command -v ufw &>/dev/null; then
    ufw allow 80/tcp
    ufw allow 443/tcp
fi

# ── Generate CDN client links ──────────────────────────
echo ""
echo "=========================================="
echo -e "${GREEN}  CDN Setup Complete${NC}"
echo "=========================================="
echo ""
echo "IMPORTANT: Now go to Cloudflare dashboard and:"
echo "  1. Set DNS A record: ${CDN_DOMAIN} -> $(curl -s ifconfig.me)"
echo "  2. Turn ON the orange cloud (Proxied) for the record"
echo "  3. SSL/TLS mode: Full (strict)"
echo ""
echo "Client links (via Cloudflare CDN):"
echo ""

for i in $(seq 1 5); do
    UUID_FILE="$DATA_DIR/user_${i}_uuid"
    [[ ! -f "$UUID_FILE" ]] && continue
    UUID=$(cat "$UUID_FILE")
    echo "--- User $i (CDN) ---"
    echo "vless://${UUID}@${CDN_DOMAIN}:443?security=tls&sni=${CDN_DOMAIN}&type=ws&path=$(echo "$WS_PATH" | sed 's|/|%2F|g')&encryption=none#CDN-User${i}"
    echo ""
done

echo "These links go through Cloudflare — TSPU cannot block them."
echo ""
log "Done!"
