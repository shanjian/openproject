# Production Backup Mechanism Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a systemd-driven nightly backup for the packaged (DEB/RPM) OpenProject production install that reuses the team's existing `openproject_db_backup_restore.sh` for the database, extends its checksum convention to attachments/config/repositories, lands dated backup sets on the mounted `/backup` volume with 30-day retention, and emails on failure.

**Architecture:** A bash wrapper (`openproject-backup.sh`) builds each artifact directly into a staging folder: the database via the existing `openproject_db_backup_restore.sh backup` (deployed alongside it), and attachments/config/repositories via new tar+`sha256sum` logic matching that script's pattern. It verifies every required artifact is present, non-empty, and checksum-valid, then atomically renames the staging folder into place under `/backup/openproject/<date>/` and prunes folders older than the retention window. A systemd timer fires it nightly; on failure systemd runs a second unit that sends an alert email. All of it is plain bash + systemd unit files — no new language runtime or dependency.

**Tech Stack:** bash, systemd (service + timer units), the existing `script/migration/openproject_db_backup_restore.sh` (reused, not modified).

## Global Constraints

- Frequency: daily. (spec: "Frequency")
- Retention: 30 days of dated backup folders on `/backup`. (spec: "Retention")
- Alerting: email on failure now, with a single well-defined seam (`openproject-backup-alert.sh`) to swap in a monitoring/alerting system later — do not hardcode email-sending logic anywhere else. (spec: "Alerting", "TODO")
- Never write to `/backup` if it isn't actually mounted — abort instead. (spec: "Error handling")
- Never leave a partially-written dated folder behind on failure. (spec: "Error handling")
- Database backup/restore must reuse `script/migration/openproject_db_backup_restore.sh` as-is — do not duplicate its `pg_dump`/`pg_restore` logic. (user instruction)
- Every artifact (DB dump, attachments, config, repositories) gets a `sha256sum` checksum file alongside it, matching that script's existing convention. (user instruction, generalized)
- Target deployment is the **packaged install** (`openproject` CLI available on the host as root), not Docker. `openproject_db_backup_restore.sh` and the new scripts are manually copied onto the box (confirmed with the user — there's no repo checkout or package-bundling step to rely on). (spec: "What gets backed up"; user clarification)
- All new files live under `extra/backup/` in this repo, matching the existing `extra/Apache`, `extra/mail_handler` convention of shipping ops artifacts outside the Rails app tree.

## Codebase facts that shape this plan

- `script/migration/openproject_db_backup_restore.sh` (already in this repo, **not modified** by this plan) is the team's existing, trusted DB backup/restore tool. `backup_db()` writes `${BACKUP_DIR}/postgresql-dump-<UTC-ts>.pgdump` (via `sudo pg_dump --format=custom --no-owner --dbname "$(sudo openproject config:get DATABASE_URL)"`) plus a `.sha256` checksum next to it. `restore_db()` takes a dump path and an optional `--yes`, stops the `openproject` service, runs `sudo pg_restore --clean --if-exists --no-owner`, and restarts the service. `BACKUP_DIR` (default `/var/db/openproject/backup/manual-db`) and `SERVICE_NAME` (default `openproject`) are its only env overrides.
- The packaging-shipped `packaging/scripts/backup` (what `openproject run backup` runs) was the basis of an earlier draft of this plan; it's **no longer used**. It doesn't propagate failure (a failed `tar` just logs "failed" and the script still exits 0), so this plan instead builds each artifact directly and checks the result itself.
- Attachments live at `sudo openproject config:get OPENPROJECT_ATTACHMENTS__STORAGE__PATH` (falling back to the legacy key `ATTACHMENTS_STORAGE_PATH`). Config to back up is `/etc/openproject/installer.dat` and `/etc/openproject/conf.d/` (same two paths `packaging/scripts/backup` tars). Repositories, if configured, are at `sudo openproject config:get GIT_REPOSITORIES` / `SVN_REPOSITORIES` — both optional.
- No `bats`/`shellcheck` are installed in this environment, so tasks below verify scripts with `bash -n` (syntax) and small fixture-driven scratch tests (using mock `sudo`/`openproject`/`openproject_db_backup_restore.sh` on `PATH`) instead of a bash test framework. `systemd-analyze verify` is available for the unit files.

## File Structure

```
extra/backup/
  openproject-backup.sh          # main wrapper: build each artifact, verify, prune
  openproject-backup-alert.sh    # failure alert (email today; the future monitoring seam)
  openproject-backup.service     # systemd oneshot unit, OnFailure=openproject-backup-alert.service
  openproject-backup.timer       # systemd timer, daily 02:30, Persistent=true
  openproject-backup-alert.service
  install.sh                    # copies scripts+units (incl. openproject_db_backup_restore.sh) into place, enables the timer
  RESTORE.md                    # disaster-restore steps
  README.md                     # what this is, config vars, how to install/test
```

`script/migration/openproject_db_backup_restore.sh` stays where it is in the repo; `install.sh` is responsible for deploying a copy of it to the same installed location as the new scripts (`/usr/local/bin/`) so `openproject-backup.sh` can find it on `PATH` at runtime.

Each script is self-contained (single responsibility: the wrapper backs up, the alert script alerts, `install.sh` installs). Config is via environment variables with defaults baked in, overridable through `/etc/openproject-backup.env` (loaded by the systemd units via `EnvironmentFile=-`).

## Interfaces between tasks

- `openproject-backup.sh` exits `0` on a verified, complete backup; non-zero (with a message on stderr) on any failure. It takes no arguments; configuration is via env vars `APP_NAME`, `DEST_ROOT`, `RETENTION_DAYS`, `LOCK_FILE`, `BACKUP_MOUNT`, `CONF_DIR`, `DB_BACKUP_SCRIPT`. It requires `openproject_db_backup_restore.sh` (or whatever `DB_BACKUP_SCRIPT` points to) to be on `PATH` and to support a `backup` subcommand honoring the `BACKUP_DIR` env var — exactly `script/migration/openproject_db_backup_restore.sh`'s existing interface.
- `openproject-backup-alert.sh` takes no arguments, exits `0` if it successfully sent an alert, non-zero otherwise. Configuration via `BACKUP_ALERT_EMAIL`, `APP_NAME`.
- `openproject-backup.service` has `OnFailure=openproject-backup-alert.service` — this is the only wiring between the two; the alert unit doesn't know why the backup failed, only that it did.
- `install.sh` assumes both new scripts, both service units, and the timer unit exist at fixed relative paths inside `extra/backup/` (the same directory it lives in), and that `script/migration/openproject_db_backup_restore.sh` exists two directories up from there (i.e. at the repo root's `script/migration/`).

---

### Task 1: Backup wrapper script

**Files:**
- Create: `extra/backup/openproject-backup.sh`
- Test (scratch, not committed): a fixture harness with mocked `sudo`/`openproject`/DB-backup-script, run manually per the steps below

**Interfaces:**
- Produces: an executable `extra/backup/openproject-backup.sh`, invoked with no args, honoring env vars `APP_NAME` (default `openproject`), `DEST_ROOT` (default `/backup/openproject`), `RETENTION_DAYS` (default `30`), `LOCK_FILE` (default `/run/lock/openproject-backup.lock`), `BACKUP_MOUNT` (default `/backup`), `CONF_DIR` (default `/etc/${APP_NAME}`), `DB_BACKUP_SCRIPT` (default `openproject_db_backup_restore.sh`, resolved via `PATH`). Exit code `0` = verified success.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-openproject}"
DEST_ROOT="${DEST_ROOT:-/backup/openproject}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
LOCK_FILE="${LOCK_FILE:-/run/lock/openproject-backup.lock}"
BACKUP_MOUNT="${BACKUP_MOUNT:-/backup}"
CONF_DIR="${CONF_DIR:-/etc/${APP_NAME}}"
DB_BACKUP_SCRIPT="${DB_BACKUP_SCRIPT:-openproject_db_backup_restore.sh}"

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

exec 9>"$LOCK_FILE"
flock -n 9 || die "another backup run is already in progress (lock: $LOCK_FILE)"

mountpoint -q "$BACKUP_MOUNT" || die "$BACKUP_MOUNT is not mounted, refusing to run"

DATE_DIR="$(date +%Y-%m-%d)"
DEST_TMP="${DEST_ROOT}/.tmp-${DATE_DIR}"
DEST_FINAL="${DEST_ROOT}/${DATE_DIR}"

mkdir -p "$DEST_ROOT"
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
  sha256sum "$dst" | tee "${dst}.sha256" >/dev/null
}

