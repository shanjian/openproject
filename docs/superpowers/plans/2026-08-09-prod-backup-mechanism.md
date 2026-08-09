# Production Backup Mechanism Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a systemd-driven nightly backup for the packaged (DEB/RPM) OpenProject production install that wraps the vendor `openproject run backup` tool, lands dated backup sets on the mounted `/backup` volume with 30-day retention, and emails on failure.

**Architecture:** A bash wrapper (`openproject-backup.sh`) runs `openproject run backup` (which already writes a full disaster-restore set — DB dump, attachments, config, repositories — into `/var/db/openproject/backup`), moves the fresh artifacts into a dated folder under `/backup/openproject/`, verifies they're non-empty, and prunes folders older than the retention window. A systemd timer fires it nightly; on failure systemd runs a second unit that sends an alert email. All of it is plain bash + systemd unit files — no new language runtime or dependency.

**Tech Stack:** bash, systemd (service + timer units), the existing `packaging/scripts/backup` tool shipped by the DEB/RPM package (invoked as `openproject run backup`).

## Global Constraints

- Frequency: daily. (spec: "Frequency")
- Retention: 30 days of dated backup folders on `/backup`. (spec: "Retention")
- Alerting: email on failure now, with a single well-defined seam (`openproject-backup-alert.sh`) to swap in a monitoring/alerting system later — do not hardcode email-sending logic anywhere else. (spec: "Alerting", "TODO")
- Never write to `/backup` if it isn't actually mounted — abort instead. (spec: "Error handling")
- Never leave a partially-written dated folder behind on failure. (spec: "Error handling")
- Target deployment is the **packaged install** (`openproject` CLI available on the host as root), not Docker. (spec: "What gets backed up")
- All new files live under `extra/backup/` in this repo, matching the existing `extra/Apache`, `extra/mail_handler` convention of shipping ops artifacts outside the Rails app tree.

## Codebase facts that shape this plan

- `packaging/scripts/backup` (already in this repo, unmodified by this plan) is what `openproject run backup` runs. It writes into `/var/db/${APP_NAME}/backup` (`APP_NAME` defaults to `openproject`) and never cleans up after itself — every run adds new timestamped files on top of old ones.
- It produces, depending on what's configured/present: `postgresql-dump-<ts>.pgdump`, `attachments-<ts>.tar.gz`, `conf-<ts>.tar.gz` (always, if `/etc/openproject` exists), and optionally `git-repositories-<ts>.tar.gz` / `svn-repositories-<ts>.tar.gz` (only if those directories exist). **Correction vs. the design doc's table:** there is no single `repositories-<ts>.tar.gz` — it's two separately-named, both-optional archives.
- Critically, `packaging/scripts/backup` does **not** propagate failure: a failed `tar` for one artifact just prints `failed` to stderr and the script keeps going, exiting 0 regardless. Our wrapper must not trust its exit code — it must check the actual files on disk.
- No `bats`/`shellcheck` are installed in this environment, so tasks below verify scripts with `bash -n` (syntax) and small fixture-driven scratch tests instead of a bash test framework. `systemd-analyze verify` is available for the unit files.

## File Structure

```
extra/backup/
  openproject-backup.sh          # main wrapper: run backup, move to dated folder, verify, prune
  openproject-backup-alert.sh    # failure alert (email today; the future monitoring seam)
  openproject-backup.service     # systemd oneshot unit, OnFailure=openproject-backup-alert.service
  openproject-backup.timer       # systemd timer, daily 02:30, Persistent=true
  openproject-backup-alert.service
  install.sh                    # copies scripts+units into place, enables the timer
  RESTORE.md                    # disaster-restore steps
  README.md                     # what this is, config vars, how to install/test
```

Each script is self-contained (single responsibility: the wrapper backs up, the alert script alerts, `install.sh` installs). Config is via environment variables with defaults baked in, overridable through `/etc/openproject-backup.env` (loaded by the systemd units via `EnvironmentFile=-`).

## Interfaces between tasks

- `openproject-backup.sh` exits `0` on a verified, complete backup; non-zero (with a message on stderr) on any failure. It takes no arguments; all configuration is via env vars `APP_NAME`, `SOURCE_DIR`, `DEST_ROOT`, `RETENTION_DAYS`, `LOCK_FILE`, `DRY_RUN`.
- `openproject-backup-alert.sh` takes no arguments, exits `0` if it successfully sent an alert, non-zero otherwise. Configuration via `BACKUP_ALERT_EMAIL`, `APP_NAME`.
- `openproject-backup.service` has `OnFailure=openproject-backup-alert.service` — this is the only wiring between the two; the alert unit doesn't know why the backup failed, only that it did.
- `install.sh` assumes both scripts and both service units and the timer unit exist at fixed relative paths inside `extra/backup/` (the same directory it lives in).

