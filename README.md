# WireGuard + WireGuard-UI (Skyline-core fork) + Traefik + Seafile

One container runs the WireGuard tunnel (`wg-quick`), the web UI and a Seafile CE server.
The UI sees the live interface and shows peer status (handshakes, transfer, connected/offline)
on its Status, Dashboard and Traffic pages. Seafile sits in the same network namespace so it
can be served **only to VPN peers**: its port 80 is firewalled to `wg0` and never published.

The UI is the [Skyline-core fork of wireguard-ui](https://github.com/Skyline-core/wireguard-ui).
It publishes no image, so this repo builds its own: GitHub Actions builds `Dockerfile` on
every push to `main` and publishes `ghcr.io/serhiicherepanov/wireguard-ui-stack:latest`
(plus a `:sha-…` tag per commit). The server pulls it; `docker compose build` still works
for a local build.

Two compose files (one service `wireguard` = tunnel + UI + Seafile, container name `wireguard`):

- `docker-compose.yaml` — base: `wireguard` (UI fork + wg-quick + Seafile, `NET_ADMIN`), plus
  `seafile-db` (MariaDB) and `seafile-memcached` on an internal network. UI is bound to
  `$WGUI_BIND:$WGUI_PORT` (default `127.0.0.1:5000`), WireGuard on `$WG_PORT/udp`.
- `docker-compose.traefik.yaml` — optional overlay: Traefik on host network, :80/:443,
  Let's Encrypt via HTTP-01 challenge, routes `https://$WG_HOST/wg` to the UI.

## Run

```
cp .env.example .env            # fill in values
docker compose pull wireguard   # CI-built image from GHCR (or: docker compose build)
docker compose up -d            # COMPOSE_FILE in .env includes the traefik overlay
```

Updating to the latest build: `docker compose pull wireguard && docker compose up -d`.
If the GHCR package is private, `docker login ghcr.io` with a token that has `read:packages`
first.

Without Traefik: drop `docker-compose.traefik.yaml` from `COMPOSE_FILE` in `.env`, or run
`docker compose -f docker-compose.yaml up -d`.

- UI: `https://$WG_HOST/wg` (with traefik; `/` redirects there), `http://$SEAFILE_HOST/wg`
  (through the tunnel) or `http://127.0.0.1:5000/wg` (on the host). The prefix is
  `WGUI_BASE_PATH`.
- Traefik dashboard: `https://$WG_HOST/traefik/dashboard/` (basic auth from `TRAEFIK_DASHBOARD_USERS`)
- WireGuard: `$WG_HOST:$WG_PORT/udp`
- Seafile: `http://$SEAFILE_HOST/` **from a connected VPN client only**. First start takes a
  couple of minutes (DB setup); watch `docker compose logs -f wireguard`.

## Seafile

- Based on the [official Seafile CE docker setup](https://manual.seafile.com/11.0/docker/deploy_seafile_with_docker/):
  same image (`seafileltd/seafile-mc:11.0-latest`), same MariaDB/memcached companions, same
  environment variables. The difference is that the Seafile image is the base of the
  `wireguard` image (see `Dockerfile`) instead of a separate container.
- Access is wg-only: `entrypoint.sh` drops tcp/80 on every interface but `wg0` (and `lo`),
  the port is not published, Traefik does not route it. Plain HTTP; the tunnel encrypts.
  Traefik cannot route it even on a separate domain: it listens on the public interface,
  while `wg0` lives inside the container, so a request to the wg address never reaches it.
- One domain for both: Seafile's nginx serves `/` itself and proxies `$WGUI_BASE_PATH`
  (default `/wg`) to the UI, so `http://$SEAFILE_HOST/wg` is the wg-only UI entry. Seafile
  itself cannot live under a sub-path, which is why the UI is the one that moves. Passkeys
  need HTTPS and therefore only work via the Traefik URL; password login works everywhere.
- `SEAFILE_HOST` must resolve, on the clients, to the server's WireGuard address
  (`WG_SERVER_ADDRESS` without the `/24`, e.g. `10.13.13.1`). A public DNS A record with that
  private IP works; so does a hosts-file entry. `http://10.13.13.1/` answers as well, but
  upload/download/share links are generated with `SEAFILE_HOST`, so the name must resolve.
- `SEAFILE_HOST`, the admin account and `SEAFILE_DB_ROOT_PASSWORD` are read on the first start
  only. To change the host later edit `SERVICE_URL`/`FILE_SERVER_ROOT` in
  `seafile/data/seafile/conf/seahub_settings.py`, delete
  `seafile/data/nginx/conf/seafile.nginx.conf` and restart.
- Clients (desktop sync, mobile) use the same `http://$SEAFILE_HOST` and need the VPN up.

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

Change the `WGUI_FORK_REF` default in `docker-compose.yaml` to a new commit sha or tag and push
to `main`; CI publishes the new image. Then on the server:

```
docker compose pull wireguard && docker compose up -d
```

## State

- `wireguard/ui/db` — UI users, clients, server keypair, settings. **Source of truth.**
- `wireguard/config/wg_confs/wg0.conf` — rendered by the UI, read by wg-quick.
- `letsencrypt/acme.json` — certificates (must be mode 600)
- `seafile/data` — Seafile config, libraries, logs; `seafile/db` — MariaDB data

All of these are gitignored.

## Migrating from the previous linuxserver/wireguard + ofelia layout

Nothing to move: the UI DB and `wg_confs/wg0.conf` are mounted from the same paths. The old
`wireguard/config/{server,templates,coredns}` directories belonged to linuxserver/wireguard
and are no longer read; delete them when convenient. Run

```
docker compose down --remove-orphans   # stops old wireguard / ofelia containers
docker compose build && docker compose up -d
```
