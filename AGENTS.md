# AGENTS.md — wireguard-ui-stack

Guidance for AI agents and humans working in this repo.

## What this is

A standalone Docker Compose stack: WireGuard VPN with a web UI, fronted by Traefik, plus a
Seafile CE server that is reachable only through the tunnel.
It was split out of `../docker-compose-openvpn-admin` and is meant to run on its own host.

The UI is the **Skyline-core fork of wireguard-ui** (v2 UI, Status/Dashboard/Traffic pages,
passkeys, multi-user). WireGuard itself runs **inside the same container** via `wg-quick`,
and so does **Seafile** (the official `seafileltd/seafile-mc` image is the runtime base).

## Files

- `docker-compose.yaml` — base stack, no reverse proxy. Always required.
- `docker-compose.traefik.yaml` — optional overlay adding Traefik and the routing labels.
  Enabled via `COMPOSE_FILE=docker-compose.yaml:docker-compose.traefik.yaml` in `.env`.
- `Dockerfile` + `.dockerignore` + `entrypoint.sh` — builds the fork from git at `WGUI_FORK_REF`
  and layers it onto the Seafile image (`SEAFILE_IMAGE`). `entrypoint.sh` is the `wireguard-ui`
  runit service inside that image.
- `nginx-ui-locations.sh` — my_init.d step baked into the image; renders the nginx `location`
  that puts the UI under `WGUI_BASE_PATH` on Seafile's nginx (one wg-only domain for both).
- `assets/wireguard.svg` — logo the fork's templates reference but do not ship; baked into the
  image at build time (embedded `assets/` dir).
- `.env` / `.env.example` — all configuration.

Services:

| Service        | Image                        | File    | Role |
|----------------|------------------------------|---------|------|
| `wireguard`    | built locally (`Dockerfile`) | base    | UI on port 5000 (under `$WGUI_BASE_PATH`), the WireGuard tunnel (`wg-quick up` on start) **and** Seafile (nginx :80 → `/` seahub/seaf-server, `$WGUI_BASE_PATH` → UI). `cap_add: NET_ADMIN`. Publishes `$WG_PORT/udp` and the UI on `$WGUI_BIND:$WGUI_PORT` (default localhost only). Port 80 is not published and is firewalled to `wg0`. |
| `seafile-db`   | `mariadb:10.11`              | base    | Seafile database, `internal` network only. |
| `seafile-memcached` | `memcached:1.6`         | base    | Seafile cache, `internal` network only, alias `memcached`. |
| `traefik`      | `traefik:v3.6`               | overlay | Reverse proxy on host network, :80 → :443 redirect, TLS via Let's Encrypt (HTTP-01 challenge on the `unsecure` entrypoint). Dashboard under `/traefik/dashboard/` behind basic auth. Routes the UI only (`https://$WG_HOST$WGUI_BASE_PATH`, `/` redirects there), never Seafile. |

## Non-obvious design decisions — do not "fix" these

- **Single container on purpose.** Peer status in the UI needs netlink access to `wg0`
  (wgctrl) plus `CAP_NET_ADMIN`. Splitting the tunnel into another container brings back the
  `network_mode: service:` dance and a cron sidecar to sync routes. Keep it in one.
- **The image is built, not pulled.** The fork's CI pushes to `ngoduykhanh/wireguard-ui` only
  (it has no own registry), and the fork's `Dockerfile` is stale (`golang:1.21` vs
  `go 1.25` in `go.mod`), so our `Dockerfile` re-implements it with a current toolchain and
  fetches sources with a shallow `git fetch` (works with the legacy builder too). `.dockerignore`
  excludes everything but the Dockerfile, `entrypoint.sh` and the logo so `.env`, keys and
  the DB never enter the build context. Bump `WGUI_FORK_REF` to upgrade; keep it a full sha
  or tag.
