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

[[ ! -f "$INSTALL_DIR/.env" ]] && err "Base VPN not installed. Run install.sh first"
source "$INSTALL_DIR/.env"

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
echo "  Cloudflare Tunnel Setup"
echo "=========================================="
echo ""
echo "This creates an OUTBOUND tunnel from your server to Cloudflare."
echo "No inbound ports needed — bypasses IP blocking completely."
echo ""
echo "Steps to get the tunnel token:"
echo "  1. Go to https://one.dash.cloudflare.com"
echo "  2. Networks -> Tunnels -> Create a tunnel"
echo "  3. Choose 'Cloudflared' connector"
echo "  4. Name it anything (e.g. 'vpn')"
echo "  5. Copy the tunnel token (long string starting with 'ey...')"
echo ""

if [[ -z "${CF_TUNNEL_TOKEN:-}" ]]; then
    ask "Cloudflare Tunnel token: " CF_TUNNEL_TOKEN
fi
[[ -z "$CF_TUNNEL_TOKEN" ]] && err "Token cannot be empty"

# Save token
echo "$CF_TUNNEL_TOKEN" > "$DATA_DIR/cf_tunnel_token"
chmod 600 "$DATA_DIR/cf_tunnel_token"

if ! grep -q "CF_TUNNEL_TOKEN" "$INSTALL_DIR/.env" 2>/dev/null; then
    echo "CF_TUNNEL_TOKEN=$CF_TUNNEL_TOKEN" >> "$INSTALL_DIR/.env"
else
    sed -i "s|^CF_TUNNEL_TOKEN=.*|CF_TUNNEL_TOKEN=$CF_TUNNEL_TOKEN|" "$INSTALL_DIR/.env"
fi

# ── Ensure VLESS+WS inbound exists in Xray ────────────
WS_PORT=10086
XRAY_CONFIG="/usr/local/etc/xray/config.json"

if ! jq -e '.inbounds[] | select(.tag == "vless-ws")' "$XRAY_CONFIG" > /dev/null 2>&1; then
    log "Adding VLESS+WS inbound to Xray..."

    if [[ -f "$DATA_DIR/ws_path" ]]; then
        WS_PATH=$(cat "$DATA_DIR/ws_path")
    else
        WS_PATH="/$(openssl rand -hex 12)"
        echo "$WS_PATH" > "$DATA_DIR/ws_path"
    fi

    USERS_WS_JSON="[]"
    for i in $(seq 1 5); do
        UUID_FILE="$DATA_DIR/user_${i}_uuid"
        [[ ! -f "$UUID_FILE" ]] && continue
        UUID=$(cat "$UUID_FILE")
        USERS_WS_JSON=$(echo "$USERS_WS_JSON" | jq --arg id "$UUID" --arg email "user${i}-ws@vpn" '. + [{"id": $id, "email": $email}]')
    done

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
    ' "$XRAY_CONFIG" > /tmp/xray_tunnel.json && mv /tmp/xray_tunnel.json "$XRAY_CONFIG"

    systemctl restart xray
    log "Xray VLESS+WS added on 127.0.0.1:${WS_PORT}"
else
    WS_PATH=$(cat "$DATA_DIR/ws_path")
    log "VLESS+WS already configured (path: $WS_PATH)"
fi

# ── Ensure nginx is running (tunnel proxies to it) ────
if ! systemctl is-active --quiet nginx; then
    systemctl start nginx
    systemctl enable nginx
    log "Started nginx"
else
    log "Nginx already running"
fi

# ── Install cloudflared ────────────────────────────────
if ! command -v cloudflared &>/dev/null; then
    log "Installing cloudflared..."
    curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
    dpkg -i /tmp/cloudflared.deb
    rm /tmp/cloudflared.deb
else
    log "cloudflared already installed"
fi

# ── Create cloudflared service ─────────────────────────
log "Configuring cloudflared tunnel..."

# Remove old cloudflared service if exists
systemctl stop cloudflared 2>/dev/null || true
systemctl disable cloudflared 2>/dev/null || true
rm -f /etc/systemd/system/cloudflared.service

cat > /etc/systemd/system/cloudflared-tunnel.service <<'CFDEOF'
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run
Environment=TUNNEL_TOKEN=PLACEHOLDER
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
CFDEOF

# Insert actual token
sed -i "s|TUNNEL_TOKEN=PLACEHOLDER|TUNNEL_TOKEN=${CF_TUNNEL_TOKEN}|" /etc/systemd/system/cloudflared-tunnel.service

systemctl daemon-reload
systemctl enable cloudflared-tunnel
systemctl start cloudflared-tunnel
sleep 3

if systemctl is-active --quiet cloudflared-tunnel; then
    log "Cloudflare Tunnel is running!"
else
    systemctl status cloudflared-tunnel --no-pager
    err "Tunnel failed to start"
fi

# ── Instructions ───────────────────────────────────────
WS_PATH=$(cat "$DATA_DIR/ws_path")
WS_PATH_ENCODED=$(echo "$WS_PATH" | sed 's|/|%2F|g')
CDN_DOMAIN="${CDN_DOMAIN:-}"

echo ""
echo "=========================================="
echo -e "${GREEN}  Cloudflare Tunnel Active${NC}"
echo "=========================================="
echo ""
echo "Now go to Cloudflare Zero Trust dashboard:"
echo "  https://one.dash.cloudflare.com"
echo "  Networks -> Tunnels -> your tunnel -> Public Hostname"
echo ""
echo "  Add a public hostname:"
echo "    Subdomain: (leave empty for root domain)"
echo "    Domain: ${CDN_DOMAIN}"
echo "    Type: HTTPS"
echo "    URL: localhost:443"
echo ""
echo "  Under 'Additional application settings' -> 'TLS':"
echo "    No TLS Verify: ON"
echo ""
echo "  Save hostname."
echo ""

if [[ -n "$CDN_DOMAIN" ]]; then
    echo "=========================================="
    echo "  Client links (via Cloudflare Tunnel):"
    echo "=========================================="
    echo ""

    for i in $(seq 1 5); do
        UUID_FILE="$DATA_DIR/user_${i}_uuid"
        [[ ! -f "$UUID_FILE" ]] && continue
        UUID=$(cat "$UUID_FILE")
        echo "--- User $i (Tunnel) ---"
        echo "vless://${UUID}@${CDN_DOMAIN}:443?security=tls&sni=${CDN_DOMAIN}&type=ws&path=${WS_PATH_ENCODED}&encryption=none#Tunnel-User${i}"
        echo ""
    done
fi

echo ""
log "Done! Tunnel connects OUTBOUND to Cloudflare — no inbound ports needed."
log "TSPU cannot block this because it only sees traffic to Cloudflare IPs."
