# Builds one image that runs WireGuard, the Skyline-core fork of wireguard-ui AND Seafile.
#
# Stage 1 (builder): the fork from its git repo at a pinned ref.
#   Why not the fork's own Dockerfile: it still uses golang:1.21 while go.mod requires
#   go >= 1.25, so `docker build <git-url>` fails. This stage mirrors the fork's Dockerfile
#   (same asset layout, same init.sh entrypoint) with the toolchain bumped. Sources are
#   fetched with git, which works with both BuildKit and the legacy builder (ADD <git-url>
#   does not).
#
# Stage 2 (runtime): the official Seafile CE image (Ubuntu 22.04, phusion my_init + runit)
#   plus wireguard-tools and the fork binary. Seafile lives in the same container (one image
#   to build, ship and run; its nginx also serves the UI under BASE_PATH). my_init stays
#   PID 1: it runs Seafile's own startup and supervises nginx, cron and our `wireguard-ui`
#   runit service.
#
# Build context is this directory (see .dockerignore).

ARG GO_IMAGE=golang:1.25-alpine
ARG SEAFILE_IMAGE=seafileltd/seafile-mc:11.0-latest

FROM ${GO_IMAGE} AS builder

ARG WGUI_FORK_REPO=https://github.com/Skyline-core/wireguard-ui.git
ARG WGUI_FORK_REF=master
ARG APP_VERSION=dev
ARG BUILD_TIME
ARG GIT_COMMIT

RUN apk add --update --no-cache git npm yarn

WORKDIR /build

# Shallow fetch of exactly one ref (sha, tag or branch all work with GitHub).
RUN git init -q . && \
    git remote add origin "${WGUI_FORK_REPO}" && \
    git fetch -q --depth 1 origin "${WGUI_FORK_REF}" && \
    git checkout -q FETCH_HEAD && \
    rm -rf .git

# Frontend deps (admin-lte + plugins), same layout as the fork's Dockerfile.
RUN yarn install --pure-lockfile --production && yarn cache clean && \
    mkdir -p assets/dist/js assets/dist/css assets/plugins && \
    cp node_modules/admin-lte/dist/js/adminlte.min.js   assets/dist/js/adminlte.min.js && \
    cp node_modules/admin-lte/dist/css/adminlte.min.css assets/dist/css/adminlte.min.css && \
    cp -r node_modules/admin-lte/plugins/jquery/ \
          node_modules/admin-lte/plugins/fontawesome-free/ \
          node_modules/admin-lte/plugins/bootstrap/ \
          node_modules/admin-lte/plugins/icheck-bootstrap/ \
          node_modules/admin-lte/plugins/toastr/ \
          node_modules/admin-lte/plugins/jquery-validation/ \
          node_modules/admin-lte/plugins/select2/ \
          node_modules/jquery-tags-input/ \
          assets/plugins/ && \
    cp -r custom/ assets/

# The fork's templates reference /static/wireguard.svg but ship no such file (404, broken
# logo on login page and sidebar). Provide it; assets/ is embedded into the binary below.
COPY assets/wireguard.svg assets/wireguard.svg

RUN CGO_ENABLED=0 go build \
      -ldflags="-X 'main.appVersion=${APP_VERSION}' -X 'main.buildTime=${BUILD_TIME}' -X 'main.gitCommit=${GIT_COMMIT}'" \
      -a -o wg-ui .

FROM ${SEAFILE_IMAGE}

# wireguard-tools + iproute2 + openresolv: wg-quick. iptables: PostUp/PostDown rules.
# jq: init.sh reads config_file_path from the UI DB. Everything else (nginx, python, cron,
# curl, wget) ships with the Seafile image.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        wireguard-tools iproute2 openresolv iptables jq && \
    rm -rf /var/lib/apt/lists/*

# Seafile's nginx also proxies BASE_PATH (default /wg) to the UI (direct / tunnel access).
# The server block gets an `include` of a file that nginx-ui-locations.sh generates from
# BASE_PATH at every start (my_init.d runs before runit starts nginx). The grep fails the
# build if a new Seafile image changes the template and the include did not land.
COPY nginx-ui-locations.sh /etc/my_init.d/02_nginx_ui_locations.sh
RUN chmod +x /etc/my_init.d/02_nginx_ui_locations.sh && \
    sed -i '/^    location \/media {/i\    # wireguard-ui under BASE_PATH, see /etc/my_init.d/02_nginx_ui_locations.sh\n    include /etc/nginx/wireguard-ui.locations;\n' \
        /templates/seafile.nginx.conf.template && \
    grep -q 'include /etc/nginx/wireguard-ui.locations;' /templates/seafile.nginx.conf.template

# TLS is terminated by Traefik: make Seafile's first-run bootstrap also write
# CSRF_TRUSTED_ORIGINS into seahub_settings.py (see the script for why). Fails the build if
# a new Seafile image moved the anchor line.
COPY patch-seafile-bootstrap.py /scripts/
RUN python3 /scripts/patch-seafile-bootstrap.py /scripts/bootstrap.py && \
    python3 -m py_compile /scripts/bootstrap.py

# The UI keeps the fork's layout under /app (init.sh uses relative paths: db/, ./wg-ui).
RUN mkdir -p /app/db
COPY --from=builder /build/wg-ui /build/init.sh /app/
# First-run fix (render wg0.conf before `wg-quick up`).
COPY entrypoint.sh /app/
RUN chmod +x /app/wg-ui /app/init.sh /app/entrypoint.sh

# Run tunnel + UI as a runit service next to Seafile's nginx and cron. runsv restarts it if
# the UI dies; `sv force-stop` on container stop sends SIGTERM, which init.sh turns into
# `wg-quick down`.
RUN mkdir -p /etc/service/wireguard-ui && \
    printf '#!/bin/sh\nexec 2>&1\ncd /app && exec ./entrypoint.sh\n' > /etc/service/wireguard-ui/run && \
    chmod +x /etc/service/wireguard-ui/run

EXPOSE 5000/tcp 80/tcp

# Inherited from the Seafile image, restated on purpose: my_init must stay PID 1 (it runs
# /etc/my_init.d, boots runit, then Seafile). Do not replace it with entrypoint.sh.
CMD ["/sbin/my_init", "--", "/scripts/enterpoint.sh"]