- **Seafile runs inside the `wireguard` container, on top of the official image.** The
  requirement is "Seafile only via the VPN address". Its nginx must therefore listen in the
  network namespace that owns `wg0`, and the runtime stage of our `Dockerfile` is
  `FROM seafileltd/seafile-mc` (Ubuntu 22.04, phusion `my_init` + runit) with
  `wireguard-tools`, `iptables`, `jq` and the fork binary added. `my_init` stays PID 1 and
  CMD is Seafile's own `/scripts/enterpoint.sh`; the tunnel + UI run as the runit service
  `/etc/service/wireguard-ui/run` → `/app/entrypoint.sh` → the fork's `init.sh`. runsv
  restarts the UI if it dies; on container stop `sv force-stop` sends SIGTERM and `init.sh`
  runs `wg-quick down`. (The alternative, a separate Seafile container with
  `network_mode: service:wireguard`, breaks on every restart of `wireguard` — the exact
  dance the single-container design avoids.)
- **Why Traefik does not route Seafile, even on its own domain.** Traefik is on the host
  network and listens on the public interface; `wg0` lives inside the `wireguard` container.
  A request to `SEAFILE_HOST` (resolving to the wg address) arrives inside the container and
  never passes Traefik. A Traefik `Host()` router would require the name to resolve to the
  public IP, i.e. make Seafile internet-reachable; an `ipAllowList` cannot save that because
  peers' traffic to the public IP leaves the tunnel (AllowedIPs is the VPN subnet only). The
  reverse proxy on the wg side is therefore Seafile's own nginx.
- **One wg-only domain for both, UI under `WGUI_BASE_PATH` (default `/wg`).** Seafile does not
  support a sub-path (nginx template, `FILE_SERVER_ROOT`, seafdav and the clients assume `/`),
  the fork does (`BASE_PATH`). So Seafile keeps `/` and the UI moves to `/wg`: `BASE_PATH` is
  process-wide, hence the UI is at `/wg` on every entry (Seafile nginx, Traefik, `:5000`).
  Mechanics: the Dockerfile adds `include /etc/nginx/wireguard-ui.locations;` to the image's
  `seafile.nginx.conf.template`; `nginx-ui-locations.sh` (my_init.d, before runit starts nginx)
  renders that file from `BASE_PATH` on every start. Because Seafile persists the rendered
  server block in `seafile/data/nginx/conf/seafile.nginx.conf`, an install rendered before this
  change needs that file deleted once. Keep `WGUI_BASE_PATH` non-empty while the Traefik overlay
  is active: its `/` → `/wg` redirect would loop on an empty value (the nginx side just skips
  the location). Passkeys work only via the HTTPS Traefik URL (WebAuthn needs a secure
  context; `http://$SEAFILE_HOST/wg` gets password login).
- **"Seafile only via wg0" is enforced with iptables in `entrypoint.sh`**, not by nginx
  binding: the server's wg address lives in the UI DB and may change. The rules are
  `INPUT -p tcp --dport 80 -i lo ACCEPT` then `! -i <wg-if> DROP`, installed idempotently
  before `wg-quick up` (the interface name is derived from `config_file_path`). Port 80 is
  also not published and Traefik has no router for it. Only IPv4: the Seafile nginx listens on
  IPv4 only and the compose networks have no IPv6.
