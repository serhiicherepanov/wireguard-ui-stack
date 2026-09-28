# Builds the Skyline-core fork of wireguard-ui from its git repo at a pinned ref.
#
# Why not the fork's own Dockerfile: it still uses golang:1.21 while go.mod requires
# go >= 1.25, so `docker build <git-url>` fails. This file mirrors the fork's Dockerfile
# (same asset layout, same init.sh entrypoint) with the toolchain bumped.
#
# Build context is this directory (see .dockerignore); the sources are fetched by ADD.

ARG GO_IMAGE=golang:1.25-alpine
ARG RUNTIME_IMAGE=alpine:3.22

FROM ${GO_IMAGE} AS builder

ARG WGUI_FORK_REPO=https://github.com/Skyline-core/wireguard-ui.git
ARG WGUI_FORK_REF=master
ARG APP_VERSION=dev
ARG BUILD_TIME
ARG GIT_COMMIT

RUN apk add --update --no-cache npm yarn

WORKDIR /build

# BuildKit fetches the git ref directly; no git clone layer to cache-bust.
ADD ${WGUI_FORK_REPO}#${WGUI_FORK_REF} /build

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

RUN CGO_ENABLED=0 go build \
      -ldflags="-X 'main.appVersion=${APP_VERSION}' -X 'main.buildTime=${BUILD_TIME}' -X 'main.gitCommit=${GIT_COMMIT}'" \
      -a -o wg-ui .

FROM ${RUNTIME_IMAGE}

# wireguard-tools pulls in bash, iproute2 and openresolv (needed by wg-quick).
# jq: init.sh reads config_file_path from the UI DB. iptables: PostUp/PostDown rules.
RUN apk --no-cache add ca-certificates wireguard-tools jq iptables

WORKDIR /app
RUN mkdir -p db

COPY --from=builder /build/wg-ui /build/init.sh ./
# First-run fix: render wg0.conf before init.sh tries `wg-quick up` (see entrypoint.sh).
COPY entrypoint.sh ./
RUN chmod +x wg-ui init.sh entrypoint.sh

EXPOSE 5000/tcp
ENTRYPOINT ["./entrypoint.sh"]
