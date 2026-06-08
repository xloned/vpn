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

# ── Config ──────────────────────────────────────────────
INSTALL_DIR="/opt/vpn"
DATA_DIR="$INSTALL_DIR/data"
CONFIG_DIR="$INSTALL_DIR/configs"
BOT_DIR="$INSTALL_DIR/bot"
SCRIPTS_DIR="$INSTALL_DIR/scripts"

HYSTERIA_PORT=443
REALITY_PORT=8443

mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$BOT_DIR" "$SCRIPTS_DIR"

# ── Interactive setup ───────────────────────────────────
if [[ -f "$INSTALL_DIR/.env" ]]; then
    source "$INSTALL_DIR/.env"
    warn "Found existing .env, using saved values"
fi

ask() {
    local prompt="$1" var="$2"
    if [[ -t 0 ]]; then
        read -rp "$prompt" "$var"
    elif [[ -e /dev/tty ]]; then
        read -rp "$prompt" "$var" < /dev/tty
    else
        err "Cannot read input. Run the script directly instead of piping:\n  git clone https://github.com/xloned/vpn.git && cd vpn && bash install.sh"
    fi
}

if [[ -z "${TG_BOT_TOKEN:-}" ]]; then
    ask "Telegram Bot Token: " TG_BOT_TOKEN
fi
if [[ -z "${TG_ADMIN_ID:-}" ]]; then
    ask "Telegram Admin Chat ID: " TG_ADMIN_ID
fi
if [[ -z "${DOMAIN:-}" ]]; then
    ask "Server domain or IP: " DOMAIN
fi

[[ -z "$TG_BOT_TOKEN" ]] && err "Bot token cannot be empty"
[[ -z "$TG_ADMIN_ID" ]]  && err "Admin chat ID cannot be empty"
[[ -z "$DOMAIN" ]]        && err "Domain/IP cannot be empty"

cat > "$INSTALL_DIR/.env" <<ENVEOF
TG_BOT_TOKEN=$TG_BOT_TOKEN
TG_ADMIN_ID=$TG_ADMIN_ID
DOMAIN=$DOMAIN
ENVEOF
chmod 600 "$INSTALL_DIR/.env"

# ── System ──────────────────────────────────────────────
log "Updating system..."
apt-get update -qq
apt-get install -y -qq curl wget unzip jq python3 python3-pip python3-venv openssl cron > /dev/null

# ── Xray (VLESS + XTLS Reality) ────────────────────────
log "Installing Xray..."
bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

REALITY_KEYS=$(xray x25519)
REALITY_PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep "Private" | awk '{print $3}')
REALITY_PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep "Public" | awk '{print $3}')
REALITY_SHORT_ID=$(openssl rand -hex 8)

echo "$REALITY_PUBLIC_KEY" > "$DATA_DIR/reality_public_key"
echo "$REALITY_SHORT_ID" > "$DATA_DIR/reality_short_id"

USERS_JSON="[]"
for i in $(seq 1 5); do
    UUID=$(xray uuid)
    echo "$UUID" > "$DATA_DIR/user_${i}_uuid"
    USERS_JSON=$(echo "$USERS_JSON" | jq --arg id "$UUID" --arg email "user$i@vpn" '. + [{"id": $id, "email": $email, "flow": "xtls-rprx-vision"}]')
done

