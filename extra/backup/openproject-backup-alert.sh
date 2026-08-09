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
