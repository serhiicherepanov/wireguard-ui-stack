# WireGuard + WireGuard-UI + Traefik

Two compose files:

- `docker-compose.yaml` — base: linuxserver/wireguard, wireguard-ui (shares the wireguard netns),
  ofelia (runs `scripts/wg-sync.sh` every minute: syncs wg0 with the conf written by the UI
  and adds kernel routes for new peer AllowedIPs). UI is bound to
  `$WGUI_BIND:$WGUI_PORT` (default `127.0.0.1:5000`).
- `docker-compose.traefik.yaml` — optional overlay: Traefik on host network, :80/:443,
  Let's Encrypt via HTTP-01 challenge, routes `https://$WG_HOST` to the UI.

## Run

```
cp .env.example .env   # fill in values
docker compose up -d   # COMPOSE_FILE in .env includes the traefik overlay
```

Without Traefik: drop `docker-compose.traefik.yaml` from `COMPOSE_FILE` in `.env`, or run
`docker compose -f docker-compose.yaml up -d`.

- UI: `https://$WG_HOST` (with traefik) or `http://127.0.0.1:5000` (without)
- Traefik dashboard: `https://$WG_HOST/traefik/dashboard/` (basic auth from `TRAEFIK_DASHBOARD_USERS`)
- WireGuard: `$WG_HOST:$WG_PORT/udp`

Changes to peers and their AllowedIPs apply within a minute without a restart. Changes to the
server `Address`, `ListenPort` or `PostUp`/`PostDown` rules still need
`docker compose restart wireguard`.

HTTP-01 requires port 80 to be reachable from the internet on this host and `$WG_HOST` to
resolve to it. No DNS provider credentials are needed.

## State

- `wireguard/config` — server keys and `wg_confs/wg0.conf`
- `wireguard/ui/db` — UI users/clients
- `letsencrypt/acme.json` — certificates (must be mode 600)

All of these are gitignored.