cat > "$CONFIG_DIR/xray.json" <<XEOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "stats": {},
  "api": {
    "tag": "api",
    "services": ["StatsService"]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag": "api-in",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    },
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${REALITY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": ${USERS_JSON},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.google.com:443",
          "xver": 0,
          "serverNames": ["www.google.com", "google.com"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${REALITY_SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "blocked", "protocol": "blackhole"}
  ],
  "routing": {
    "rules": [
      {"inboundTag": ["api-in"], "outboundTag": "api", "type": "field"}
    ]
  }
}
XEOF

mkdir -p /var/log/xray
chown -R nobody:nogroup /var/log/xray
cp "$CONFIG_DIR/xray.json" /usr/local/etc/xray/config.json

systemctl enable xray
systemctl restart xray
log "Xray installed (VLESS+Reality on port $REALITY_PORT)"

# ── Hysteria2 ───────────────────────────────────────────
log "Installing Hysteria2..."
bash -c "$(curl -sL https://get.hy2.sh/)"

HYSTERIA_OBFS_PASS=$(openssl rand -base64 16)
echo "$HYSTERIA_OBFS_PASS" > "$DATA_DIR/hysteria_obfs_pass"

HYSTERIA_API_SECRET=$(openssl rand -base64 24)
echo "$HYSTERIA_API_SECRET" > "$DATA_DIR/hysteria_api_secret"

HY_USERPASS_BLOCK=""
for i in $(seq 1 5); do
    PASS=$(openssl rand -base64 16)
    echo "$PASS" > "$DATA_DIR/hysteria_user_${i}_pass"
    HY_USERPASS_BLOCK="${HY_USERPASS_BLOCK}    user${i}: ${PASS}\n"
done

cat > "$CONFIG_DIR/hysteria2.yaml" <<HEOF
listen: :${HYSTERIA_PORT}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

obfs:
  type: salamander
  salamander:
    password: ${HYSTERIA_OBFS_PASS}

auth:
  type: userpass
  userpass:
$(echo -e "$HY_USERPASS_BLOCK")

masquerade:
  type: proxy
  proxy:
    url: https://www.google.com
    rewriteHost: true

trafficStats:
  listen: 127.0.0.1:9999
  secret: ${HYSTERIA_API_SECRET}

bandwidth:
  up: 1 gbps
  down: 1 gbps
HEOF

mkdir -p /etc/hysteria

if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log "IP detected, generating self-signed cert..."
    openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/server.key
    openssl req -new -x509 -key /etc/hysteria/server.key \
        -out /etc/hysteria/server.crt \
        -subj "/CN=bing.com" -days 3650
else
    log "Domain detected, getting Let's Encrypt cert..."
    apt-get install -y -qq certbot > /dev/null
    certbot certonly --standalone --agree-tos --register-unsafely-without-email \
        -d "$DOMAIN" --non-interactive || {
        warn "Certbot failed, using self-signed cert"
        openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/server.key
        openssl req -new -x509 -key /etc/hysteria/server.key \
            -out /etc/hysteria/server.crt \
            -subj "/CN=$DOMAIN" -days 3650
    }
    if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        ln -sf "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" /etc/hysteria/server.crt
        ln -sf "/etc/letsencrypt/live/$DOMAIN/privkey.pem" /etc/hysteria/server.key
    fi
fi

cp "$CONFIG_DIR/hysteria2.yaml" /etc/hysteria/config.yaml

cat > /etc/systemd/system/hysteria-server.service <<'SVCEOF'
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable hysteria-server
systemctl start hysteria-server
log "Hysteria2 installed (port $HYSTERIA_PORT/UDP)"

# ── Telegram Bot ────────────────────────────────────────
log "Setting up Telegram bot..."

cat > "$BOT_DIR/requirements.txt" <<'REQEOF'
python-telegram-bot==21.6
aiohttp==3.10.11
psutil==6.1.0
python-dotenv==1.0.1
REQEOF

python3 -m venv "$BOT_DIR/venv"
"$BOT_DIR/venv/bin/pip" install -q -r "$BOT_DIR/requirements.txt"

cat > "$BOT_DIR/bot.py" << 'BOTEOF'
import os
import json
import asyncio
import subprocess
import logging
from datetime import datetime, timedelta
from pathlib import Path

import psutil
import aiohttp
from dotenv import load_dotenv
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    Application, CommandHandler, CallbackQueryHandler, ContextTypes
)

load_dotenv("/opt/vpn/.env")
TOKEN = os.environ["TG_BOT_TOKEN"]
ADMIN_ID = int(os.environ["TG_ADMIN_ID"])
DATA_DIR = Path("/opt/vpn/data")
LOG_DIR = Path("/var/log")
CRASH_LOG = DATA_DIR / "crashes.log"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(DATA_DIR / "bot.log"),
        logging.StreamHandler()
    ]
)
log = logging.getLogger(__name__)


def is_admin(update: Update) -> bool:
    return update.effective_user.id == ADMIN_ID


