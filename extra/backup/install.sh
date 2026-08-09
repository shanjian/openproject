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
