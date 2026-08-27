#!/usr/bin/env bash
#
# Bootstrap a fresh Ubuntu VM for OpenProject local (non-Docker) development,
# mirroring the toolchain documented in
# docs/development/development-environment/linux/SETUP_RUNBOOK_FROM_AGENT.md
#
# Usage:
#   1. Copy this file to the new VM (scp, curl, or paste).
#   2. ./openproject_new_devbox_setup.sh
#   3. Follow the printed instructions for `gh auth login` and starting `bin/dev`.
#
# The script is idempotent: re-running it after a partial failure skips
# steps that already succeeded.

set -euo pipefail

RUBY_VERSION="3.4.7"
NODE_VERSION="22.21.0"
NVM_VERSION="v0.40.3"
REPO_URL="https://github.com/shanjian/openproject.git"
UPSTREAM_URL="https://github.com/opf/openproject.git"
CLONE_DIR="${CLONE_DIR:-$HOME/srcs/openproject}"
DEFAULT_BRANCH="epic"

log()  { printf '\n==> %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
log "1) System build dependencies"
sudo apt-get update
sudo apt-get install -y \
  build-essential curl git libssl-dev zlib1g-dev libreadline-dev \
  libyaml-dev libxml2-dev libxslt1-dev libffi-dev libgdbm-dev \
  libncurses5-dev libpq-dev postgresql-client \
  postgresql postgresql-contrib \
  ruby-foreman \
  gh

# ---------------------------------------------------------------------------
log "2) Ruby ${RUBY_VERSION} via rbenv"
if [ ! -d "$HOME/.rbenv" ]; then
  git clone https://github.com/rbenv/rbenv.git "$HOME/.rbenv"
  git clone https://github.com/rbenv/ruby-build.git "$HOME/.rbenv/plugins/ruby-build"
fi
grep -qxF 'export PATH="$HOME/.rbenv/bin:$PATH"' "$HOME/.bashrc" || \
  echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> "$HOME/.bashrc"
grep -qxF 'eval "$(rbenv init - bash)"' "$HOME/.bashrc" || \
  echo 'eval "$(rbenv init - bash)"' >> "$HOME/.bashrc"

export PATH="$HOME/.rbenv/bin:$PATH"
eval "$("$HOME/.rbenv/bin/rbenv" init - bash)"

rbenv versions --bare | grep -qx "$RUBY_VERSION" || rbenv install "$RUBY_VERSION"
rbenv global "$RUBY_VERSION"
gem install bundler --conservative

# ---------------------------------------------------------------------------
log "3) Node ${NODE_VERSION} via nvm"
if [ ! -d "$HOME/.nvm" ]; then
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

nvm install "$NODE_VERSION"
nvm alias default "$NODE_VERSION"
corepack enable || true

# ---------------------------------------------------------------------------
log "4) PostgreSQL role and databases"
sudo systemctl enable --now postgresql
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='dev'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE ROLE dev WITH LOGIN SUPERUSER;"
sudo -u postgres createdb -O dev openproject_development 2>/dev/null || true
sudo -u postgres createdb -O dev openproject_test 2>/dev/null || true

# ---------------------------------------------------------------------------
log "5) GitHub CLI auth (interactive — needed to clone/push over HTTPS)"
if ! gh auth status >/dev/null 2>&1; then
  gh auth login
fi
gh auth setup-git

# ---------------------------------------------------------------------------
log "6) Clone OpenProject"
if [ ! -d "$CLONE_DIR/.git" ]; then
  mkdir -p "$(dirname "$CLONE_DIR")"
  git clone "$REPO_URL" "$CLONE_DIR"
fi
cd "$CLONE_DIR"
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
git checkout "$DEFAULT_BRANCH"

# ---------------------------------------------------------------------------
log "7) config/database.yml"
[ -f config/database.yml ] || cp config/database.yml.example config/database.yml

# ---------------------------------------------------------------------------
log "8) Ruby gems"
bundle check || bundle install

# ---------------------------------------------------------------------------
log "9) Frontend dependencies"
(cd frontend && npm ci)
(cd extensions/op-blocknote-hocuspocus && npm ci)

# ---------------------------------------------------------------------------
log "10) Database migrate + seed"
bundle exec rake db:migrate
bundle exec rake db:seed

# ---------------------------------------------------------------------------
log "11) Register linked plugin frontends"
bundle exec rails openproject:plugins:register_frontend

# ---------------------------------------------------------------------------
log "12) Git hooks (rubocop/eslint on commit)"
bundle exec lefthook install

cat <<'EOF'

==> Done.

Next steps:
  cd ~/srcs/openproject   # or $CLONE_DIR if you overrode it
  OPENPROJECT_COLLABORATIVE__EDITING__HOCUSPOCUS__SECRET=dev-secret bin/dev

Default seeded login: admin / admin

Rails app:    http://localhost:5000
Frontend dev: http://localhost:4200 (must also be reachable — see
              docs/development/development-environment/linux/SETUP_RUNBOOK_FROM_AGENT.md
              section 11 for SSH port forwarding)

If you hit issues, check
docs/development/development-environment/linux/SETUP_RUNBOOK_FROM_AGENT.md —
it documents the traps we hit (missing database.yml, rbenv not loaded in
non-interactive shells, missing foreman, hocuspocus secret, 2FA popping up
locally, etc).
EOF