---

### Task 1: Backup wrapper script

**Files:**
- Create: `extra/backup/openproject-backup.sh`
- Test (scratch, not committed): a fixture harness run manually per the steps below

**Interfaces:**
- Produces: an executable `extra/backup/openproject-backup.sh`, invoked with no args, honoring env vars `APP_NAME` (default `openproject`), `SOURCE_DIR` (default `/var/db/${APP_NAME}/backup`), `DEST_ROOT` (default `/backup/openproject`), `RETENTION_DAYS` (default `30`), `LOCK_FILE` (default `/run/lock/openproject-backup.lock`), `DRY_RUN` (default `0`), `BACKUP_MOUNT` (default `/backup`, the mountpoint that must be present before anything runs). Exit code `0` = verified success.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-openproject}"
SOURCE_DIR="${SOURCE_DIR:-/var/db/${APP_NAME}/backup}"
DEST_ROOT="${DEST_ROOT:-/backup/openproject}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
LOCK_FILE="${LOCK_FILE:-/run/lock/openproject-backup.lock}"
DRY_RUN="${DRY_RUN:-0}"
BACKUP_MOUNT="${BACKUP_MOUNT:-/backup}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

exec 9>"$LOCK_FILE"
flock -n 9 || die "another backup run is already in progress (lock: $LOCK_FILE)"

mountpoint -q "$BACKUP_MOUNT" || die "$BACKUP_MOUNT is not mounted, refusing to run"

DATE_DIR="$(date +%Y-%m-%d)"
DEST_TMP="${DEST_ROOT}/.tmp-${DATE_DIR}"
DEST_FINAL="${DEST_ROOT}/${DATE_DIR}"

mkdir -p "$SOURCE_DIR" "$DEST_ROOT"
rm -rf "$DEST_TMP"
mkdir -p "$DEST_TMP"

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1: skipping '${APP_NAME} run backup'"
else
  log "running '${APP_NAME} run backup'"
  "$APP_NAME" run backup
fi

