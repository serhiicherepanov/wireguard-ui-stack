#!/bin/sh
# Reconcile the live wg0 interface with /config/wg_confs/wg0.conf written by wireguard-ui.
#
# 1. `wg syncconf` applies peer add/remove/AllowedIPs changes to the kernel cryptokey table
#    without dropping existing sessions.
# 2. syncconf does NOT touch kernel routes. wg-quick only adds `ip route ... dev wg0` on `up`,
#    so a new subnet in a peer's AllowedIPs would be unreachable until a restart. This script
#    adds the missing routes the same way wg-quick does.
#
# Run by ofelia every minute inside the `wireguard` container. Safe to run manually:
#   docker compose exec wireguard sh /scripts/wg-sync.sh
set -eu

CONF=${WG_CONF:-/config/wg_confs/wg0.conf}
IFACE=${WG_IFACE:-wg0}

STRIPPED=$(mktemp)
LIVE=$(mktemp)
trap 'rm -f "$STRIPPED" "$LIVE"' EXIT

wg-quick strip "$CONF" > "$STRIPPED"
wg showconf "$IFACE" > "$LIVE"

if ! cmp -s "$STRIPPED" "$LIVE"; then
  echo "wg-sync: applying $CONF to $IFACE"
  wg syncconf "$IFACE" "$STRIPPED"
fi

# Ensure a kernel route exists for every AllowedIPs entry of every peer.
# Mirrors wg-quick's add_route(): skip if an existing route on the interface already covers it.
# /0 is skipped on purpose: wg-quick handles default routes via fwmark/policy routing,
# and a plain `ip route add 0.0.0.0/0 dev wg0` would break the container's uplink.
wg show "$IFACE" allowed-ips | awk '{ for (i = 2; i <= NF; i++) print $i }' | while read -r cidr; do
  case "$cidr" in
    "(none)"|*/0) continue ;;
    *:*) fam=-6 ;;
    *)   fam=-4 ;;
  esac
  if [ -z "$(ip $fam route show dev "$IFACE" match "$cidr" 2>/dev/null)" ]; then
    echo "wg-sync: adding route $cidr dev $IFACE"
    ip $fam route add "$cidr" dev "$IFACE"
  fi
done
