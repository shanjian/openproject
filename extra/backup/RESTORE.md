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