log "backing up database via $DB_BACKUP_SCRIPT"
BACKUP_DIR="$DEST_TMP" "$DB_BACKUP_SCRIPT" backup

attachments_path="$(sudo openproject config:get OPENPROJECT_ATTACHMENTS__STORAGE__PATH 2>/dev/null || true)"
[ -n "$attachments_path" ] || attachments_path="$(sudo openproject config:get ATTACHMENTS_STORAGE_PATH 2>/dev/null || true)"
archive_with_checksum "$attachments_path" "${DEST_TMP}/attachments-${DATE_DIR}.tar.gz" attachments

if [ -d "$CONF_DIR" ]; then
  log "archiving configuration from $CONF_DIR"
  conf_dst="${DEST_TMP}/conf-${DATE_DIR}.tar.gz"
  tar czf "$conf_dst" -C "$CONF_DIR" installer.dat conf.d
  sha256sum "$conf_dst" | tee "${conf_dst}.sha256" >/dev/null
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
```

- [ ] **Step 2: Syntax-check it**

Run: `bash -n extra/backup/openproject-backup.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Make it executable**

Run: `chmod +x extra/backup/openproject-backup.sh`

- [ ] **Step 4: Build a scratch fixture with mocked dependencies**

This wrapper calls `sudo`, `openproject`, and `openproject_db_backup_restore.sh` — none of which should be exercised for real in a test. Build a scratch `PATH` with mocks for all three, plus fixture data directories:

