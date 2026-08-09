#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-openproject}"
DEST_ROOT="${DEST_ROOT:-/backup/openproject}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
LOCK_FILE="${LOCK_FILE:-/run/lock/openproject-backup.lock}"
BACKUP_MOUNT="${BACKUP_MOUNT:-/backup}"
CONF_DIR="${CONF_DIR:-/etc/${APP_NAME}}"
DB_BACKUP_SCRIPT="${DB_BACKUP_SCRIPT:-openproject_db_backup_restore.sh}"

# Restrict all files/directories this script creates to owner-only permissions,
# since backup artifacts contain the DB dump and secrets (conf-*.tar.gz).
umask 077

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_cmd "$DB_BACKUP_SCRIPT"
require_cmd sudo
require_cmd openproject
require_cmd tar
require_cmd sha256sum
require_cmd mountpoint
require_cmd flock

exec 9>"$LOCK_FILE"
flock -n 9 || die "another backup run is already in progress (lock: $LOCK_FILE)"

mountpoint -q "$BACKUP_MOUNT" || die "$BACKUP_MOUNT is not mounted, refusing to run"

DATE_DIR="$(date +%Y-%m-%d)"
DEST_TMP="${DEST_ROOT}/.tmp-${DATE_DIR}"
DEST_FINAL="${DEST_ROOT}/${DATE_DIR}"

trap 'rm -rf "$DEST_TMP"' EXIT

mkdir -p "$DEST_ROOT"
chmod 0700 "$DEST_ROOT"
rm -rf "$DEST_TMP"
mkdir -p "$DEST_TMP"

archive_with_checksum() {
  local src_dir="$1" dst="$2" label="$3"
  if [ -z "$src_dir" ] || [ ! -d "$src_dir" ]; then
    log "no $label directory found; skipping"
    return 0
  fi
  log "archiving $label from $src_dir"
  tar czf "$dst" -C "$src_dir" .
  # Compute checksum with relative path (basename only) so it survives directory renames
  ( cd "$(dirname "$dst")" && sha256sum "$(basename "$dst")" ) | tee "${dst}.sha256" >/dev/null
}

log "backing up database via $DB_BACKUP_SCRIPT"
BACKUP_DIR="$DEST_TMP" "$DB_BACKUP_SCRIPT" backup

# Re-compute DB dump checksums with relative path (db backup script used absolute path).
# Must happen here, inside $DEST_TMP, before the verification pass below and before the
# rename to $DEST_FINAL — so the single verification pass covers the DB dump too, and the
# rename remains the last mutation this script performs on the backup content.
# Also explicitly chmod DB dumps to 0600 (owner read/write only) to counter any
# world-readable permissions that may have been left by the sudo pg_dump process.
log "recomputing database dump checksums with relative path"
( cd "$DEST_TMP" && for f in postgresql-dump-*.pgdump; do [ -f "$f" ] && { chmod 0600 "$f"; sha256sum "$f" > "${f}.sha256"; }; done )

attachments_path="$(sudo openproject config:get OPENPROJECT_ATTACHMENTS__STORAGE__PATH 2>/dev/null || true)"
[ -n "$attachments_path" ] || attachments_path="$(sudo openproject config:get ATTACHMENTS_STORAGE_PATH 2>/dev/null || true)"
archive_with_checksum "$attachments_path" "${DEST_TMP}/attachments-${DATE_DIR}.tar.gz" attachments

if [ -d "$CONF_DIR" ]; then
  log "archiving configuration from $CONF_DIR"
  conf_dst="${DEST_TMP}/conf-${DATE_DIR}.tar.gz"
  tar czf "$conf_dst" -C "$CONF_DIR" installer.dat conf.d
  # Compute checksum with relative path (basename only) so it survives directory renames
  ( cd "$(dirname "$conf_dst")" && sha256sum "$(basename "$conf_dst")" ) | tee "${conf_dst}.sha256" >/dev/null
else
  die "no configuration directory $CONF_DIR found"
fi

git_repos="$(sudo openproject config:get GIT_REPOSITORIES 2>/dev/null || true)"
archive_with_checksum "$git_repos" "${DEST_TMP}/git-repositories-${DATE_DIR}.tar.gz" "git repositories"

svn_repos="$(sudo openproject config:get SVN_REPOSITORIES 2>/dev/null || true)"
archive_with_checksum "$svn_repos" "${DEST_TMP}/svn-repositories-${DATE_DIR}.tar.gz" "svn repositories"

for pattern in 'postgresql-dump-*.pgdump' 'attachments-*.tar.gz' 'conf-*.tar.gz'; do
  shopt -s nullglob
  matches=("$DEST_TMP"/$pattern)
  shopt -u nullglob
  [ "${#matches[@]}" -gt 0 ] || die "missing expected artifact matching '$pattern' in $DEST_TMP"
  for m in "${matches[@]}"; do
    [ -s "$m" ] || die "artifact $m is empty"
  done
done

log "verifying checksums"
( cd "$DEST_TMP" && sha256sum -c ./*.sha256 >/dev/null )

rm -rf "$DEST_FINAL"
mv "$DEST_TMP" "$DEST_FINAL"
log "backup stored at $DEST_FINAL"

find "$DEST_ROOT" -maxdepth 1 -mindepth 1 -type d -name '20*' -mtime "+${RETENTION_DAYS}" -print0 |
  while IFS= read -r -d '' old; do
    log "pruning old backup $old"
    rm -rf "$old"
  done

log "backup completed successfully"
