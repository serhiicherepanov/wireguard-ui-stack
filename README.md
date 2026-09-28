# WireGuard + WireGuard-UI (Skyline-core fork) + Traefik

One container runs both the WireGuard tunnel (`wg-quick`) and the web UI, so the UI sees the
live interface and shows peer status (handshakes, transfer, connected/offline) on its Status,
Dashboard and Traffic pages.

The UI is the [Skyline-core fork of wireguard-ui](https://github.com/Skyline-core/wireguard-ui).
It publishes no image, so it is built locally from a pinned commit (see `Dockerfile`).

Two compose files (one service `wireguard` = tunnel + UI, container name `wireguard`):

- `docker-compose.yaml` — base: `wireguard` (UI fork + wg-quick, `NET_ADMIN`). UI is bound to
  `$WGUI_BIND:$WGUI_PORT` (default `127.0.0.1:5000`), WireGuard on `$WG_PORT/udp`.
- `docker-compose.traefik.yaml` — optional overlay: Traefik on host network, :80/:443,
  Let's Encrypt via HTTP-01 challenge, routes `https://$WG_HOST` to the UI.

## Run

```
cp .env.example .env   # fill in values
docker compose build   # builds the fork image (first time and after bumping WGUI_FORK_REF)
docker compose up -d   # COMPOSE_FILE in .env includes the traefik overlay
```

Without Traefik: drop `docker-compose.traefik.yaml` from `COMPOSE_FILE` in `.env`, or run
`docker compose -f docker-compose.yaml up -d`.

- UI: `https://$WG_HOST` (with traefik) or `http://127.0.0.1:5000` (without)
- Traefik dashboard: `https://$WG_HOST/traefik/dashboard/` (basic auth from `TRAEFIK_DASHBOARD_USERS`)
- WireGuard: `$WG_HOST:$WG_PORT/udp`

## How changes are applied

- Container start/stop: `wg-quick up/down` (`WGUI_MANAGE_START=true`).
- **Apply config** in the UI rewrites `wg0.conf` and restarts the tunnel with `wg-quick`
  (`WGUI_ALLOW_WG_QUICK=true`). That covers peers, AllowedIPs (kernel routes included),
  server address, port and PostUp/PostDown. Sessions drop for about a second and reconnect.
- The Server page has Stop / Start / Restart buttons.
- No cron or sidecar containers anymore.

HTTP-01 requires port 80 to be reachable from the internet on this host and `$WG_HOST` to
resolve to it. No DNS provider credentials are needed.

## Upgrading the fork

Set `WGUI_FORK_REF` in `.env` to a new commit sha or tag, then:

```
docker compose build --pull && docker compose up -d
```

## State

- `wireguard/ui/db` — UI users, clients, server keypair, settings. **Source of truth.**
- `wireguard/config/wg_confs/wg0.conf` — rendered by the UI, read by wg-quick.
- `letsencrypt/acme.json` — certificates (must be mode 600)

All of these are gitignored.

## Migrating from the previous linuxserver/wireguard + ofelia layout

Nothing to move: the UI DB and `wg_confs/wg0.conf` are mounted from the same paths. The old
`wireguard/config/{server,templates,coredns}` directories belonged to linuxserver/wireguard
and are no longer read; delete them when convenient. Run

```
docker compose down --remove-orphans   # stops old wireguard / ofelia containers
docker compose build && docker compose up -d
```