```bash
SCRATCH=$(mktemp -d)
mkdir -p "$SCRATCH/bin" "$SCRATCH/backup_mount/openproject" \
         "$SCRATCH/attachments" "$SCRATCH/etc_openproject/conf.d"
touch "$SCRATCH/etc_openproject/installer.dat"
echo "some file" > "$SCRATCH/attachments/file1.txt"

cat > "$SCRATCH/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

cat > "$SCRATCH/bin/openproject" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "config:get OPENPROJECT_ATTACHMENTS__STORAGE__PATH") echo "$SCRATCH/attachments"; exit 0 ;;
  *) exit 1 ;;
esac
EOF

cat > "$SCRATCH/bin/openproject_db_backup_restore.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "backup" ] || { echo "mock only supports backup" >&2; exit 1; }
ts="$(date -u +%Y%m%dT%H%M%SZ)"
dump="${BACKUP_DIR}/postgresql-dump-${ts}.pgdump"
echo "fake dump contents" > "$dump"
sha256sum "$dump" > "${dump}.sha256"
EOF

chmod +x "$SCRATCH/bin/"*

mount --bind "$SCRATCH/backup_mount" "$SCRATCH/backup_mount"   # makes it a real mountpoint
```

`mount --bind` requires root/sudo. If unavailable in this environment, use an already-mounted directory (e.g. `BACKUP_MOUNT=/tmp` with `DEST_ROOT=/tmp/openproject-backup-test-$$`) instead of creating one, and skip the `umount` in Step 5.

- [ ] **Step 5: Run the happy path**

