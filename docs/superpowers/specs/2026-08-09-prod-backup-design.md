# Production Backup Mechanism — Design

**Date:** 2026-08-09
**Status:** Draft (pending approval)

## Goal

Disaster-recovery backups for the OpenProject production server (packaged
DEB/RPM install). A `/backup` directory is mounted on the server and is the
backup destination.

## Requirements (from discussion)

- **Frequency:** daily (worst-case data loss: 24h).
- **Retention:** 30 days of daily backups on `/backup`.
- **Alerting:** email on failure now; clean seam to hook into a future
  monitoring/alert system (TODO).
- **Approach chosen:** Option A — wrap the vendor-supported
  `openproject run backup` tool (over custom pg_dump+rsync, or restic).

## What gets backed up

The user already has a manually-copied helper script,
`script/migration/openproject_db_backup_restore.sh`, in production use for
one-off DB snapshots (`pg_dump --format=custom --no-owner`, plus a
`.sha256` checksum alongside the dump, and a matching `restore` subcommand
with a typed confirmation prompt). The nightly pipeline reuses this script
verbatim for the database portion — no duplicated pg_dump/pg_restore logic —
and extends its same checksum convention to the other artifacts:

| Artifact | Produced by | Contents |
|---|---|---|
| `postgresql-dump-<ts>.pgdump` + `.sha256` | `openproject_db_backup_restore.sh backup` | Full database dump |
| `attachments-<ts>.tar.gz` + `.sha256` | new logic in the wrapper | Uploaded files/attachments |
| `conf-<ts>.tar.gz` + `.sha256` | new logic in the wrapper | `/etc/openproject` configuration incl. secrets and `installer.dat` |
| `git-repositories-<ts>.tar.gz` / `svn-repositories-<ts>.tar.gz` + `.sha256` | new logic in the wrapper | Git/SVN repositories (only if either exists) |

This replaces the earlier idea of shelling out to `openproject run backup`
(the packaging-script wrapper): that command doesn't propagate failure (a
failed `tar` just logs "failed" to stderr and the script still exits 0), and
it duplicates DB-dump logic the team already has a trusted script for.
Building each artifact directly means every step's exit code is meaningful
and every artifact gets a checksum, matching the existing script's pattern.

## Components

All files live in this repo under `extra/backup/` and are installed onto the
prod server.

### 1. `openproject-backup.sh` (wrapper script)

Steps, in order — any failure exits non-zero:

1. Abort unless `mountpoint -q /backup` succeeds (a missing mount must never
   silently write to the root disk).
2. Take an exclusive `flock` so runs never overlap.
3. Build each artifact directly into a staging folder:
   - Database: `openproject_db_backup_restore.sh backup` (deployed
     alongside this script — see below), pointed at the staging folder via
     its `BACKUP_DIR` env var. Produces the `.pgdump` + `.sha256`.
   - Attachments, config, and repositories (if present): tar + gzip, each
     immediately followed by a `sha256sum` checksum file, same convention
     as the DB script.
4. Verify every required artifact (pgdump, attachments, conf) is present,
   **non-empty**, and its checksum verifies — a "successful" but empty or
   corrupt backup counts as a failure.
5. Rename the staging folder into place as
   `/backup/openproject/<YYYY-MM-DD>/` (atomic — no partial folder is ever
   visible under its final name).
6. Prune `/backup/openproject/*` folders older than 30 days.

Paths, retention days, and destination are config variables at the top of the
script. `openproject_db_backup_restore.sh` must be present next to this
script (or on `PATH`) — the installer deploys both together.

### 2. `openproject-backup.service` + `openproject-backup.timer`

- Timer: daily at **02:30**, `Persistent=true` (a server that was off at
  02:30 runs the backup at next boot).
- Service: `Type=oneshot`, runs the wrapper as root,
  `OnFailure=openproject-backup-alert.service`.
- All output goes to the journal: `journalctl -u openproject-backup`.

### 3. `openproject-backup-alert.service` (the alerting seam)

- Today: sends a failure email via the host's `sendmail`/`mail`.
- **TODO (requested):** when a monitoring/alert system is adopted, replace
  this unit's `ExecStart` (or add a webhook call) — nothing else changes.

## Error handling

Missing mount, backup-command failure, empty artifacts, and disk-full on
`/backup` all surface as non-zero exit → systemd marks the run failed →
alert email fires. No partial dated folder is left behind on failure
(write to a `.tmp` folder, rename into place on success).

## Restore procedure

Documented in `extra/backup/RESTORE.md`:

1. Install the same-version OpenProject package on the replacement server,
   plus a copy of `openproject_db_backup_restore.sh`.
2. `openproject_db_backup_restore.sh restore <dump>.pgdump --yes` — reuses
   the existing, already-trusted restore path (stops the service,
   `pg_restore --clean --if-exists --no-owner`, restarts the service).
3. Untar `conf-*.tar.gz` to `/etc/openproject`, attachments archive to the
   attachments directory (and repositories archive if present).
4. Run `openproject configure`.

Recommendation: perform a test restore once or twice a year — an untested
backup is a hope, not a backup.

## Testing / verification

- Run the service once manually: `systemctl start openproject-backup.service`;
  confirm a dated folder with non-empty artifacts appears on `/backup`.
- Simulate failure (e.g. unmount `/backup`) and confirm the alert email
  arrives.
- Confirm pruning by creating a fake >30-day-old dated folder.

## Out of scope (noted for later)

- **Offsite copy:** if `/backup` is local disk, fire/ransomware can take out
  server and backups together. If it is a NAS/remote mount, machine loss is
  covered. A true offsite copy (e.g. restic to S3 — Option C) is a natural
  future upgrade.
- Monitoring-system integration (seam prepared, see TODO above).
