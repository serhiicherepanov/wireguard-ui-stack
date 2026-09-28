#!/bin/bash
# Wrapper around the fork's init.sh.
#
# init.sh runs `wg-quick up <conf>` before starting the UI. On the very first start the UI
# has not rendered wg0.conf yet, so the tunnel silently stays down until a restart or an
# "Apply config". Fix: if the conf is missing, run the UI once just long enough for it to
# render the file, then hand over to init.sh as usual.
set -u

conf="$(jq -r .config_file_path db/server/global_settings.json 2>/dev/null || true)"
[ -n "$conf" ] && [ "$conf" != "null" ] || conf="${WGUI_CONFIG_FILE_PATH:-/etc/wireguard/wg0.conf}"

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