```bash
PATH="$SCRATCH/bin:$PATH" \
BACKUP_MOUNT="$SCRATCH/backup_mount" \
DEST_ROOT="$SCRATCH/backup_mount/openproject" \
CONF_DIR="$SCRATCH/etc_openproject" \
LOCK_FILE="$SCRATCH/lock" \
  extra/backup/openproject-backup.sh
echo "exit=$?"
ls "$SCRATCH/backup_mount/openproject"
find "$SCRATCH/backup_mount/openproject" -maxdepth 2
```

Expected: `exit=0`; one directory named like `2026-08-09` containing `postgresql-dump-*.pgdump` (+ `.sha256`), `attachments-*.tar.gz` (+ `.sha256`), `conf-*.tar.gz` (+ `.sha256`). No `git-repositories-*`/`svn-repositories-*` files (the mock `openproject` returns nonzero for those keys, so they're correctly skipped).

- [ ] **Step 6: Confirm the failure paths**

Using the same `SCRATCH` setup, confirm each of these exits non-zero with a clear stderr message:

1. Unmounted destination: rerun with `BACKUP_MOUNT` pointing at a plain (non-bind-mounted) empty directory — expect `"is not mounted, refusing to run"`.
2. Missing config dir: rerun with `CONF_DIR=$SCRATCH/does-not-exist` — expect `"no configuration directory ... found"`.
3. Corrupted checksum: the wrapper's checksum check (`sha256sum -c ./*.sha256`) can't easily be forced to fail mid-script without editing the script, so verify that exact command's behavior in isolation instead, against the dated folder Step 5 already produced:
   ```bash
   cd "$SCRATCH/backup_mount/openproject/$(date +%Y-%m-%d)"
   echo corrupted >> attachments-*.tar.gz
   sha256sum -c ./*.sha256 ; echo "exit=$?"
   ```
   Expected: `exit` is non-zero and `sha256sum` reports the attachments file as `FAILED` — this confirms the same verification command the wrapper runs would have caught corruption, had it occurred before the rename.

- [ ] **Step 7: Confirm retention pruning**

Reuse the Step 4 fixture, but before running the script create an old dated folder and set its mtime beyond the retention window:

```bash
mkdir -p "$SCRATCH/backup_mount/openproject/2020-01-01"
touch -d '40 days ago' "$SCRATCH/backup_mount/openproject/2020-01-01"
# ... run the script exactly as in Step 5 ...
ls "$SCRATCH/backup_mount/openproject"   # 2020-01-01 must be gone, today's dir must be present
```

- [ ] **Step 8: Clean up the scratch fixture**

```bash
umount "$SCRATCH/backup_mount" 2>/dev/null || true
rm -rf "$SCRATCH"
```

- [ ] **Step 9: Commit**

```bash
git add extra/backup/openproject-backup.sh
git commit -m "feat(backup): add nightly backup wrapper script"
```

---

### Task 2: Failure alert script

**Files:**
- Create: `extra/backup/openproject-backup-alert.sh`

**Interfaces:**
- Consumes: nothing from Task 1 directly (it is invoked independently by systemd via `OnFailure=`).
- Produces: an executable `extra/backup/openproject-backup-alert.sh`, env vars `BACKUP_ALERT_EMAIL` (default `root`) and `APP_NAME` (default `openproject`). Exit `0` on successful send, non-zero otherwise.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-openproject}"
BACKUP_ALERT_EMAIL="${BACKUP_ALERT_EMAIL:-root}"

subject="[ALERT] ${APP_NAME} backup failed on $(hostname)"
body="The openproject-backup.service unit failed on $(hostname) at $(date -u +%Y-%m-%dT%H:%M:%SZ).

Check logs with: journalctl -u openproject-backup.service -n 200 --no-pager"

# NOTE: this script is the single seam for alerting. When a monitoring/alert
# system is adopted, replace the body of this script (or the ExecStart line
# in openproject-backup-alert.service) — nothing else in the backup pipeline
# needs to change.
if command -v mail >/dev/null 2>&1; then
  echo "$body" | mail -s "$subject" "$BACKUP_ALERT_EMAIL"
