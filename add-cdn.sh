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
if [[ -f "$DATA_DIR/ws_path" ]]; then
    WS_PATH=$(cat "$DATA_DIR/ws_path")
    log "Using existing WS path: $WS_PATH"
else
    WS_PATH="/$(openssl rand -hex 12)"
    echo "$WS_PATH" > "$DATA_DIR/ws_path"
fi
echo "$CDN_DOMAIN" > "$DATA_DIR/cdn_domain"

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

jq --argjson ws "$WS_INBOUND" '
  .inbounds = [.inbounds[] | select(.tag != "vless-ws")] + [$ws]
' "$XRAY_CONFIG" > /tmp/xray_cdn.json && mv /tmp/xray_cdn.json "$XRAY_CONFIG"

systemctl restart xray
log "Xray restarted with VLESS+WS on 127.0.0.1:${WS_PORT}"

# ── Install nginx ──────────────────────────────────────
log "Installing nginx..."
apt-get install -y -qq nginx > /dev/null

systemctl stop nginx 2>/dev/null || true

# ── TLS certificate via Cloudflare Origin CA ───────────
# No need for certbot or DNS propagation!
# We generate a self-signed cert that Cloudflare trusts via "Full" SSL mode.
# Cloudflare handles the real TLS to the client.

CERT_DIR="/etc/nginx/ssl"
mkdir -p "$CERT_DIR"

log "Generating origin certificate..."
openssl ecparam -name prime256v1 -genkey -noout -out "$CERT_DIR/origin.key"
openssl req -new -x509 -key "$CERT_DIR/origin.key" \
    -out "$CERT_DIR/origin.crt" \
    -subj "/CN=$CDN_DOMAIN" -days 3650

log "Certificate created (valid 10 years, Cloudflare terminates real TLS)"

cat > /etc/nginx/sites-available/vpn-cdn <<NGEOF
server {
    listen 443 ssl http2;
    server_name ${CDN_DOMAIN};

    ssl_certificate ${CERT_DIR}/origin.crt;
    ssl_certificate_key ${CERT_DIR}/origin.key;
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

    # Normal-looking website for everything else
    location / {
        default_type text/html;
        return 200 '<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>It works!</h1></body></html>';
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

nginx -t && systemctl restart nginx
systemctl enable nginx
log "Nginx configured"

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
echo "IMPORTANT: In Cloudflare dashboard:"
echo "  1. DNS: A record ${CDN_DOMAIN} -> $(curl -s ifconfig.me) with orange cloud (Proxied)"
echo "  2. SSL/TLS -> set to 'Full' (NOT 'Full strict', NOT 'Flexible')"
echo "  3. Under SSL/TLS -> Edge Certificates -> enable 'Always Use HTTPS'"
echo ""
echo "No need to wait for DNS propagation to set this up!"
echo ""
echo "=========================================="
echo "  Client links (via Cloudflare CDN):"
echo "=========================================="
echo ""

WS_PATH_ENCODED=$(echo "$WS_PATH" | sed 's|/|%2F|g')

for i in $(seq 1 5); do
    UUID_FILE="$DATA_DIR/user_${i}_uuid"
    [[ ! -f "$UUID_FILE" ]] && continue
    UUID=$(cat "$UUID_FILE")
    echo "--- User $i (CDN) ---"
    echo "vless://${UUID}@${CDN_DOMAIN}:443?security=tls&sni=${CDN_DOMAIN}&type=ws&path=${WS_PATH_ENCODED}&encryption=none#CDN-User${i}"
    echo ""
done

echo "These links route through Cloudflare — your server IP is hidden."
echo "Works even if the server IP is blocked by TSPU."
echo ""
echo "NOTE: Links will work once DNS propagation completes"
echo "      and orange cloud (Proxied) is ON in Cloudflare."
echo ""
log "Done!"
