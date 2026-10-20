#!/bin/sh
# Backs up the whole project directory (mounted read-only at /src) as one .tgz streamed over
# SSH to $BACKUP_SSH_HOST:$BACKUP_REMOTE_DIR/<BACKUP_NAME>_<yyyymmdd>_<hhmmss>.tgz.
#
# Steps: 1) mariadb-dump of the Seafile databases into /dump (= seafile/dump on the host,
# so it lands inside the archive), 2) tar -czf - /src | ssh 'cat > file.part', 3) mv to the
# final name, 4) optional retention: keep the newest $BACKUP_KEEP archives on the remote.
# No local temp space: the archive never touches the local disk.
#
# Run by ofelia (see entrypoint.sh) or by hand: docker compose exec backup backup.sh
set -eu
set -o pipefail

# ofelia keeps job output in a buffer; send it to the container log instead, unless we are
# on a terminal (docker compose exec).
[ -t 1 ] || exec >>/proc/1/fd/1 2>&1

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') backup: $*"; }
die() { log "ERROR: $*"; exit 1; }

: "${BACKUP_SSH_HOST:?BACKUP_SSH_HOST is not set}"
: "${BACKUP_REMOTE_DIR:?BACKUP_REMOTE_DIR is not set}"
name=${BACKUP_NAME:-wireguard-ui-stack}
user=${BACKUP_SSH_USER:-root}
port=${BACKUP_SSH_PORT:-22}
keep=${BACKUP_KEEP:-0}
src=${BACKUP_SRC:-/src}
dump_dir=${BACKUP_DUMP_DIR:-/dump}

case "$name$BACKUP_REMOTE_DIR" in *"'"*|*" "*) die "BACKUP_NAME / BACKUP_REMOTE_DIR must not contain spaces or quotes" ;; esac

# --- SSH setup: ssh refuses a key with loose permissions when root owns it, so use a 0600 copy.
key_src=/ssh/${BACKUP_SSH_KEY:-id_ed25519}
[ -r "$key_src" ] || die "SSH key $key_src not found (host path backup/ssh/${BACKUP_SSH_KEY:-id_ed25519})"
key=$(mktemp)
trap 'rm -f "$key"' EXIT
cat "$key_src" >"$key" && chmod 600 "$key"
ssh_cmd() {
  ssh -i "$key" -p "$port" \
      -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/ssh/known_hosts \
      -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=6 \
      "$user@$BACKUP_SSH_HOST" "$@"
}

# --- 1. consistent dump of the Seafile databases (raw files in seafile/db are being written to).
# --skip-ssl: the 11.x client insists on TLS by default; seafile-db has none and sits on the
# internal network.
if [ "${BACKUP_DB_DUMP:-true}" = "true" ]; then
  mkdir -p "$dump_dir"
  log "dumping Seafile databases from ${DB_HOST:-seafile-db} to $dump_dir/seafile-db.sql.gz"
  mariadb-dump -h "${DB_HOST:-seafile-db}" -u root --skip-ssl --single-transaction --quick --routines --events \
      --databases ccnet_db seafile_db seahub_db \
    | gzip >"$dump_dir/seafile-db.sql.gz.part" \
    || die "mariadb-dump failed"
  mv "$dump_dir/seafile-db.sql.gz.part" "$dump_dir/seafile-db.sql.gz"
fi

# --- 2. stream the archive
stamp=$(date +%Y%m%d_%H%M%S)
file="${name}_${stamp}.tgz"
remote="$BACKUP_REMOTE_DIR/$file"
log "archiving $src -> $user@$BACKUP_SSH_HOST:$remote"

ssh_cmd "mkdir -p '$BACKUP_REMOTE_DIR'" || die "cannot create $BACKUP_REMOTE_DIR on $BACKUP_SSH_HOST"

excludes=""
for e in ${BACKUP_EXCLUDE:-}; do excludes="$excludes --exclude=./${e#./}"; done

tar_rc_file=$(mktemp)
trap 'rm -f "$key" "$tar_rc_file"' EXIT
# shellcheck disable=SC2086
{ tar -C "$src" --warning=no-file-changed $excludes -czf - . ; echo $? >"$tar_rc_file"; } \
  | ssh_cmd "cat >'$remote.part'" \
  || die "upload failed (ssh/cat exit status $?)"
tar_rc=$(cat "$tar_rc_file")
# GNU tar: 1 = a file changed while it was read (expected on a live system), 2 = fatal.
[ "$tar_rc" -le 1 ] || { ssh_cmd "rm -f '$remote.part'"; die "tar failed (exit $tar_rc)"; }

# --- 3. rename only after a complete upload; report the size
size=$(ssh_cmd "mv '$remote.part' '$remote' && wc -c <'$remote'") || die "cannot finalise $remote"
log "done: $remote ($(echo "$size" | tr -d ' ') bytes, tar exit $tar_rc)"

# --- 4. retention on the remote (names sort by timestamp)
if [ "$keep" -gt 0 ] 2>/dev/null; then
  ssh_cmd "cd '$BACKUP_REMOTE_DIR' && ls -1 '${name}'_*.tgz 2>/dev/null | sort -r | tail -n +$((keep + 1)) \
           | while read -r f; do rm -f -- \"\$f\" && echo \"removed \$f\"; done" \
    | while read -r line; do log "$line"; done
  log "retention: keeping the newest $keep archive(s)"
fi