elif command -v sendmail >/dev/null 2>&1; then
  { printf 'Subject: %s\nTo: %s\n\n%s\n' "$subject" "$BACKUP_ALERT_EMAIL" "$body"; } | sendmail -t
else
  echo "no mail transport available (mail/sendmail); cannot send backup-failure alert" >&2
  exit 1
fi
```

- [ ] **Step 2: Syntax-check and make executable**

Run: `bash -n extra/backup/openproject-backup-alert.sh && chmod +x extra/backup/openproject-backup-alert.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Confirm the success path with a mocked mail transport**

```bash
SCRATCH=$(mktemp -d)
cat > "$SCRATCH/mail" <<'EOF'
#!/usr/bin/env bash
echo "MOCK MAIL CALLED: $*" >&2
cat >/dev/null
EOF
chmod +x "$SCRATCH/mail"
PATH="$SCRATCH:$PATH" BACKUP_ALERT_EMAIL=ops@example.com extra/backup/openproject-backup-alert.sh
echo "exit=$?"
rm -rf "$SCRATCH"
```

Expected: stderr shows `MOCK MAIL CALLED: -s [ALERT] openproject backup failed on <hostname> ops@example.com`, `exit=0`.

- [ ] **Step 4: Confirm the failure path when no mail transport exists**

```bash
SCRATCH_EMPTY_BIN=$(mktemp -d)
PATH="$SCRATCH_EMPTY_BIN:$(dirname "$(command -v hostname)"):$(dirname "$(command -v date)")" \
  extra/backup/openproject-backup-alert.sh
echo "exit=$?"
rm -rf "$SCRATCH_EMPTY_BIN"
```

Expected: `"no mail transport available"` on stderr, `exit=1`.

- [ ] **Step 5: Commit**

```bash
git add extra/backup/openproject-backup-alert.sh
git commit -m "feat(backup): add backup-failure alert script"
```

---

### Task 3: systemd units

**Files:**
- Create: `extra/backup/openproject-backup.service`
- Create: `extra/backup/openproject-backup.timer`
- Create: `extra/backup/openproject-backup-alert.service`

**Interfaces:**
- Consumes: `extra/backup/openproject-backup.sh` and `extra/backup/openproject-backup-alert.sh` from Tasks 1–2, referenced by absolute installed path `/usr/local/bin/openproject-backup.sh` / `/usr/local/bin/openproject-backup-alert.sh` (Task 4 installs them there).
- Produces: three unit files, installable via `systemctl link` or copy into `/etc/systemd/system/`.

- [ ] **Step 1: Write `openproject-backup.service`**

```ini
[Unit]
Description=OpenProject disaster-recovery backup
After=postgresql.service network-online.target
Wants=network-online.target
OnFailure=openproject-backup-alert.service

[Service]
Type=oneshot
User=root
EnvironmentFile=-/etc/openproject-backup.env
ExecStart=/usr/local/bin/openproject-backup.sh
```

- [ ] **Step 2: Write `openproject-backup.timer`**

```ini
[Unit]
Description=Run OpenProject backup nightly

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Write `openproject-backup-alert.service`**

```ini
[Unit]
Description=Send alert for a failed OpenProject backup

