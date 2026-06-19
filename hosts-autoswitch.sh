#!/bin/sh
# hosts-autoswitch
#
# Keep a single /etc/hosts entry pointing at a host's LAN IP while you're on
# your home/trusted network, and at its remote (e.g. Tailscale) IP everywhere
# else -- so you can use one short name no matter where you are.
#
# "Am I home?" is decided by SSH host-key IDENTITY, not by IP or subnet: the
# LAN IP is trusted only if whatever answers there presents the host's pinned
# host key. A different device sitting at the same LAN IP on a foreign network
# therefore cannot hijack the name.
#
# Because /etc/hosts is consulted before DNS, resolution keeps working even
# with a full-tunnel VPN (e.g. Proton VPN) that would otherwise capture DNS.
#
# Run by the LaunchDaemon on every network change. Safe to run by hand too.
#
# Testing without root (writes to a throwaway file):
#   HOSTS_AUTOSWITCH_CONF=./config HOSTS_FILE=/tmp/hosts.test ./hosts-autoswitch.sh
set -u

CONF="${HOSTS_AUTOSWITCH_CONF:-/usr/local/etc/hosts-autoswitch.conf}"
HOSTS="${HOSTS_FILE:-/etc/hosts}"

log() { echo "$(date '+%F %T') $*"; }

[ -r "$CONF" ] || { log "ERROR: config not readable: $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

# Defaults for optional settings.
HOST_KEY_TYPE="${HOST_KEY_TYPE:-ed25519}"
SSH_PORT="${SSH_PORT:-22}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-3}"

# Required settings must be present.
for v in MANAGED_HOST LAN_IP REMOTE_IP HOST_KEY_FP; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || { log "ERROR: $v is not set in $CONF"; exit 1; }
done

# --- decide the target IP by host-key identity -----------------------------
# Probe the LAN IP with a hard timeout; trust it only on an exact key match.
probe_fp="$(ssh-keyscan -T "$PROBE_TIMEOUT" -p "$SSH_PORT" -t "$HOST_KEY_TYPE" "$LAN_IP" 2>/dev/null \
            | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"

if [ "$probe_fp" = "$HOST_KEY_FP" ]; then
    target="$LAN_IP"; where="home/LAN"
else
    target="$REMOTE_IP"; where="remote"
fi

# --- no-op if the entry is already correct ---------------------------------
current="$(awk -v h="$MANAGED_HOST" '$2==h {print $1; exit}' "$HOSTS")"
if [ "$current" = "$target" ]; then
    log "$MANAGED_HOST already -> $target ($where); no change"
    exit 0
fi

# --- rewrite the hosts file atomically -------------------------------------
# Drop any existing line whose canonical (first) name is the managed host,
# then append the desired one. Removal matches the awk field exactly as the
# detection step above ($2 == h), so the two can never disagree. Using a
# literal field comparison (not a regex) also means dots or other regex
# metacharacters in the hostname -- e.g. an FQDN like "my.host" -- are treated
# literally, and comment lines are left untouched.
#
# Note: this manages the line where the host is the *canonical* (first) name.
# If you also list the host as a trailing alias on some other line, that line
# is left alone -- don't do that (see README).
#
# The temp file lives in the same directory so the final mv is an atomic
# same-filesystem rename.
dir="$(dirname "$HOSTS")"
tmp="$(mktemp "$dir/.hosts.XXXXXX")" || { log "ERROR: mktemp failed"; exit 1; }
awk -v h="$MANAGED_HOST" '$2 != h' "$HOSTS" > "$tmp"
printf '%s\t%s\n' "$target" "$MANAGED_HOST" >> "$tmp"

# Validate before swapping in: the result must be non-empty AND still define
# localhost (IPv4 127.0.0.1 or IPv6 ::1). If anything looks wrong, bail without
# touching the live file.
if [ -s "$tmp" ] && grep -qE '(127\.0\.0\.1|::1)[[:space:]]+localhost' "$tmp"; then
    chmod 644 "$tmp"
    chown root:wheel "$tmp" 2>/dev/null || true
    mv "$tmp" "$HOSTS"
    dscacheutil -flushcache 2>/dev/null || true
    killall -HUP mDNSResponder 2>/dev/null || true
    log "$MANAGED_HOST -> $target ($where)"
else
    log "VALIDATION FAILED; left $HOSTS unchanged"
    rm -f "$tmp"
    exit 1
fi