shopt -s nullglob
source_files=("$SOURCE_DIR"/*)
shopt -u nullglob
[ "${#source_files[@]}" -gt 0 ] || die "no backup artifacts found in $SOURCE_DIR"

for f in "${source_files[@]}"; do
  mv "$f" "$DEST_TMP/"
done

for pattern in 'postgresql-dump-*' 'attachments-*' 'conf-*'; do
  shopt -s nullglob
  matches=("$DEST_TMP"/$pattern)
  shopt -u nullglob
  [ "${#matches[@]}" -gt 0 ] || die "missing expected artifact matching '$pattern' in $DEST_TMP"
  for m in "${matches[@]}"; do
    [ -s "$m" ] || die "artifact $m is empty"
  done
done

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

- [ ] **Step 4: Build a scratch fixture and confirm the happy path**

Run this from the repo root (uses only `/tmp`, no root needed, no real `openproject` CLI):

```bash
SCRATCH=$(mktemp -d)
mkdir -p "$SCRATCH/backup_mount/openproject" "$SCRATCH/var_source"
mount --bind "$SCRATCH/backup_mount" "$SCRATCH/backup_mount"   # makes it a real mountpoint
echo fakedump   > "$SCRATCH/var_source/postgresql-dump-20260809010000.pgdump"
echo fakeattach > "$SCRATCH/var_source/attachments-20260809010000.tar.gz"
echo fakeconf   > "$SCRATCH/var_source/conf-20260809010000.tar.gz"

BACKUP_MOUNT="$SCRATCH/backup_mount" \
SOURCE_DIR="$SCRATCH/var_source" \
DEST_ROOT="$SCRATCH/backup_mount/openproject" \
LOCK_FILE="$SCRATCH/lock" \
DRY_RUN=1 \
  extra/backup/openproject-backup.sh
echo "exit=$?"
ls "$SCRATCH/backup_mount/openproject"
umount "$SCRATCH/backup_mount"
rm -rf "$SCRATCH"
```

Expected: `exit=0`, and `ls` shows one directory named like `2026-08-09` containing the three fixture files. `mount --bind` requires root/sudo — if unavailable in this environment, substitute `BACKUP_MOUNT=/tmp` for the fixture run (`/tmp` is virtually always its own mountpoint) instead of creating one.

- [ ] **Step 5: Confirm the failure paths**

Run three variants and confirm each exits non-zero with a clear message on stderr:

1. Unmounted destination: point `BACKUP_MOUNT` at a plain (non-mountpoint) empty scratch directory instead of a bind mount — expect `"is not mounted, refusing to run"`.
2. Empty artifact: repeat Step 4's fixture but make `attachments-*.tar.gz` a zero-byte file (`: > "$SCRATCH/var_source/attachments-....tar.gz"`) — expect `"artifact ... is empty"`.
3. Missing artifact: repeat Step 4's fixture but omit `conf-*.tar.gz` entirely — expect `"missing expected artifact matching 'conf-*'"`.

- [ ] **Step 6: Confirm retention pruning**

Reuse Step 4's fixture, but before running the script create an old dated folder and set its mtime beyond the retention window, then confirm it's removed after a successful run:

```bash
mkdir -p "$SCRATCH/backup_mount/openproject/2020-01-01"
touch -d '40 days ago' "$SCRATCH/backup_mount/openproject/2020-01-01"
# ... run the script as in Step 4 ...
ls "$SCRATCH/backup_mount/openproject"   # 2020-01-01 must be gone, today's dir must be present
```

- [ ] **Step 7: Commit**

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
env -i PATH=/nonexistent extra/backup/openproject-backup-alert.sh
echo "exit=$?"
```

Expected: `"no mail transport available"` on stderr, `exit=1` (nonzero — note `env -i PATH=/nonexistent` won't find `hostname`/`date` either in a real minimal PATH; run this check specifically for the mail-transport branch by temporarily hiding only `mail`/`sendmail` if your `hostname`/`date` aren't on `/nonexistent`, e.g. `PATH="$SCRATCH_EMPTY_BIN:$(dirname "$(command -v hostname)"):$(dirname "$(command -v date)")"` where `$SCRATCH_EMPTY_BIN` contains no mail/sendmail).

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
- Consumes: all five files from Tasks 1–3, located in the same directory as `install.sh` itself (`extra/backup/`).
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

install -m 0755 "$SRC_DIR/openproject-backup.sh" /usr/local/bin/openproject-backup.sh
install -m 0755 "$SRC_DIR/openproject-backup-alert.sh" /usr/local/bin/openproject-backup-alert.sh
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

- [ ] **Step 4: Commit**

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
- Consumes: the artifact naming and layout produced by Tasks 1–4 (dated folders under `/backup/openproject/<YYYY-MM-DD>/` containing `postgresql-dump-*.pgdump`, `attachments-*.tar.gz`, `conf-*.tar.gz`, and optionally `git-repositories-*.tar.gz` / `svn-repositories-*.tar.gz`).
- Produces: none (documentation only).

- [ ] **Step 1: Write `extra/backup/RESTORE.md`**

```markdown
# Restoring from a backup

Pick the dated folder to restore from, e.g. `/backup/openproject/2026-08-09/`.

1. Install the **same version** of the OpenProject package on the
   replacement server that produced the backup (`openproject --version`
   on the old host tells you which).

2. Stop the app before restoring data:

   ```bash
   sudo openproject scale web=0 worker=0
   ```

3. Restore the database:

   ```bash
   sudo -u postgres pg_restore --clean --if-exists \
     -d "$(sudo openproject config:get DATABASE_URL)" \
     /backup/openproject/2026-08-09/postgresql-dump-*.pgdump
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
   sudo openproject scale web=1 worker=1
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
install, using the vendor `openproject run backup` tool under the hood.

## What it does

`openproject-backup.sh` runs `openproject run backup`, moves the resulting
artifacts from `/var/db/openproject/backup` into a dated folder under
`/backup/openproject/<YYYY-MM-DD>/`, verifies the database dump, attachments
archive, and config archive are all non-empty, and prunes dated folders older
than `RETENTION_DAYS` (default 30). A systemd timer runs it nightly at
02:30; on failure, `openproject-backup-alert.service` sends an email.

## Install

Requires the `/backup` volume to already be mounted on this host.

```bash
sudo extra/backup/install.sh
```

This installs the scripts to `/usr/local/bin/`, the units to
`/etc/systemd/system/`, creates `/etc/openproject-backup.env` for overrides,
and enables + starts the timer.

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

This task has no new files — it's the manual acceptance pass the earlier scratch tests couldn't cover (a real `openproject` CLI, real systemd, real `/backup` mount).

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

Expected: `systemctl status openproject-backup.service` shows `Active: inactive (dead)` with no failure, and `ls /backup/openproject/` shows today's dated folder with non-empty `postgresql-dump-*.pgdump`, `attachments-*.tar.gz`, `conf-*.tar.gz` (and repository archives if this instance has any).

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

Follow `extra/backup/RESTORE.md` against a disposable VM using the artifacts from Step 2. Confirm the restored instance logs in and shows the expected data.

- [ ] **Step 6: Record the verification outcome**

Update the spec's "Testing / verification" section (`docs/superpowers/specs/2026-08-09-prod-backup-design.md`) with the date this was verified and on what host/version, then commit:

```bash
git add docs/superpowers/specs/2026-08-09-prod-backup-design.md
git commit -m "docs(backup): record end-to-end verification"
```
