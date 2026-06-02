# OpenProject Local Setup Runbook (What Was Actually Run)

This file documents the exact local setup flow we executed in this environment, including why each step exists and which traps we hit.

## 0) Install Ruby, Node.js, npm, and Bundler (prerequisites)

Purpose: install the exact toolchain needed by OpenProject before dependency install/build.

### 0.1 Install system build dependencies

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential curl git libssl-dev zlib1g-dev libreadline-dev \
  libyaml-dev libxml2-dev libxslt1-dev libffi-dev libgdbm-dev \
  libncurses5-dev libpq-dev postgresql-client
```

### 0.2 Install Ruby 3.4.7 via rbenv

```bash
git clone https://github.com/rbenv/rbenv.git ~/.rbenv
git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
echo 'eval "$(rbenv init - bash)"' >> ~/.bashrc
export PATH="$HOME/.rbenv/bin:$PATH"
eval "$(~/.rbenv/bin/rbenv init - bash)"
rbenv install 3.4.7
rbenv global 3.4.7
ruby -v
```

### 0.3 Install Bundler (2.x)

```bash
gem install bundler
bundle -v
```

### 0.4 Install Node.js 22.21.x (npm is included) via nvm

```bash
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm install 22.21.0
nvm alias default 22.21.0
node -v
npm -v
```

## 1) Verify runtime versions

Purpose: avoid subtle build/runtime failures from version mismatch.

```bash
cat .ruby-version
ruby -v
node -v
npm -v
bundle -v
```

Expected:
- Ruby `3.4.7`
- Node `22.x` (project expects `^22.21.0`)
- Bundler `2.x`

## 2) Configure database file for local (non-Docker) setup

Purpose: Rails cannot boot/migrate without `config/database.yml`.

```bash
cp config/database.yml.example config/database.yml
```

Then edit `config/database.yml` with your local PostgreSQL credentials (we used user `dev` for `development` and `test`).

## 3) Ensure PostgreSQL is running and DB objects exist

Purpose: migrations and app boot require reachable PostgreSQL + matching role/databases.

```bash
sudo systemctl enable --now postgresql
sudo -u postgres psql -c "CREATE ROLE dev WITH LOGIN SUPERUSER;" || true
sudo -u postgres createdb -O dev openproject_development || true
sudo -u postgres createdb -O dev openproject_test || true
```

## 4) Install Ruby gems

Purpose: install backend dependencies.

```bash
bundle install
```

## 5) Install frontend dependencies

Purpose: install Angular/frontend deps used by `bin/dev`.

```bash
npm ci
(cd extensions/op-blocknote-hocuspocus && npm ci)
```

## 6) Install process manager used by `bin/dev`

Purpose: `bin/dev` expects `overmind` or `foreman`.

We installed `foreman` via apt in this environment:

```bash
sudo apt-get update
sudo apt-get install -y ruby-foreman
```

## 7) Run database migrations

Purpose: create/update schema.

```bash
bundle exec rake db:migrate
```

## 8) Seed initial data and admin account

Purpose: create base data + default login account.

```bash
bundle exec rake db:seed
```

Default seeded account in development:
- username: `admin`
- password: `admin`

## 9) Register linked frontend plugins

Purpose: generate linked plugin frontend files required by Angular build.

```bash
bundle exec rails openproject:plugins:register_frontend
```

## 10) Start all services

Purpose: boot Rails, frontend dev server, worker, collaborative editing service.

```bash
OPENPROJECT_COLLABORATIVE__EDITING__HOCUSPOCUS__SECRET=dev-secret bin/dev
```

## 11) Access URL and required ports

Purpose: avoid partial UI loads.

- Rails app: `http://localhost:5000`
- Frontend dev assets: port `4200` is also required in dev mode

If using SSH port forwarding, forward both ports:

```bash
ssh -N \
  -L 5000:127.0.0.1:5000 \
  -L 4200:127.0.0.1:4200 \
  <user>@<remote-host>
```

If asset URLs are not browser-reachable, set:

```bash
export OPENPROJECT_CLI_PROXY=http://<browser-reachable-host>:<port>
```

## 12) ESLint usage (frontend lint)

Purpose: validate TypeScript/JavaScript code style and correctness.

```bash
cd frontend
npx eslint src/
```

## 13) After code changes: recompile or just restart?

Purpose: clarify when you can rely on dev watchers vs. when extra steps are required.

In this setup, `bin/dev` runs Rails + frontend watchers, so most source changes do **not** require a manual recompile.

Start/restart command:

```bash
OPENPROJECT_COLLABORATIVE__EDITING__HOCUSPOCUS__SECRET=dev-secret bin/dev
```

Use additional steps only when relevant:

1. `Gemfile` / `Gemfile.lock` changed
- Run: `bundle install`
- Then restart `bin/dev`

2. `package.json` / lockfile / frontend dependency changed
- Run: `npm ci` (and plugin package install if needed)
- Then restart `bin/dev`

3. Database migration added/changed
- Run: `bundle exec rake db:migrate`

4. Environment variables or Rails initializers changed
- Restart `bin/dev`

5. Linked plugin frontend wiring changed
- Run: `bundle exec rails openproject:plugins:register_frontend`
- Then restart `bin/dev`

---

## Traps We Encountered (and Fixes)

1. Missing `config/database.yml`
- Symptom: `Cannot load database configuration. No such file - ["config/database.yml"]`
- Why: local setup needs this file; Docker docs explicitly say the opposite.
- Fix: copy from example and set valid DB credentials.

2. `rbenv` not loaded in non-interactive shell
- Symptom: wrong Ruby/Bundler from PATH in scripted command execution.
- Why: shell startup may skip `rbenv` init in non-interactive sessions.
- Fix: ensure `~/.rbenv/shims` and `~/.rbenv/bin` are in PATH (or use a login shell with proper init).

3. `foreman`/`overmind` missing
- Symptom: `Neither overmind, nor foreman is installed`.
- Fix: install one of them (`gem install foreman` or OS package `ruby-foreman`).

4. Frontend assets failing with `ERR_CONNECTION_REFUSED` on `:4200`
- Symptom: login page loads but JS/CSS fail and app is broken.
- Why: only port `5000` forwarded/open; dev assets are served from `4200`.
- Fix: forward/open port `4200` too (and optionally set `OPENPROJECT_CLI_PROXY`).

5. Hocuspocus secret missing
- Symptom: `bin/dev` process for collaborative editing fails.
- Fix: set `OPENPROJECT_COLLABORATIVE__EDITING__HOCUSPOCUS__SECRET`.

6. No admin login after migrate
- Symptom: login fails even though app boots.
- Why: `db:migrate` does not create the admin user.
- Fix: run `bundle exec rake db:seed` to create `admin/admin` (default dev seed).

7. `bundler: failed to load command: rails ... Bundler::GemNotFound`
- Symptom: `bin/dev` fails right after restart with many “Could not find <gem-version>” messages.
- Why: active branch/revision changed and local gems for that lockfile are not installed yet.
- Fix:
  - `bundle install`
  - verify with `bundle exec rails -v`
  - then restart `bin/dev`
