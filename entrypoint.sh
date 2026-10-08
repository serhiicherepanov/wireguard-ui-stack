#!/bin/bash
# Wrapper around the fork's init.sh. Runs as the `wireguard-ui` runit service (see Dockerfile),
# so it may be started more than once per container lifetime: keep everything idempotent.
#
# 1. Seafile's nginx listens on :80 in this network namespace. Only VPN peers may reach it:
#    drop :80 on every interface except the tunnel (and lo). iptables matches interface
#    names as strings, so the rule can be installed before wg0 exists.
# 2. init.sh runs `wg-quick up <conf>` before starting the UI. On the very first start the UI
#    has not rendered wg0.conf yet, so the tunnel silently stays down until a restart or an
#    "Apply config". Fix: if the conf is missing, run the UI once just long enough for it to
#    render the file, then hand over to init.sh as usual.
set -u

conf="$(jq -r .config_file_path db/server/global_settings.json 2>/dev/null || true)"
[ -n "$conf" ] && [ "$conf" != "null" ] || conf="${WGUI_CONFIG_FILE_PATH:-/etc/wireguard/wg0.conf}"
wg_if="$(basename "$conf" .conf)"

# --- 1. Seafile reachable only through the tunnel ---
rule() { iptables -C INPUT "$@" 2>/dev/null || iptables -I INPUT 1 "$@"; }
# Inserted at position 1 in this order, so the final chain reads: lo ACCEPT, !wg DROP.
rule -p tcp --dport 80 ! -i "$wg_if" -j DROP
rule -p tcp --dport 80 -i lo -j ACCEPT
echo "entrypoint: tcp/80 (Seafile) accepted only on $wg_if and lo"

# --- 2. First-run: render the config before init.sh needs it ---
if [ ! -f "$conf" ]; then
  echo "entrypoint: $conf does not exist yet, starting the UI once to render it"
  ./wg-ui >/dev/null 2>&1 &
  ui=$!
  for _ in $(seq 1 30); do
    [ -f "$conf" ] && break
    sleep 1
  done
  kill "$ui" 2>/dev/null
  wait "$ui" 2>/dev/null
  [ -f "$conf" ] && echo "entrypoint: rendered $conf" || echo "entrypoint: WARNING $conf still missing, tunnel will not start"
fi

exec ./init.sh
