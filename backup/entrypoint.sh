#!/bin/sh
# Entrypoint of the backup container: write ofelia's config from the environment (compose
# interpolates .env into it) and start the daemon. INI config instead of docker labels so
# the container does not need the docker socket.
set -eu

mkdir -p /etc/ofelia
cat >/etc/ofelia/config.ini <<INI
[job-local "backup"]
schedule = ${BACKUP_SCHEDULE:-0 30 3 * * *}
command = /usr/local/bin/backup.sh
INI

echo "backup: schedule '${BACKUP_SCHEDULE:-0 30 3 * * *}' (sec min hour dom mon dow, TZ=${TZ:-UTC})" \
     "-> ${BACKUP_SSH_USER:-root}@${BACKUP_SSH_HOST:-?}:${BACKUP_REMOTE_DIR:-?}"

exec /sbin/tini -- /usr/bin/ofelia daemon --config /etc/ofelia/config.ini
