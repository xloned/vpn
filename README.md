# VPN Server

Automated deployment: Hysteria2 + VLESS (XTLS Reality) with Telegram bot management.

## Quick Start

```bash
ssh root@your-server
apt install -y curl
curl -sL https://raw.githubusercontent.com/xloned/vpn/main/install.sh | bash
# or clone and run:
git clone https://github.com/xloned/vpn.git && cd vpn && bash install.sh
```

During installation you'll be asked for:
- **Telegram Bot Token** — get from [@BotFather](https://t.me/BotFather)
- **Telegram Admin Chat ID** — get from [@userinfobot](https://t.me/userinfobot)
- **Server domain or IP**

## Architecture

| Protocol | Port | Transport |
|----------|------|-----------|
| Hysteria2 | 443/udp | QUIC + Salamander obfs |
| VLESS + XTLS Reality | 8443/tcp | TCP + Reality |

## Telegram Bot Commands

| Command | Description |
|---------|-------------|
| `/start` | Main menu |
| `/status` | CPU, RAM, disk, uptime, service status |
| `/traffic` | Per-user traffic stats |
| `/configs` | Connection links for all users |
| `/crashes` | Recent crash logs |
| `/restart` | Restart all VPN services |

## Monitoring

A cron job runs every 3 minutes:
- Checks if services are alive, auto-restarts on failure
- Sends Telegram alert on crash or high resource usage (>90% CPU/RAM/disk)
- Saves crash logs to `/opt/vpn/data/crashes.log`

## File Structure

```
/opt/vpn/
├── .env                    # Secrets
├── configs/
│   ├── xray.json           # VLESS config
│   └── hysteria2.yaml      # Hysteria2 config
├── data/
│   ├── user_*_uuid         # VLESS user UUIDs
│   ├── hysteria_*_pass     # Hysteria2 passwords
│   ├── reality_public_key  # Reality public key
│   └── crashes.log         # Crash history
├── bot/
│   └── bot.py              # Telegram bot
└── scripts/
    └── monitor.sh          # Health monitor
```

## Uninstall

```bash
bash uninstall.sh
```
