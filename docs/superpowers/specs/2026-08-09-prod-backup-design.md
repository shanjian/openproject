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

`openproject run backup` produces a complete disaster-restore set:

| Artifact | Contents |
|---|---|
| `postgresql-dump-<ts>.pgdump` | Full database dump (pg_dump custom format) |
| `attachments-<ts>.tar.gz` | Uploaded files/attachments |
| `conf-<ts>.tar.gz` | `/etc/openproject` configuration incl. secrets and `installer.dat` |
| `repositories-<ts>.tar.gz` | Git/SVN repositories (only if any exist) |

## Components

All files live in this repo under `extra/backup/` and are installed onto the
prod server.

### 1. `openproject-backup.sh` (wrapper script)

Steps, in order — any failure exits non-zero:

1. Abort unless `mountpoint -q /backup` succeeds (a missing mount must never
   silently write to the root disk).
2. Take an exclusive `flock` so runs never overlap.
3. Run `openproject run backup` (artifacts land in
   `/var/db/openproject/backup/`).
4. Move the new artifacts into `/backup/openproject/<YYYY-MM-DD>/`.
5. Verify the dated folder contains a **non-empty** pgdump, attachments
   archive, and conf archive — a "successful" but empty backup counts as a
   failure.
6. Prune `/backup/openproject/*` folders older than 30 days.

Paths, retention days, and destination are config variables at the top of the
script.

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

1. Install the same-version OpenProject package on the replacement server.
2. `pg_restore` the database dump.
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
