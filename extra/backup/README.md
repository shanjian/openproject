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
