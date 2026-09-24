# AGENTS.md — wireguard-ui-stack

Guidance for AI agents and humans working in this repo.

## What this is

A standalone Docker Compose stack: WireGuard VPN with a web UI, fronted by Traefik.
It was split out of `../docker-compose-openvpn-admin` and is meant to run on its own host.

## Files

- `docker-compose.yaml` — base stack, no reverse proxy. Always required.
- `docker-compose.traefik.yaml` — optional overlay adding Traefik and the routing labels.
  Enabled via `COMPOSE_FILE=docker-compose.yaml:docker-compose.traefik.yaml` in `.env`.
- `.env` / `.env.example` — all configuration.

Services:

| Service        | Image                            | File | Role |
|----------------|----------------------------------|------|------|
| `wireguard`    | `linuxserver/wireguard`          | base | The VPN server. `PEERS=0`, peers are managed by the UI. Publishes `$WG_PORT/udp` and the UI on `$WGUI_BIND:$WGUI_PORT` (default localhost only). |
| `wireguard-ui` | `ngoduykhanh/wireguard-ui`       | base | Web UI on port 5000. Runs with `network_mode: service:wireguard`, i.e. inside the wireguard container's network namespace. |
| `ofelia`       | `mcuadros/ofelia`                | base | Cron-in-docker. Every minute runs `scripts/wg-sync.sh` inside `wireguard`: `wg syncconf` from the UI-written `wg0.conf`, then adds missing kernel routes for peer AllowedIPs. |
| `traefik`      | `traefik:v3.6`                   | overlay | Reverse proxy on host network, :80 → :443 redirect, TLS via Let's Encrypt (Cloudflare DNS challenge). Exposes its dashboard under `/traefik/dashboard/` behind basic auth. |

## Non-obvious design decisions — do not "fix" these

- **Traefik labels for the UI are on the `wireguard` service, not on `wireguard-ui`.**
  Because the UI shares the wireguard netns, Traefik must route to the wireguard container's IP.
  Moving the labels to `wireguard-ui` breaks routing. They live in `docker-compose.traefik.yaml`
  under `services.wireguard.labels` and are merged by key with the ofelia labels from the base
  file. Keep the base file free of any `traefik.*` labels.
- **The UI port is published in the base file on `wireguard`** (`$WGUI_BIND:$WGUI_PORT:5000`),
  bound to `127.0.0.1` by default so the stack is usable without Traefik. Do not set
  `WGUI_BIND=0.0.0.0` on a public host when the traefik overlay is active.
- **Traefik uses `network_mode: host`.** That is why there is no `ports:` section on it. The host
  can reach the compose bridge network, so the docker provider still works. Do not add `ports:`.
- **`wireguard-ui` has no `ports:` and no network** — it cannot, because of `network_mode: service:`.
- **ofelia's job** is defined as labels on `wireguard` (`ofelia.job-exec.wg-sync.*`). It executes
  `scripts/wg-sync.sh` (mounted at `/scripts`) inside the wireguard container, which has `wg`,
  `wg-quick` and `ip`.
- **Why the sync script adds routes.** `wg syncconf` only updates the kernel cryptokey table.
  Kernel routes (`ip route add <cidr> dev wg0`) are added by `wg-quick up` only, so a subnet
  added to a peer's AllowedIPs in the UI would be unreachable until a restart. The script
  mirrors wg-quick's `add_route` logic and deliberately skips `/0`. It does not remove stale
  routes, and it does not re-apply `PostUp`/`PostDown`, `Address` or `ListenPort` changes;
  those still need `docker compose restart wireguard`.
- **`depends_on` with `condition: service_healthy`** on `wireguard-ui` matters: the UI reads
  `/etc/wireguard/wg0.conf`, which linuxserver/wireguard generates on first boot.
- The `dynamic/` file provider from the original project was intentionally left out. Everything
  is configured via docker labels.

## Configuration

All configuration is in `.env` (gitignored). `.env.example` lists every variable.

- `WG_HOST` — used both as the WireGuard endpoint (`SERVERURL`) and the Traefik `Host()` rule
  for the UI. Keep them the same unless you have a reason to split.
- `WG_PORT` — UDP port, used for `SERVERPORT` and the published port. Change in one place.
- `WGUI_DEFAULT_CLIENT_ALLOWED_IPS` — default AllowedIPs for new peers. Currently routes only the
  VPN subnet and a LAN, not `0.0.0.0/0`.
- `CF_API_KEY` / `CF_API_EMAIL` — Cloudflare global key for the DNS challenge. Prefer switching to
  `CF_DNS_API_TOKEN` (commented out in compose) when rotating credentials.
- `TRAEFIK_DASHBOARD_USERS` — htpasswd line. If using bcrypt/md5, escape `$` as `$$`.
- `TELEGRAM_TOKEN` — for the UI's Telegram bot that hands out configs.

## State on disk (all gitignored)

- `wireguard/config/` — server keys (`server/privatekey-server`), templates, `wg_confs/wg0.conf`.
  Losing this means all peers must be re-issued.
- `wireguard/ui/db/` — UI users, clients, settings (JSON files).
- `letsencrypt/acme.json` — certificates. Must be mode `600` or Traefik refuses to start.

## Common tasks

```
docker compose -f docker-compose.yaml config -q   # base only
docker compose config -q                          # base + traefik (COMPOSE_FILE from .env)
docker compose up -d
docker compose logs -f traefik wireguard wireguard-ui
docker compose exec wireguard wg show
```

## Rules for agents

- After touching either compose file, validate both variants:
  `docker compose -f docker-compose.yaml config -q` and `docker compose config -q`.
- Never commit `.env`, `wireguard/`, or `letsencrypt/`. Never print secret values from `.env`
  into chat, logs, or commit messages.
- Do not change service names, `container_name`s, or volume paths without a migration note:
  `wireguard-ui`'s DB and wireguard's config are path-bound.
- Keep new settings in `.env` + `.env.example`, not hardcoded in compose.
- This stack and `../docker-compose-openvpn-admin` both run Traefik on the host network. They
  cannot run on the same machine at the same time.