[Service]
Type=oneshot
User=root
EnvironmentFile=-/etc/openproject-backup.env
ExecStart=/usr/local/bin/openproject-backup-alert.sh
```

- [ ] **Step 4: Validate all three unit files**

Run: `systemd-analyze verify extra/backup/openproject-backup.service extra/backup/openproject-backup.timer extra/backup/openproject-backup-alert.service`
Expected: no fatal errors. (Warnings about the units referencing files that don't yet exist at `/usr/local/bin/...` are expected and fine at this stage — they exist once Task 4's `install.sh` runs on a real host.)

- [ ] **Step 5: Commit**

```bash
git add extra/backup/openproject-backup.service extra/backup/openproject-backup.timer extra/backup/openproject-backup-alert.service
git commit -m "feat(backup): add systemd service and timer units"
```

---

### Task 4: Installer script

**Files:**
- Create: `extra/backup/install.sh`

**Interfaces:**
- Consumes: all five files from Tasks 1–3, located in the same directory as `install.sh` itself (`extra/backup/`); and `script/migration/openproject_db_backup_restore.sh`, located two directories up (repo root's `script/migration/`).
- Produces: an idempotent installer; running it twice is safe.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "install.sh must be run as root" >&2
  exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SRC_DIR/../.." && pwd)"

install -m 0755 "$SRC_DIR/openproject-backup.sh" /usr/local/bin/openproject-backup.sh
install -m 0755 "$SRC_DIR/openproject-backup-alert.sh" /usr/local/bin/openproject-backup-alert.sh
install -m 0755 "$REPO_ROOT/script/migration/openproject_db_backup_restore.sh" /usr/local/bin/openproject_db_backup_restore.sh
install -m 0644 "$SRC_DIR/openproject-backup.service" /etc/systemd/system/openproject-backup.service
install -m 0644 "$SRC_DIR/openproject-backup.timer" /etc/systemd/system/openproject-backup.timer
install -m 0644 "$SRC_DIR/openproject-backup-alert.service" /etc/systemd/system/openproject-backup-alert.service

if [ ! -f /etc/openproject-backup.env ]; then
  cat > /etc/openproject-backup.env <<'EOF'
# Overrides for the OpenProject backup pipeline. Uncomment and edit as needed.
# RETENTION_DAYS=30
# BACKUP_ALERT_EMAIL=ops@example.com
EOF
  chmod 0644 /etc/openproject-backup.env
fi

systemctl daemon-reload
systemctl enable --now openproject-backup.timer

echo "Installed. Next scheduled run:"
systemctl list-timers openproject-backup.timer --no-pager
```

- [ ] **Step 2: Syntax-check and make executable**

Run: `bash -n extra/backup/install.sh && chmod +x extra/backup/install.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Confirm the non-root guard**

Run (as a non-root user): `extra/backup/install.sh; echo "exit=$?"`
Expected: `"install.sh must be run as root"` on stderr, `exit=1`.

- [ ] **Step 4: Confirm it resolves `openproject_db_backup_restore.sh` correctly**

Run (as any user, just checking path resolution logic, not the root guard):
```bash
bash -c '
SRC_DIR="$(cd extra/backup && pwd)"
REPO_ROOT="$(cd "$SRC_DIR/../.." && pwd)"
test -f "$REPO_ROOT/script/migration/openproject_db_backup_restore.sh" && echo "resolved ok: $REPO_ROOT/script/migration/openproject_db_backup_restore.sh"
'
```
Expected: prints `resolved ok: <repo-root>/script/migration/openproject_db_backup_restore.sh`.

- [ ] **Step 5: Commit**

```bash
git add extra/backup/install.sh
git commit -m "feat(backup): add installer for backup scripts and systemd units"
```

---

### Task 5: Restore procedure and README

**Files:**
- Create: `extra/backup/RESTORE.md`
- Create: `extra/backup/README.md`

**Interfaces:**
- Consumes: the artifact naming and layout produced by Tasks 1–4 (dated folders under `/backup/openproject/<YYYY-MM-DD>/` containing `postgresql-dump-*.pgdump` + `.sha256`, `attachments-*.tar.gz` + `.sha256`, `conf-*.tar.gz` + `.sha256`, and optionally `git-repositories-*.tar.gz` / `svn-repositories-*.tar.gz` + `.sha256`); and `openproject_db_backup_restore.sh`'s `restore` subcommand interface (`restore <dump_file> [--yes]`).
- Produces: none (documentation only).

- [ ] **Step 1: Write `extra/backup/RESTORE.md`**

```markdown
# Restoring from a backup

