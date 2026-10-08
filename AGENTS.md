# AGENTS.md — wireguard-ui-stack

Guidance for AI agents and humans working in this repo.

## What this is

A standalone Docker Compose stack: WireGuard VPN with a web UI plus a Seafile CE server,
both fronted by Traefik on one domain (Seafile at `/`, the UI at `/wg`).
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
  that puts the UI under `WGUI_BASE_PATH` on Seafile's nginx (`:80` serves both).
- `patch-seafile-bootstrap.py` — build-time patch of the image's first-run bootstrap
  (`SERVICE_URL` with https, `CSRF_TRUSTED_ORIGINS`), see design notes.
- `assets/wireguard.svg` — logo the fork's templates reference but do not ship; baked into the
  image at build time (embedded `assets/` dir).
- `.env` / `.env.example` — all configuration.
- `.github/workflows/build-image.yml` — builds the image on every push to `main` with
  `docker buildx bake` on `docker-compose.yaml` and pushes `ghcr.io/<owner>/<repo>:latest`
  and `:sha-<short>`.

Services:

| Service        | Image                        | File    | Role |
|----------------|------------------------------|---------|------|
| `wireguard`    | `ghcr.io/…/wireguard-ui-stack` (CI-built from `Dockerfile`) | base    | UI on port 5000 (under `$WGUI_BASE_PATH`), the WireGuard tunnel (`wg-quick up` on start) **and** Seafile (nginx :80 → `/` seahub/seaf-server, `$WGUI_BASE_PATH` → UI). `cap_add: NET_ADMIN`. Publishes `$WG_PORT/udp` and the UI on `$WGUI_BIND:$WGUI_PORT` (default localhost only). Port 80 is not published; Traefik reaches it over the bridge. |
| `seafile-db`   | `mariadb:10.11`              | base    | Seafile database, `internal` network only. |
| `seafile-memcached` | `memcached:1.6`         | base    | Seafile cache, `internal` network only, alias `memcached`. |
| `traefik`      | `traefik:v3.6`               | overlay | Reverse proxy on host network, :80 → :443 redirect, TLS via Let's Encrypt (HTTP-01 challenge on the `unsecure` entrypoint). Dashboard under `/traefik/dashboard/` behind basic auth. One router: `Host($WG_HOST)` (and `$SEAFILE_HOST` if set) → container nginx :80. |

## Non-obvious design decisions — do not "fix" these

- **Single container on purpose.** Peer status in the UI needs netlink access to `wg0`
  (wgctrl) plus `CAP_NET_ADMIN`. Splitting the tunnel into another container brings back the
  `network_mode: service:` dance and a cron sidecar to sync routes. Keep it in one.
- **The image is ours, built by CI, pulled by the server.** The fork's CI pushes to
  `ngoduykhanh/wireguard-ui` only (it has no own registry), and the fork's `Dockerfile` is
  stale (`golang:1.21` vs `go 1.25` in `go.mod`), so our `Dockerfile` re-implements it with
  a current toolchain and fetches sources with a shallow `git fetch` (works with the legacy
  builder too). `.dockerignore` excludes everything but the Dockerfile, the two scripts and
  the logo so `.env`, keys and the DB never enter the build context. GitHub Actions builds it
  on every push to `main` via `buildx bake` **reading `docker-compose.yaml`**, so the build
  args (the `WGUI_FORK_REF` pin, `SEAFILE_IMAGE`) have exactly one home: the compose
  defaults. The workflow sets dummy `SEAFILE_*` values only to satisfy the `${VAR:?}`
  checks during interpolation. `docker compose build` still works locally and produces the
  same tag. Bump `WGUI_FORK_REF` in the compose default to upgrade; keep it a full sha or
  tag. `WG_IMAGE` in `.env` pins the server to a specific `:sha-…` tag if wanted.
- **Seafile runs inside the `wireguard` container, on top of the official image.** One image
  to build in CI, ship and run; its nginx serves Seafile and proxies the UI, so the container
  has a single HTTP entry (:80) next to the UI's own :5000. The runtime stage of our
  `Dockerfile` is `FROM seafileltd/seafile-mc` (Ubuntu 22.04, phusion `my_init` + runit) with
  `wireguard-tools`, `iptables`, `jq` and the fork binary added. `my_init` stays PID 1 and
  CMD is Seafile's own `/scripts/enterpoint.sh`; the tunnel + UI run as the runit service
  `/etc/service/wireguard-ui/run` → `/app/entrypoint.sh` → the fork's `init.sh`. runsv
  restarts the UI if it dies; on container stop `sv force-stop` sends SIGTERM and `init.sh`
  runs `wg-quick down`.
- **One domain, Seafile at `/`, UI under `WGUI_BASE_PATH` (default `/wg`).** Seafile does not
  support a sub-path (nginx template, `FILE_SERVER_ROOT`, seafdav and the clients assume `/`),
  the fork does (`BASE_PATH`). `BASE_PATH` is process-wide, hence the UI is at `/wg` on every
  entry (Traefik, Seafile nginx, `:5000`). The split lives in one place, the container's
  nginx: Traefik has a single router that sends the whole domain to `:80`. The Dockerfile adds
  `include /etc/nginx/wireguard-ui.locations;` to the image's `seafile.nginx.conf.template`
  and `nginx-ui-locations.sh` (my_init.d, before runit starts nginx) renders that file from
  `BASE_PATH` on every start, so the same split works over the tunnel and without Traefik.
  The location forwards Traefik's `X-Forwarded-Proto` to the UI instead of nginx's own
  `$scheme` (http), because passkeys compare origins. Seafile
  persists the rendered server block in `seafile/data/nginx/conf/seafile.nginx.conf`; an
  install rendered before this change needs that file deleted once. Keep `WGUI_BASE_PATH`
  non-empty: Seafile owns `/` (the nginx side just skips the location on an empty value).
