#!/bin/sh
# Print the SSH host-key fingerprint to pin in `config` as HOST_KEY_FP.
#
# Usage: ./capture-fingerprint.sh <host-or-ip> [keytype] [port]
#   e.g. ./capture-fingerprint.sh 192.168.1.10
#        ./capture-fingerprint.sh myhost.tailnet.ts.net ed25519 22
#
# A host key is the same regardless of which IP/interface you reach the host
# on, so you can capture it over Tailscale and it will still match on the LAN.
set -eu

HOST="${1:?usage: ./capture-fingerprint.sh <host-or-ip> [keytype] [port]}"
TYPE="${2:-ed25519}"
PORT="${3:-22}"

fp="$(ssh-keyscan -T 5 -p "$PORT" -t "$TYPE" "$HOST" 2>/dev/null \
      | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"

if [ -z "$fp" ]; then
    echo "Could not fetch a $TYPE host key from $HOST:$PORT" >&2
    echo "Is the host reachable and running SSH? Try a different keytype/port." >&2
    exit 1
fi

echo "$fp"
echo "" >&2
echo "Put this in your config:  HOST_KEY_FP=\"$fp\"" >&2