- **Seafile first-run defaults**: `SEAFILE_SERVER_HOSTNAME` (= `SEAFILE_HOST`), admin
  email/password and `DB_ROOT_PASSWD` are consumed only when `seafile/data/seafile/` does not
  exist yet. The hostname ends up in `seahub_settings.py` (`SERVICE_URL`, `FILE_SERVER_ROOT`)
  and in the persisted `seafile/data/nginx/conf/seafile.nginx.conf` (`server_name`; it is
  also nginx's default server, so the bare wg IP answers too, but generated links use the name).
  `SEAFILE_SERVER_LETSENCRYPT` is hardcoded `false`: plain HTTP over the tunnel, HTTP-01
  cannot reach a wg-only host anyway.
- **`memcached` network alias is required**: Seafile's bootstrap hardcodes
  `memcached:11211` into `seahub_settings.py`. `DB_HOST=seafile-db` is configurable and is
  written into `seafile.conf` on first run.
- **The `wireguard` healthcheck covers the UI and the tunnel only.** Traefik drops unhealthy
  containers from routing, so a Seafile problem must not take the VPN admin UI offline.
- **Stop timing**: `stop_grace_period: 60s` because `my_init` stops seaf-server/seahub,
  nginx, cron and then the tunnel; the compose default (10s) ends in SIGKILL.
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
- `WGUI_BASE_PATH` — URL prefix of the UI on every entry point (default `/wg`). Non-empty.
- `ACME_EMAIL` — Let's Encrypt account email. HTTP-01: port 80 must be publicly reachable and
  `WG_HOST` must resolve here. No wildcards.
- `TRAEFIK_DASHBOARD_USERS` — htpasswd line. If using bcrypt/md5, escape `$` as `$$`.
- `TELEGRAM_TOKEN` — for the UI's Telegram bot that hands out configs.
- `SEAFILE_HOST` — Seafile domain (plain HTTP). For VPN clients it must resolve to the
  server's wg address (`WG_SERVER_ADDRESS` without prefix, e.g. `10.13.13.1`); a public A
  record pointing at that private IP is fine. First-run default (see above).
- `SEAFILE_DB_ROOT_PASSWORD`, `SEAFILE_ADMIN_EMAIL`, `SEAFILE_ADMIN_PASSWORD` — MariaDB root
  and the initial Seafile admin. First-run defaults.
- `SEAFILE_IMAGE` — runtime base image (default `seafileltd/seafile-mc:11.0-latest`).
  Seafile upgrades between minor versions are handled by the image's own `upgrade.py` on start;
  read the Seafile manual before bumping a major.

## State on disk (all gitignored)

- `wireguard/ui/db/` — UI users, clients, **server keypair**, settings (JSON). Source of truth;
  losing this means all peers must be re-issued.
- `wireguard/config/wg_confs/wg0.conf` — rendered from the DB by the UI. Regenerable.
- `letsencrypt/acme.json` — certificates. Must be mode `600` or Traefik refuses to start.
- `seafile/data/` — Seafile `/shared`: `seafile/conf/` (seafile.conf, seahub_settings.py with
  the DB user password and secret key), `seafile/seafile-data/` (library blocks), `seahub-data/`,
  logs, `nginx/conf/seafile.nginx.conf`. Source of truth for Seafile together with the DB.
- `seafile/db/` — MariaDB data dir (`ccnet_db`, `seafile_db`, `seahub_db`).

## Common tasks

```
docker compose -f docker-compose.yaml config -q   # base only
docker compose config -q                          # base + traefik (COMPOSE_FILE from .env)
docker compose build                              # (re)build the fork image
docker compose up -d
docker compose logs -f wireguard traefik
docker compose exec wireguard wg show
docker compose exec wireguard iptables -S INPUT       # expect the two tcp/80 rules first
docker compose exec wireguard sv status /etc/service/*  # nginx, cron, wireguard-ui
docker compose exec wireguard curl -sI -H "Host: $SEAFILE_HOST" http://127.0.0.1/   # Seafile up?
docker compose exec wireguard curl -sI -H "Host: $SEAFILE_HOST" http://127.0.0.1/wg/login  # UI via nginx
docker compose logs -f wireguard                      # Seafile + UI + wg-quick, one stream
```

## Rules for agents

- After touching either compose file, validate both variants:
  `docker compose -f docker-compose.yaml config -q` and `docker compose config -q`.
- After touching `Dockerfile`, run `docker compose -f docker-compose.yaml build`.
- Never commit `.env`, `wireguard/`, `letsencrypt/` or `seafile/` contents. Never print secret
  values from `.env`, `wireguard/ui/db/server/keypair.json` or `seafile/data/seafile/conf/`
  into chat, logs, or commit messages.
- Do not publish Seafile's port 80, add a Traefik router for it, bind it to `0.0.0.0` on the
  host or remove the iptables rules in `entrypoint.sh`: wg-only access is the requirement.
- After bumping `SEAFILE_IMAGE`, check that the `sed` in the Dockerfile still hits the nginx
  template (the build greps for the include and fails otherwise).
- Do not replace the image's `CMD` (`my_init` + Seafile) with `entrypoint.sh`; the UI runs as
  a runit service. If the fork's `init.sh` changes its signal handling, re-check that
  `sv force-stop` still results in `wg-quick down`.
- Do not change service names, `container_name`s, or volume paths without a migration note
  (the service was `wireguard-ui` until Sep 2026; the volume paths still predate that):
  the DB and `wg0.conf` are path-bound.
- Keep new settings in `.env` + `.env.example`, not hardcoded in compose.
- This stack and `../docker-compose-openvpn-admin` both run Traefik on the host network. They
  cannot run on the same machine at the same time.