Pick the dated folder to restore from, e.g. `/backup/openproject/2026-08-09/`.

1. Install the **same version** of the OpenProject package on the
   replacement server that produced the backup (`openproject --version`
   on the old host tells you which), plus a copy of
   `openproject_db_backup_restore.sh` (see this repo's
   `script/migration/openproject_db_backup_restore.sh` — `install.sh` puts
   it at `/usr/local/bin/openproject_db_backup_restore.sh`).

2. Verify the dump's checksum before trusting it:

   ```bash
   cd /backup/openproject/2026-08-09
   sha256sum -c postgresql-dump-*.pgdump.sha256
   sha256sum -c attachments-*.tar.gz.sha256
   sha256sum -c conf-*.tar.gz.sha256
   ```

3. Restore the database using the existing tool (it stops the
   `openproject` service, runs `pg_restore --clean --if-exists --no-owner`,
   and restarts the service for you):

   ```bash
   sudo openproject_db_backup_restore.sh restore \
     /backup/openproject/2026-08-09/postgresql-dump-*.pgdump --yes
   ```

4. Restore configuration (do this before `openproject configure`, since it
   includes `installer.dat`):

   ```bash
   sudo tar xzf /backup/openproject/2026-08-09/conf-*.tar.gz -C /etc/openproject
   ```

5. Restore attachments:

   ```bash
   attachments_path=$(sudo openproject config:get OPENPROJECT_ATTACHMENTS__STORAGE__PATH)
   sudo mkdir -p "$attachments_path"
   sudo tar xzf /backup/openproject/2026-08-09/attachments-*.tar.gz -C "$attachments_path"
   ```

6. Restore repositories, if the backup folder has them:

   ```bash
   [ -f /backup/openproject/2026-08-09/git-repositories-*.tar.gz ] && \
     sudo tar xzf /backup/openproject/2026-08-09/git-repositories-*.tar.gz -C "$(sudo openproject config:get GIT_REPOSITORIES)"
   [ -f /backup/openproject/2026-08-09/svn-repositories-*.tar.gz ] && \
     sudo tar xzf /backup/openproject/2026-08-09/svn-repositories-*.tar.gz -C "$(sudo openproject config:get SVN_REPOSITORIES)"
   ```

7. Reapply configuration and restart:

   ```bash
   sudo openproject configure
   ```

8. Log in and spot-check: a recently modified work package, an attachment
   download, and (if applicable) a repository browse.

## Test this procedure regularly

An untested backup is a hope, not a backup. Run this restore procedure
against a scratch VM at least once or twice a year, and after any OpenProject
major-version upgrade.
```

- [ ] **Step 2: Write `extra/backup/README.md`**

```markdown
# OpenProject production backup pipeline

Nightly disaster-recovery backups for a packaged (DEB/RPM) OpenProject
install. The database portion reuses the team's existing
`openproject_db_backup_restore.sh`; attachments, configuration, and
repositories are archived with the same tar + `sha256sum` convention.

## What it does

`openproject-backup.sh`:

1. Refuses to run unless `/backup` is actually mounted.
2. Backs up the database via `openproject_db_backup_restore.sh backup`.
3. Archives attachments, `/etc/openproject`, and any git/svn repositories,
   each with a `.sha256` checksum alongside it.
4. Verifies every required artifact (dump, attachments, config) is
   present, non-empty, and checksum-valid.
5. Atomically moves the result into `/backup/openproject/<YYYY-MM-DD>/`.
6. Prunes dated folders older than `RETENTION_DAYS` (default 30).

A systemd timer runs it nightly at 02:30; on failure,
`openproject-backup-alert.service` sends an email.

## Install

Requires the `/backup` volume to already be mounted on this host.

```bash
sudo extra/backup/install.sh
```

