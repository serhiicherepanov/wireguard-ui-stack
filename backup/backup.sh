#!/bin/sh
# Backs up the whole project directory (mounted read-only at /src) as one .tgz streamed over
# SFTP to $BACKUP_SSH_HOST:$BACKUP_REMOTE_DIR/<BACKUP_NAME>_<yyyymmdd>_<hhmmss>.tgz.
#
# Steps: 1) mariadb-dump of the Seafile databases into /dump (= seafile/dump on the host,
# so it lands inside the archive), 2) tar -czf - /src | rclone rcat (SFTP streaming upload
# to file.part), 3) rename to the final name, 4) optional retention: keep the newest
# $BACKUP_KEEP archives on the remote.
#
# Everything on the remote side goes through the SFTP subsystem only (rclone sftp backend
# with shell_type=none): no remote shell commands, so SFTP-only accounts (Hetzner Storage
# Box and the like) work. No local temp space: the archive never touches the local disk.
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
port=${BACKUP_SSH_PORT:-22}
keep=${BACKUP_KEEP:-0}
src=${BACKUP_SRC:-/src}
dump_dir=${BACKUP_DUMP_DIR:-/dump}
known_hosts=/ssh/known_hosts
remote_dir=${BACKUP_REMOTE_DIR%/}

# --- SSH setup. The key: ssh libraries refuse a key with loose permissions, so use a 0600 copy.
key_src=/ssh/${BACKUP_SSH_KEY:-id_ed25519}
[ -r "$key_src" ] || die "SSH key $key_src not found (host path backup/ssh/${BACKUP_SSH_KEY:-id_ed25519})"
key=$(mktemp)
tar_rc_file=$(mktemp)
trap 'rm -f "$key" "$tar_rc_file"' EXIT
cat "$key_src" >"$key" && chmod 600 "$key"

# Host key: trust on first use, pinned in backup/ssh/known_hosts afterwards (rclone verifies
# against the file but never adds to it, hence ssh-keyscan). Pre-fill the file to skip TOFU.
touch "$known_hosts"
if ! ssh-keygen -F "$BACKUP_SSH_HOST" -f "$known_hosts" >/dev/null 2>&1 \
   && ! ssh-keygen -F "[$BACKUP_SSH_HOST]:$port" -f "$known_hosts" >/dev/null 2>&1; then
  log "host key of $BACKUP_SSH_HOST:$port unknown, adding it to $known_hosts (first use)"
  ssh-keyscan -p "$port" -T 30 "$BACKUP_SSH_HOST" 2>/dev/null | grep -v "^#" >>"$known_hosts" || die "ssh-keyscan $BACKUP_SSH_HOST failed"
fi

# rclone sftp backend configured from the environment; the remote is ":sftp:<path>".
export RCLONE_SFTP_HOST="$BACKUP_SSH_HOST" RCLONE_SFTP_PORT="$port" RCLONE_SFTP_USER="${BACKUP_SSH_USER:-root}"
export RCLONE_SFTP_KEY_FILE="$key" RCLONE_SFTP_KNOWN_HOSTS_FILE="$known_hosts"
# No remote shell commands at all (SFTP-only accounts), no hash checks (they need a shell).
export RCLONE_SFTP_SHELL_TYPE=none RCLONE_SFTP_DISABLE_HASHCHECK=true
export RCLONE_CONTIMEOUT=30s RCLONE_TIMEOUT=5m RCLONE_RETRIES=1 RCLONE_LOW_LEVEL_RETRIES=3 RCLONE_LOG_LEVEL=ERROR
rc() { rclone "$@"; }

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
remote=":sftp:$remote_dir/$file"
log "archiving $src -> ${RCLONE_SFTP_USER}@$BACKUP_SSH_HOST:$port $remote_dir/$file"

rc mkdir ":sftp:$remote_dir" || die "cannot create $remote_dir on $BACKUP_SSH_HOST"

excludes=""
for e in ${BACKUP_EXCLUDE:-}; do excludes="$excludes --exclude=./${e#./}"; done

# shellcheck disable=SC2086
{ tar -C "$src" --warning=no-file-changed $excludes -czf - . ; echo $? >"$tar_rc_file"; } \
  | rc rcat "$remote.part" \
  || die "upload failed (rclone exit status $?)"
tar_rc=$(cat "$tar_rc_file")
# GNU tar: 1 = a file changed while it was read (expected on a live system), 2 = fatal.
[ "$tar_rc" -le 1 ] || { rc deletefile "$remote.part" || true; die "tar failed (exit $tar_rc)"; }

# --- 3. rename only after a complete upload; report the size
rc moveto "$remote.part" "$remote" || die "cannot rename $file.part on $BACKUP_SSH_HOST"
size=$(rc lsf --files-only --format s --include "/$file" ":sftp:$remote_dir" 2>/dev/null || echo "?")
log "done: $remote_dir/$file (${size:-?} bytes, tar exit $tar_rc)"

# --- 4. retention on the remote (names sort by timestamp)
if [ "$keep" -gt 0 ] 2>/dev/null; then
  rc lsf --files-only --include "/${name}_*.tgz" ":sftp:$remote_dir" | sort -r | tail -n +$((keep + 1)) \
  | while read -r f; do
      [ -n "$f" ] || continue
      rc deletefile ":sftp:$remote_dir/$f" && log "removed $f" || log "WARNING: could not remove $f"
    done
  log "retention: keeping the newest $keep archive(s)"
fi