- **TLS ends at Traefik; Seafile must still write https URLs and trust the https origin.**
  The overlay sets `FORCE_HTTPS_IN_CONF=true` (the official knob). Two things the image gets
  wrong on first run, fixed by `patch-seafile-bootstrap.py` (run at build time against
  `/scripts/bootstrap.py`; the build fails if its anchor line is gone):
  1. `bootstrap.py` runs `setup-seafile-mysql.py` with a hand-built `env=`, so
     `FORCE_HTTPS_IN_CONF` never reaches it and `SERVICE_URL` comes out as `http://` while
     `FILE_SERVER_ROOT` is `https://`. The patch re-states `SERVICE_URL` later in the file.
  2. Seahub sees plain HTTP from its nginx, and Django 4 (Seafile 11) rejects every POST whose
     `Origin` is `https://…` unless it is in `CSRF_TRUSTED_ORIGINS`, which the image never
     writes. Without it the Seafile login returns 403. The patch appends it.
- **Seafile first-run defaults**: `SEAFILE_SERVER_HOSTNAME` (= `SEAFILE_HOST`, default
  `WG_HOST`), `FORCE_HTTPS_IN_CONF`, admin email/password and `DB_ROOT_PASSWD` are consumed
  only when `seafile/data/seafile/` does not exist yet. The hostname ends up in
  `seahub_settings.py` (`SERVICE_URL`, `FILE_SERVER_ROOT`, `CSRF_TRUSTED_ORIGINS`) and in the
  persisted nginx server block (`server_name`; it is also nginx's default server).
  `SEAFILE_SERVER_LETSENCRYPT` is hardcoded `false`: certificates are Traefik's job.
- **`memcached` network alias is required**: Seafile's bootstrap hardcodes
  `memcached:11211` into `seahub_settings.py`. `DB_HOST=seafile-db` is configurable and is
  written into `seafile.conf` on first run.
- **The `wireguard` healthcheck covers the UI and the tunnel only.** Traefik drops unhealthy
  containers from routing (both routers, since both point at this container), so the check
  deliberately does not depend on Seafile's slower start.
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
- **Two HTTP ports are published in the base file**, both bound to `127.0.0.1` by default so
  the stack is usable without Traefik behind any other proxy: `$HTTP_PORT` (8080) → nginx
  (Seafile at `/`, UI at `/wg`; this is what an external proxy should target) and
  `$WGUI_PORT` (5000) → the UI directly (kept for compatibility, same `BASE_PATH`). Do not bind
  them to `0.0.0.0` on a public host. Without the overlay, `SEAFILE_FORCE_HTTPS=true` in `.env`
  is what makes Seafile write https URLs on first run (the overlay forces it).
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
- `HTTP_BIND`, `HTTP_PORT` — where the container's nginx (:80) is published without Traefik.
- `SEAFILE_FORCE_HTTPS` — `true` when an external proxy terminates TLS (first-run default).
- `ACME_EMAIL` — Let's Encrypt account email. HTTP-01: port 80 must be publicly reachable and
  `WG_HOST` must resolve here. No wildcards.
- `TRAEFIK_DASHBOARD_USERS` — htpasswd line. If using bcrypt/md5, escape `$` as `$$`.
- `TELEGRAM_TOKEN` — for the UI's Telegram bot that hands out configs.
- `SEAFILE_HOST` — Seafile domain, optional; defaults to `WG_HOST` (Seafile at `/`, UI at
  `/wg`). A separate value must also resolve to this host. First-run default (see above).
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
docker compose pull wireguard                     # fetch the CI-built image
docker compose build                              # or build it locally (same tag)
docker compose up -d
docker compose logs -f wireguard traefik
docker compose exec wireguard wg show
docker compose exec wireguard sv status /etc/service/*  # nginx, cron, wireguard-ui
docker compose exec wireguard curl -sI http://127.0.0.1/            # Seafile up? (302 to login)
docker compose exec wireguard curl -sI http://127.0.0.1/wg/login    # UI via nginx (200)
docker compose exec wireguard grep -E '^(SERVICE_URL|FILE_SERVER_ROOT|CSRF_TRUSTED)' /shared/seafile/conf/seahub_settings.py
docker compose logs -f wireguard                      # Seafile + UI + wg-quick, one stream
```

## Rules for agents

- After touching either compose file, validate both variants:
  `docker compose -f docker-compose.yaml config -q` and `docker compose config -q`.
- After touching `Dockerfile`, run `docker compose -f docker-compose.yaml build`. After touching
  the `build:` section or the workflow, also dry-run what CI will do:
  `SEAFILE_HOST=x SEAFILE_DB_ROOT_PASSWORD=x SEAFILE_ADMIN_PASSWORD=x docker buildx bake -f docker-compose.yaml --print wireguard`.
- Never commit `.env`, `wireguard/`, `letsencrypt/` or `seafile/` contents. Never print secret
  values from `.env`, `wireguard/ui/db/server/keypair.json` or `seafile/data/seafile/conf/`
  into chat, logs, or commit messages.
- Do not publish port 80 in the base file; Traefik reaches it over the bridge. Do not add a
  second Traefik router pointing at `:5000`; the UI is reached through nginx on purpose.
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