This installs the scripts (including a copy of
`script/migration/openproject_db_backup_restore.sh`) to `/usr/local/bin/`,
the units to `/etc/systemd/system/`, creates `/etc/openproject-backup.env`
for overrides, and enables + starts the timer.

## Configuration

Set these in `/etc/openproject-backup.env` (created empty/commented by
`install.sh`):

| Variable | Default | Meaning |
|---|---|---|
| `RETENTION_DAYS` | `30` | How many days of dated folders to keep on `/backup` |
| `BACKUP_ALERT_EMAIL` | `root` | Recipient for failure alert emails |
| `DEST_ROOT` | `/backup/openproject` | Where dated backup folders are written |
| `APP_NAME` | `openproject` | The package/CLI name, if customized |

## Verifying it works

```bash
sudo systemctl start openproject-backup.service
ls /backup/openproject/
journalctl -u openproject-backup.service -n 50 --no-pager
```

To test the failure alert without breaking a real backup, temporarily
unmount `/backup` (or bind-mount something else over it), run
`sudo systemctl start openproject-backup.service`, and confirm the alert
email arrives.

## Restoring

See [RESTORE.md](RESTORE.md).

## Future work

Alerting currently sends email only. When a monitoring/alerting system is
adopted, swap `openproject-backup-alert.sh`'s implementation (or point
`openproject-backup-alert.service`'s `ExecStart` at a new script) — no other
part of this pipeline needs to change.
```

- [ ] **Step 3: Commit**

```bash
git add extra/backup/RESTORE.md extra/backup/README.md
git commit -m "docs(backup): add restore procedure and pipeline README"
```

---

### Task 6: End-to-end verification on a real or staging host

This task has no new files — it's the manual acceptance pass the earlier scratch tests couldn't cover (a real `openproject` CLI, real systemd, real `/backup` mount, real database).

**Interfaces:**
- Consumes: everything from Tasks 1–5, installed via Task 4's `install.sh` on a host that has the `openproject` package installed and `/backup` mounted.

- [ ] **Step 1: Install on the target host**

```bash
sudo extra/backup/install.sh
```

Expected: no errors; `systemctl list-timers openproject-backup.timer` shows a next-run time.

- [ ] **Step 2: Run a real backup manually**

```bash
sudo systemctl start openproject-backup.service
```

Expected: `systemctl status openproject-backup.service` shows `Active: inactive (dead)` with no failure, and `ls /backup/openproject/` shows today's dated folder with non-empty, checksum-valid `postgresql-dump-*.pgdump`, `attachments-*.tar.gz`, `conf-*.tar.gz` (and repository archives if this instance has any).

- [ ] **Step 3: Confirm the alert fires on failure**

```bash
sudo umount /backup   # or otherwise make it not a mountpoint temporarily
sudo systemctl start openproject-backup.service
```

Expected: the service fails, `journalctl -u openproject-backup-alert.service` shows it ran, and the configured `BACKUP_ALERT_EMAIL` recipient receives the alert. Remount `/backup` afterward.

- [ ] **Step 4: Confirm retention pruning on a real host**

```bash
sudo mkdir -p /backup/openproject/2020-01-01
sudo touch -d '40 days ago' /backup/openproject/2020-01-01
sudo systemctl start openproject-backup.service
ls /backup/openproject/   # 2020-01-01 must be gone
```

- [ ] **Step 5: Do a full restore rehearsal on a scratch VM**

Follow `extra/backup/RESTORE.md` against a disposable VM using the artifacts from Step 2, including the `openproject_db_backup_restore.sh restore ... --yes` step. Confirm the restored instance logs in and shows the expected data.

- [ ] **Step 6: Record the verification outcome**

Update the spec's "Testing / verification" section (`docs/superpowers/specs/2026-08-09-prod-backup-design.md`) with the date this was verified and on what host/version, then commit:

```bash
git add docs/superpowers/specs/2026-08-09-prod-backup-design.md
git commit -m "docs(backup): record end-to-end verification"
```