def format_bytes(b: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(b) < 1024:
            return f"{b:.2f} {unit}"
        b /= 1024
    return f"{b:.2f} PB"


def get_system_stats() -> dict:
    cpu = psutil.cpu_percent(interval=1)
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage("/")
    net = psutil.net_io_counters()
    uptime_sec = int((datetime.now() - datetime.fromtimestamp(psutil.boot_time())).total_seconds())
    days, rem = divmod(uptime_sec, 86400)
    hours, rem = divmod(rem, 3600)
    mins, _ = divmod(rem, 60)

    return {
        "cpu": cpu,
        "ram_used": format_bytes(mem.used),
        "ram_total": format_bytes(mem.total),
        "ram_pct": mem.percent,
        "disk_used": format_bytes(disk.used),
        "disk_total": format_bytes(disk.total),
        "disk_pct": disk.percent,
        "net_sent": format_bytes(net.bytes_sent),
        "net_recv": format_bytes(net.bytes_recv),
        "uptime": f"{days}d {hours}h {mins}m",
    }


def get_service_status(name: str) -> str:
    try:
        r = subprocess.run(
            ["systemctl", "is-active", name],
            capture_output=True, text=True, timeout=5
        )
        return r.stdout.strip()
    except Exception:
        return "unknown"


async def get_xray_stats() -> dict:
    try:
        r = subprocess.run(
            ["xray", "api", "statsquery", "-server=127.0.0.1:10085", "-pattern", ""],
            capture_output=True, text=True, timeout=10
        )
        data = json.loads(r.stdout) if r.stdout.strip() else {}
        stats = {}
        for s in data.get("stat", []):
            name = s.get("name", "")
            value = int(s.get("value", 0))
            if "user>>>" in name:
                parts = name.split(">>>")
                user = parts[1]
                direction = parts[3]
                if user not in stats:
                    stats[user] = {"up": 0, "down": 0}
                if direction == "uplink":
                    stats[user]["up"] = value
                else:
                    stats[user]["down"] = value
        return stats
    except Exception as e:
        log.error(f"Xray stats error: {e}")
        return {}


async def get_hysteria_stats() -> dict:
    password = ""
    pass_file = DATA_DIR / "hysteria_api_secret"
    if pass_file.exists():
        password = pass_file.read_text().strip()
    try:
        async with aiohttp.ClientSession() as session:
            headers = {"Authorization": password} if password else {}
            async with session.get(
                "http://127.0.0.1:9999/traffic",
                headers=headers, timeout=aiohttp.ClientTimeout(total=5)
            ) as resp:
                if resp.status == 200:
                    return await resp.json()
    except Exception as e:
        log.error(f"Hysteria stats error: {e}")
    return {}


async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        return
    kb = [
        [InlineKeyboardButton("Server Status", callback_data="status")],
        [InlineKeyboardButton("Traffic Stats", callback_data="traffic")],
        [InlineKeyboardButton("User Configs", callback_data="configs")],
        [InlineKeyboardButton("Recent Crashes", callback_data="crashes")],
        [InlineKeyboardButton("Restart Services", callback_data="restart")],
    ]
    await update.message.reply_text(
        "VPN Management Bot", reply_markup=InlineKeyboardMarkup(kb)
    )


async def cmd_status(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        return
    s = get_system_stats()
    xray_st = get_service_status("xray")
    hy_st = get_service_status("hysteria-server")
    text = (
        f"<b>Server Status</b>\n\n"
        f"<b>Uptime:</b> {s['uptime']}\n"
        f"<b>CPU:</b> {s['cpu']}%\n"
        f"<b>RAM:</b> {s['ram_used']}/{s['ram_total']} ({s['ram_pct']}%)\n"
        f"<b>Disk:</b> {s['disk_used']}/{s['disk_total']} ({s['disk_pct']}%)\n"
        f"<b>Network:</b> ↑{s['net_sent']} ↓{s['net_recv']}\n\n"
        f"<b>Services:</b>\n"
        f"  Xray (VLESS): <code>{xray_st}</code>\n"
        f"  Hysteria2: <code>{hy_st}</code>"
    )
    if update.message:
        await update.message.reply_text(text, parse_mode="HTML")
    elif update.callback_query:
        await update.callback_query.edit_message_text(text, parse_mode="HTML")


async def cmd_traffic(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        return
    xray_stats = await get_xray_stats()
    hysteria_stats = await get_hysteria_stats()

    lines = ["<b>Traffic Stats</b>\n", "<b>VLESS (Xray):</b>"]
    if xray_stats:
        for user, data in xray_stats.items():
            lines.append(f"  {user}: ↑{format_bytes(data['up'])} ↓{format_bytes(data['down'])}")
    else:
        lines.append("  No data")

    lines.append("\n<b>Hysteria2:</b>")
    if hysteria_stats:
        for user, data in hysteria_stats.items():
            up = data.get("tx", 0)
            down = data.get("rx", 0)
            lines.append(f"  {user}: ↑{format_bytes(up)} ↓{format_bytes(down)}")
    else:
        lines.append("  No data")

    text = "\n".join(lines)
    if update.message:
        await update.message.reply_text(text, parse_mode="HTML")
    elif update.callback_query:
        await update.callback_query.edit_message_text(text, parse_mode="HTML")


async def cmd_configs(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        return
    domain = os.environ.get("DOMAIN", "SERVER_IP")
    pub_key = (DATA_DIR / "reality_public_key").read_text().strip()
    short_id = (DATA_DIR / "reality_short_id").read_text().strip()

    lines = ["<b>User Configs</b>\n"]
    for i in range(1, 6):
        uuid_file = DATA_DIR / f"user_{i}_uuid"
        hy_file = DATA_DIR / f"hysteria_user_{i}_pass"
        if not uuid_file.exists():
            continue
        uuid = uuid_file.read_text().strip()
        vless_link = (
            f"vless://{uuid}@{domain}:8443"
            f"?security=reality&sni=www.google.com"
            f"&fp=chrome&pbk={pub_key}"
            f"&sid={short_id}&type=tcp"
            f"&flow=xtls-rprx-vision"
            f"&encryption=none"
            f"#VLESS-User{i}"
        )
        lines.append(f"<b>User {i}</b>")
        lines.append(f"VLESS:\n<code>{vless_link}</code>\n")

        if hy_file.exists():
            hy_pass = hy_file.read_text().strip()
            hy_obfs = (DATA_DIR / "hysteria_obfs_pass").read_text().strip()
            hy_link = f"hysteria2://user{i}:{hy_pass}@{domain}:443?obfs=salamander&obfs-password={hy_obfs}&insecure=1#HY2-User{i}"
            lines.append(f"Hysteria2:\n<code>{hy_link}</code>\n")

    text = "\n".join(lines)
    if update.message:
        await update.message.reply_text(text, parse_mode="HTML")
    elif update.callback_query:
        await update.callback_query.edit_message_text(text, parse_mode="HTML")


async def cmd_crashes(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        return
    if CRASH_LOG.exists():
        content = CRASH_LOG.read_text().strip()
        last_lines = "\n".join(content.split("\n")[-20:])
        text = f"<b>Recent Crashes</b>\n\n<pre>{last_lines}</pre>"
    else:
        text = "No crash logs found."

    if update.message:
        await update.message.reply_text(text, parse_mode="HTML")
    elif update.callback_query:
        await update.callback_query.edit_message_text(text, parse_mode="HTML")


async def cmd_restart(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        return
    results = []
    for svc in ("xray", "hysteria-server"):
        try:
            subprocess.run(["systemctl", "restart", svc], timeout=15, check=True)
            results.append(f"{svc}: restarted")
        except Exception as e:
            results.append(f"{svc}: FAILED ({e})")
    text = "<b>Restart Results</b>\n\n" + "\n".join(results)
    if update.message:
        await update.message.reply_text(text, parse_mode="HTML")
    elif update.callback_query:
        await update.callback_query.edit_message_text(text, parse_mode="HTML")


async def button_handler(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    actions = {
        "status": cmd_status,
        "traffic": cmd_traffic,
        "configs": cmd_configs,
        "crashes": cmd_crashes,
        "restart": cmd_restart,
    }
    handler = actions.get(q.data)
    if handler:
        await handler(update, ctx)


def main():
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("traffic", cmd_traffic))
    app.add_handler(CommandHandler("configs", cmd_configs))
    app.add_handler(CommandHandler("crashes", cmd_crashes))
    app.add_handler(CommandHandler("restart", cmd_restart))
    app.add_handler(CallbackQueryHandler(button_handler))
    log.info("Bot started")
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
BOTEOF

cat > "$BOT_DIR/requirements.txt" <<'REQEOF'
python-telegram-bot==21.6
aiohttp==3.10.11
psutil==6.1.0
python-dotenv==1.0.1
REQEOF

# ── Monitor script ──────────────────────────────────────
cat > "$SCRIPTS_DIR/monitor.sh" << 'MONEOF'
#!/usr/bin/env bash
source /opt/vpn/.env

DATA_DIR="/opt/vpn/data"
CRASH_LOG="$DATA_DIR/crashes.log"
NOW=$(date '+%Y-%m-%d %H:%M:%S')

send_alert() {
    local msg="$1"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TG_ADMIN_ID" \
        -d text="$msg" \
        -d parse_mode="HTML" > /dev/null 2>&1
}

for svc in xray hysteria-server; do
    if ! systemctl is-active --quiet "$svc"; then
        echo "[$NOW] $svc is DOWN, restarting..." >> "$CRASH_LOG"

        if [[ "$svc" == "xray" ]]; then
            journalctl -u "$svc" --no-pager -n 50 --since "5 minutes ago" >> "$CRASH_LOG"
        else
            journalctl -u "$svc" --no-pager -n 50 --since "5 minutes ago" >> "$CRASH_LOG"
        fi

        systemctl restart "$svc"
        sleep 3

        if systemctl is-active --quiet "$svc"; then
            send_alert "⚠️ <b>$svc</b> was down, restarted successfully at $NOW"
            echo "[$NOW] $svc restarted OK" >> "$CRASH_LOG"
        else
            send_alert "🔴 <b>$svc</b> is DOWN and restart FAILED at $NOW"
            echo "[$NOW] $svc restart FAILED" >> "$CRASH_LOG"
        fi
    fi
done

CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d. -f1)
MEM=$(free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')
DISK=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

if [[ "$CPU" -gt 90 ]] || [[ "$MEM" -gt 90 ]] || [[ "$DISK" -gt 90 ]]; then
    send_alert "⚠️ <b>High load</b>\nCPU: ${CPU}%\nRAM: ${MEM}%\nDisk: ${DISK}%"
fi
MONEOF

chmod +x "$SCRIPTS_DIR/monitor.sh"

# ── Bot systemd service ────────────────────────────────
cat > /etc/systemd/system/vpn-bot.service <<BOTSERVICE
[Unit]
Description=VPN Telegram Bot
After=network.target

[Service]
Type=simple
ExecStart=$BOT_DIR/venv/bin/python $BOT_DIR/bot.py
WorkingDirectory=$BOT_DIR
Restart=on-failure
RestartSec=5
EnvironmentFile=$INSTALL_DIR/.env

[Install]
WantedBy=multi-user.target
BOTSERVICE

systemctl daemon-reload
systemctl enable vpn-bot
systemctl start vpn-bot

# ── Cron ────────────────────────────────────────────────
(crontab -l 2>/dev/null; echo "*/3 * * * * /opt/vpn/scripts/monitor.sh") | sort -u | crontab -
log "Monitor cron set (every 3 min)"

# ── Firewall ────────────────────────────────────────────
log "Configuring firewall..."
if command -v ufw &>/dev/null; then
    ufw allow 22/tcp
    ufw allow ${HYSTERIA_PORT}/udp
    ufw allow ${REALITY_PORT}/tcp
    ufw --force enable
fi

# ── Summary ─────────────────────────────────────────────
echo ""
echo "=========================================="
echo -e "${GREEN}  VPN Server Deployed Successfully${NC}"
echo "=========================================="
echo ""
echo "  VLESS + XTLS Reality: port ${REALITY_PORT}/tcp"
echo "  Hysteria2:            port ${HYSTERIA_PORT}/udp"
echo ""
echo "  Configs: /opt/vpn/configs/"
echo "  Data:    /opt/vpn/data/"
echo ""
echo "  Telegram bot: /start to begin"
echo "  Bot commands: /status /traffic /configs /crashes /restart"
echo ""

log "Generating client configs..."
PUB_KEY=$(cat "$DATA_DIR/reality_public_key")
SID=$(cat "$DATA_DIR/reality_short_id")
HY_OBFS=$(cat "$DATA_DIR/hysteria_obfs_pass")

for i in $(seq 1 5); do
    UUID=$(cat "$DATA_DIR/user_${i}_uuid")
    echo ""
    echo "--- User $i ---"
    echo "VLESS: vless://${UUID}@${DOMAIN}:${REALITY_PORT}?security=reality&sni=www.google.com&fp=chrome&pbk=${PUB_KEY}&sid=${SID}&type=tcp&flow=xtls-rprx-vision&encryption=none#VLESS-User${i}"

    if [[ -f "$DATA_DIR/hysteria_user_${i}_pass" ]]; then
        HY_USER_PASS=$(cat "$DATA_DIR/hysteria_user_${i}_pass")
        echo "HY2:   hysteria2://user${i}:${HY_USER_PASS}@${DOMAIN}:${HYSTERIA_PORT}?obfs=salamander&obfs-password=${HY_OBFS}&insecure=1#HY2-User${i}"
    fi
done

echo ""
log "Done! Send /start to your Telegram bot."
