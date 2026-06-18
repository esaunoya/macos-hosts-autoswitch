#!/bin/sh
# Uninstaller for hosts-autoswitch (macOS). Run with sudo:
#   sudo ./uninstall.sh
set -u

LABEL="hosts-autoswitch"
SCRIPT_DST="/usr/local/sbin/hosts-autoswitch.sh"
CONF_DST="/usr/local/etc/hosts-autoswitch.conf"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"
BACKUP="/etc/hosts.bak.hosts-autoswitch"

[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo: sudo ./uninstall.sh"; exit 1; }

launchctl bootout system "$PLIST_DST" 2>/dev/null || true
rm -f "$PLIST_DST" "$SCRIPT_DST" "$CONF_DST"

echo "Removed the daemon, script, and config."
echo ""
echo "Note: your /etc/hosts still has whatever line was last written for the"
echo "managed host. To restore the pre-install /etc/hosts, run:"
echo "    sudo cp $BACKUP /etc/hosts"
echo "(backup present: $( [ -f "$BACKUP" ] && echo yes || echo no ))"
