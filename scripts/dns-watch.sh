#!/usr/bin/env bash
source /opt/vpn/.env

DOMAIN="${CDN_DOMAIN:-}"
[[ -z "$DOMAIN" ]] && exit 0

CURRENT_IP=$(dig +short "$DOMAIN" 2>/dev/null | head -1)
SERVER_IP=$(curl -s ifconfig.me)

# If IP changed from old server to something else (Cloudflare or our IP)
if [[ "$CURRENT_IP" != "91.209.135.79" ]] && [[ -n "$CURRENT_IP" ]]; then
    # Check if it's a Cloudflare IP or our IP
    MSG="DNS propagation complete for <b>${DOMAIN}</b>!%0A%0AResolves to: <code>${CURRENT_IP}</code>"

    if [[ "$CURRENT_IP" != "$SERVER_IP" ]]; then
        MSG="${MSG}%0A%0ACloudflare proxy is active — CDN links should work now.%0ATest your VLESS+WS+CDN connection!"
    else
        MSG="${MSG}%0A%0ANote: Cloudflare proxy (orange cloud) is OFF. Turn it ON in Cloudflare dashboard."
    fi

    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TG_ADMIN_ID" \
        -d text="$MSG" \
        -d parse_mode="HTML" > /dev/null 2>&1

    # Remove self from cron after notification
    crontab -l 2>/dev/null | grep -v "dns-watch.sh" | crontab -
fi
