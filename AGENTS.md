# AGENTS.md — wireguard-ui-stack

Guidance for AI agents and humans working in this repo.

## What this is

A standalone Docker Compose stack: WireGuard VPN with a web UI, fronted by Traefik.
It was split out of `../docker-compose-openvpn-admin` and is meant to run on its own host.

The UI is the **Skyline-core fork of wireguard-ui** (v2 UI, Status/Dashboard/Traffic pages,
passkeys, multi-user). WireGuard itself runs **inside the same container** via `wg-quick`.

## Files

- `docker-compose.yaml` — base stack, no reverse proxy. Always required.
- `docker-compose.traefik.yaml` — optional overlay adding Traefik and the routing labels.
  Enabled via `COMPOSE_FILE=docker-compose.yaml:docker-compose.traefik.yaml` in `.env`.
- `Dockerfile` + `.dockerignore` — builds the fork from git at `WGUI_FORK_REF`.
- `.env` / `.env.example` — all configuration.

Services:

| Service        | Image                        | File    | Role |
|----------------|------------------------------|---------|------|
| `wireguard`    | built locally (`Dockerfile`) | base    | UI on port 5000 **and** the WireGuard tunnel (`wg-quick up` on start). `cap_add: NET_ADMIN`. Publishes `$WG_PORT/udp` and the UI on `$WGUI_BIND:$WGUI_PORT` (default localhost only). |
| `traefik`      | `traefik:v3.6`               | overlay | Reverse proxy on host network, :80 → :443 redirect, TLS via Let's Encrypt (HTTP-01 challenge on the `unsecure` entrypoint). Dashboard under `/traefik/dashboard/` behind basic auth. |

## Non-obvious design decisions — do not "fix" these

- **Single container on purpose.** Peer status in the UI needs netlink access to `wg0`
  (wgctrl) plus `CAP_NET_ADMIN`. Splitting the tunnel into another container brings back the
  `network_mode: service:` dance and a cron sidecar to sync routes. Keep it in one.
- **The image is built, not pulled.** The fork's CI pushes to `ngoduykhanh/wireguard-ui` only
  (it has no own registry), and the fork's `Dockerfile` is stale (`golang:1.21` vs
  `go 1.25` in `go.mod`), so our `Dockerfile` re-implements it with a current toolchain and
  fetches sources with `ADD <git-url>#<ref>`. `.dockerignore` excludes everything but the
  Dockerfile so `.env`, keys and the DB never enter the build context. Bump `WGUI_FORK_REF`
  to upgrade; keep it a full sha or tag.
- **Lifecycle env combination** in the base file:
  `WGUI_MANAGE_START=true` (init.sh does `wg-quick up/down` with the container),
  `WGUI_MANAGE_RESTART=false` (the inotify restarter would double-restart),
  `WGUI_ALLOW_WG_QUICK=true` (Apply config does `wg-quick down/up`, which is what adds kernel
  routes for new AllowedIPs; also enables Stop/Start/Restart on the Server page),
  `WGUI_WG_RESTART_VIA_SYSTEMD=false`, `WGUI_WG_SYNCCONF_AFTER_APPLY=true` (fallback when the
  UI is asked to apply without restart), `WGUI_ALLOW_SYSCTL_IP_FORWARD=false` (forwarding is set
  by compose `sysctls:`). Changing any of these changes how config reaches the kernel.
- **`WGUI_SERVER_*`, `WGUI_ENDPOINT_ADDRESS`, `WGUI_USERNAME/PASSWORD` are first-run defaults
  only.** Once `wireguard/ui/db` exists they are ignored; edit those on the Server page.
- **Traefik labels are on `wireguard`** in the overlay file. Keep the base file free of
  `traefik.*` labels. The overlay also sets `WGUI_WEBAUTHN_RP_ID/ORIGINS` to `WG_HOST` because
  passkeys need a fixed RP ID behind a proxy.
- **The UI port is published in the base file**, bound to `127.0.0.1` by default so the stack is
  usable without Traefik. Do not set `WGUI_BIND=0.0.0.0` on a public host when the traefik
  overlay is active.
- **Traefik uses `network_mode: host`.** That is why there is no `ports:` section on it. Do not
  add `ports:`.
- **Volume paths are inherited from the old two-container layout** (`wireguard/config/wg_confs`
  for `wg0.conf`, `wireguard/ui/db` for the DB) so existing installs need no migration.
  `wireguard/config/{server,templates,coredns}` are dead leftovers of linuxserver/wireguard.
- The host kernel must provide the `wireguard` module (mainline since 5.6). The container does
  not modprobe anything.

## Configuration

All configuration is in `.env` (gitignored). `.env.example` lists every variable.

- `WG_HOST` — WireGuard endpoint for clients (first-run default) and the Traefik `Host()` rule.
- `WG_PORT` — UDP port: published port, first-run listen port, endpoint port. Change in one
  place, then also on the Server page for an existing DB.
- `WG_SERVER_ADDRESS`, `WG_POST_UP`, `WG_POST_DOWN` — first-run defaults for the interface.
- `WGUI_DEFAULT_CLIENT_ALLOWED_IPS` — default AllowedIPs for new peers. Currently routes only the
  VPN subnet, not `0.0.0.0/0`.
- `WGUI_FORK_REF` — commit sha/tag of the fork to build.
- `ACME_EMAIL` — Let's Encrypt account email. HTTP-01: port 80 must be publicly reachable and
  `WG_HOST` must resolve here. No wildcards.
- `TRAEFIK_DASHBOARD_USERS` — htpasswd line. If using bcrypt/md5, escape `$` as `$$`.
- `TELEGRAM_TOKEN` — for the UI's Telegram bot that hands out configs.

## State on disk (all gitignored)

- `wireguard/ui/db/` — UI users, clients, **server keypair**, settings (JSON). Source of truth;
  losing this means all peers must be re-issued.
- `wireguard/config/wg_confs/wg0.conf` — rendered from the DB by the UI. Regenerable.
- `letsencrypt/acme.json` — certificates. Must be mode `600` or Traefik refuses to start.

## Common tasks

```
docker compose -f docker-compose.yaml config -q   # base only
docker compose config -q                          # base + traefik (COMPOSE_FILE from .env)
docker compose build                              # (re)build the fork image
docker compose up -d
docker compose logs -f wireguard traefik
docker compose exec wireguard wg show
```

## Rules for agents

- After touching either compose file, validate both variants:
  `docker compose -f docker-compose.yaml config -q` and `docker compose config -q`.
- After touching `Dockerfile`, run `docker compose -f docker-compose.yaml build`.
- Never commit `.env`, `wireguard/`, or `letsencrypt/`. Never print secret values from `.env`
  or `wireguard/ui/db/server/keypair.json` into chat, logs, or commit messages.
- Do not change service names, `container_name`s, or volume paths without a migration note
  (the service was `wireguard-ui` until Sep 2026; the volume paths still predate that):
  the DB and `wg0.conf` are path-bound.
- Keep new settings in `.env` + `.env.example`, not hardcoded in compose.
- This stack and `../docker-compose-openvpn-admin` both run Traefik on the host network. They
  cannot run on the same machine at the same time.
