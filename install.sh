#!/bin/sh
# Installer for hosts-autoswitch (macOS). Run with sudo from the repo dir:
#   sudo ./install.sh
set -eu

LABEL="hosts-autoswitch"
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DST="/usr/local/sbin/hosts-autoswitch.sh"
CONF_DST="/usr/local/etc/hosts-autoswitch.conf"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"
LOG="/var/log/hosts-autoswitch.log"
BACKUP="/etc/hosts.bak.hosts-autoswitch"

[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo: sudo ./install.sh"; exit 1; }
[ -f "$HERE/config" ] || {
    echo "Missing ./config -- copy config.example to config and fill it in:"
    echo "    cp config.example config && \$EDITOR config"
    exit 1
}

# Sanity-check required keys exist in config.
for v in MANAGED_HOST LAN_IP REMOTE_IP HOST_KEY_FP; do
    grep -qE "^${v}=" "$HERE/config" || { echo "config is missing $v"; exit 1; }
done

# One-time backup of /etc/hosts (never overwritten on reinstall).
[ -f "$BACKUP" ] || cp /etc/hosts "$BACKUP"

# Install the script and config (mkdir -p + cp + chmod: works everywhere).
mkdir -p /usr/local/sbin /usr/local/etc
cp "$HERE/hosts-autoswitch.sh" "$SCRIPT_DST"
chown root:wheel "$SCRIPT_DST"; chmod 755 "$SCRIPT_DST"
cp "$HERE/config" "$CONF_DST"
chown root:wheel "$CONF_DST"; chmod 600 "$CONF_DST"

# Generate the LaunchDaemon plist from the template.
sed -e "s|__LABEL__|${LABEL}|g" \
    -e "s|__SCRIPT__|${SCRIPT_DST}|g" \
    -e "s|__LOG__|${LOG}|g" \
    "$HERE/hosts-autoswitch.plist.template" > "$PLIST_DST"
chown root:wheel "$PLIST_DST"; chmod 644 "$PLIST_DST"

# (Re)load the daemon, then run once now.
launchctl bootout system "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap system "$PLIST_DST"
"$SCRIPT_DST"

echo ""
echo "Installed. Recent log ($LOG):"
tail -n 3 "$LOG" 2>/dev/null || true
echo ""
echo "Current entry:"
grep -E "[[:space:]]$(grep -E '^MANAGED_HOST=' "$HERE/config" | cut -d= -f2 | tr -d '\"')\$" /etc/hosts || true
