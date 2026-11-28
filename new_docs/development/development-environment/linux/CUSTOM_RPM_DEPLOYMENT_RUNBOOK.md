# Custom RPM Deployment Runbook (RHEL/CentOS 9, Local RPM)

This runbook documents how to deploy OpenProject changes from your fork into a package-based installation by shipping your own RPMs and installing them as local files (without hosting a package repository).

It is written for:
- Current production installed from RPM packages
- RHEL 9 / CentOS 9
- Custom code based on OpenProject `17.1.2`

---

## 1) Scope and Safety

### Why this approach

With package-based installations, editing files under `/opt/openproject` is not durable and is overwritten by package upgrades.  
For persistent core changes, package your fork and upgrade via RPM.

This runbook uses the **local RPM method**:
- build RPM artifact from your fork
- copy RPM file to server
- install/upgrade with `dnf` from local file path

### Safety rules

1. Test on staging before production.
2. Take a backup and host snapshot before upgrade.
3. Treat `16 -> 17` as a major upgrade with change control.
4. Always run `openproject configure` after package install/upgrade.

---

## 2) Inputs Checklist

Collect these values first:

- Fork repo: `shanjian/openproject`
- Release base: `release-17.1.2`
- Custom packaging branch: e.g. `release-17.1.2-custom`
- Packager build URL/job for your branch (to download the RPM artifact)
- Production host SSH access
- Maintenance window

---

## 3) Prepare Release-Based Branch in Fork

Purpose: ensure your package is built from a stable release base, not edge/dev.

```bash
git checkout release-17.1.2
git pull
git checkout -b release-17.1.2-custom

# Cherry-pick or merge your custom commits
# git cherry-pick <commit>
# or merge PR branch

git push -u origin release-17.1.2-custom
```

Optional (recommended) for explicit package versioning:

```bash
git tag v17.1.2-custom.1
git push origin v17.1.2-custom.1
```

---

## 4) Build RPMs from Your Fork (Packager.io)

Purpose: produce installable EL9 RPM artifacts from your branch.

1. Open packager.io and add/configure your fork repository.
2. Trigger a build for branch `release-17.1.2-custom`.
3. Ensure target `el:9` succeeds.
4. Download the generated EL9 RPM artifact from the build output.

Expected file style:

```text
openproject-<version>-1.el9.x86_64.rpm
```

---

## 5) Rehearse on Staging (Mandatory Recommended)

Purpose: catch migration/runtime issues before production.

1. Restore latest production backup/snapshot to staging.
2. Apply the same local-RPM upgrade steps from section 7.
3. Validate:
   - Login
   - Boards and your changed features
   - Background job processing
   - Outbound email
   - Any enterprise/plugin features you use

---

## 6) Production Pre-Upgrade

Purpose: enable fast recovery.

On production host:

```bash
# 1) OpenProject application backup
sudo openproject run backup

# 2) Record currently installed app version
sudo openproject run bundle exec rake version

# 3) Optional but strongly recommended: VM/disk snapshot
```

Backup files are typically created under:

```text
/var/db/openproject/backup
```

---

## 7) Upgrade Installation with Local RPM

Purpose: install your forked package from a local file and run migrations/config.

### 7.1 Copy RPM artifact to server

Example from your workstation:

```bash
scp openproject-17.1.2-custom.1-1.el9.x86_64.rpm <user>@<host>:/tmp/
```

### 7.2 (Optional) Disable official OpenProject repo

```bash
sudo mv /etc/yum.repos.d/openproject.repo \
        /etc/yum.repos.d/openproject.repo.disabled
```

Use this if you do not want future `dnf upgrade` to pull from official repo.

### 7.3 Install/upgrade from local RPM file

```bash
sudo dnf install -y /tmp/openproject-17.1.2-custom.1-1.el9.x86_64.rpm
```

Notes:
- If version is newer than installed package, this upgrades.
- If same NEVRA and you need overwrite/reapply:
  - `sudo dnf reinstall -y /tmp/openproject-17.1.2-custom.1-1.el9.x86_64.rpm`
- If you need to move to an older build:
  - `sudo dnf downgrade -y /tmp/openproject-17.1.2-custom.0-1.el9.x86_64.rpm`

### 7.4 Apply OpenProject configure/migrations

```bash
sudo openproject configure
```

### 7.5 Restart and verify services

```bash
sudo openproject restart
sudo openproject run bundle exec rake version
```

### 7.6 Verify package source/version

```bash
rpm -qi openproject
dnf list installed openproject
```

---

## 8) Post-Deployment Verification

Purpose: confirm deployment health.

Check:

1. OpenProject UI is reachable.
2. Login works for admin and normal users.
3. Changed features behave correctly.
4. Worker queues are processing (no backlog growth).
5. No critical errors in service logs/journal.

Useful command examples:

```bash
journalctl -u openproject -n 200 --no-pager
journalctl -u openproject-worker-1 -n 200 --no-pager
```

---

## 9) Rollback Strategy

If migrations/config have been applied, simple RPM downgrade may not be sufficient.

Primary rollback path:

1. Restore VM/disk snapshot.
2. Restore OpenProject backup if needed.
3. Reinstall previous known-good RPM from file (only if schema/app state allows it).

---

## 10) Future Custom Updates

For each new custom release:

1. Add commits to `release-17.1.2-custom`.
2. Tag (e.g., `v17.1.2-custom.2`).
3. Build new RPM artifact in packager.
4. On production:

```bash
sudo dnf install -y /tmp/openproject-17.1.2-custom.2-1.el9.x86_64.rpm
sudo openproject configure
sudo openproject restart
```

---

## 11) Common Traps

1. Building from `dev`/edge instead of release branch.
- Fix: build only from `release-17.1.2-custom`.

2. Forgetting `openproject configure` after package upgrade.
- Symptom: schema/config mismatch, startup errors.
- Fix: always run `sudo openproject configure`.

3. Leaving both old and new repo active.
- Symptom: unintended package source selection.
- Fix: disable old repo file before upgrade.

4. Skipping staging test for major upgrade path.
- Fix: always rehearse on a staging clone of production data.

5. Assuming local RPM install does not replace repo-installed package.
- Symptom: fear that package manager blocks replacement.
- Fix: `dnf install /path/to/openproject-...rpm` upgrades/replaces when package name matches (`openproject`).
