#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  install_rpm_from_run.sh <run_id> [repo]

Examples:
  install_rpm_from_run.sh 22786237226
  install_rpm_from_run.sh 22786237226 shanjian/openproject
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

RUN_ID="${1:-}"
REPO="${2:-shanjian/openproject}"

if [ -z "$RUN_ID" ]; then
  usage
  exit 1
fi

if ! [[ "$RUN_ID" =~ ^[0-9]+$ ]]; then
  echo "Error: run_id must be numeric. Received: $RUN_ID" >&2
  exit 1
fi

require_cmd gh
require_cmd find
require_cmd mktemp

if command -v dnf >/dev/null 2>&1; then
  INSTALL_TOOL="dnf"
elif command -v yum >/dev/null 2>&1; then
  INSTALL_TOOL="yum"
elif command -v rpm >/dev/null 2>&1; then
  INSTALL_TOOL="rpm"
else
  echo "Error: none of dnf, yum, rpm found on this host." >&2
  exit 1
fi

if ! command -v openproject >/dev/null 2>&1; then
  echo "Error: openproject command not found." >&2
  exit 1
fi

status="$(gh run view "$RUN_ID" --repo "$REPO" --json status --jq '.status')"
conclusion="$(gh run view "$RUN_ID" --repo "$REPO" --json conclusion --jq '.conclusion')"

if [ "$status" != "completed" ]; then
  echo "Error: run $RUN_ID is not completed yet (status=$status)." >&2
  exit 1
fi

if [ "$conclusion" != "success" ]; then
  echo "Error: run $RUN_ID did not succeed (conclusion=$conclusion)." >&2
  exit 1
fi

artifact_name="$(
  gh api "repos/$REPO/actions/runs/$RUN_ID/artifacts" \
    --jq '.artifacts
      | map(select(.name | test("^openproject-el9-rpm-[0-9]+$")))
      | sort_by(.created_at)
      | last
      | .name'
)"

if [ -z "${artifact_name:-}" ] || [ "$artifact_name" = "null" ]; then
  echo "Error: no matching RPM artifact found for run $RUN_ID in $REPO." >&2
  exit 1
fi

workdir="$(mktemp -d "/tmp/openproject-rpm-${RUN_ID}-XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

echo "Downloading artifact: $artifact_name"
gh run download "$RUN_ID" -n "$artifact_name" --repo "$REPO" --dir "$workdir"

mapfile -t rpm_files < <(
  find "$workdir" -type f -name '*.rpm' \
    ! -name '*-debuginfo*.rpm' \
    ! -name '*-debugsource*.rpm' \
    | sort
)

if [ "${#rpm_files[@]}" -eq 0 ]; then
  echo "Error: no RPM files found after downloading artifact $artifact_name." >&2
  exit 1
fi

echo "Installing RPM package(s):"
printf ' - %s\n' "${rpm_files[@]}"

case "$INSTALL_TOOL" in
  dnf)
    run_as_root dnf install -y "${rpm_files[@]}"
    ;;
  yum)
    run_as_root yum install -y "${rpm_files[@]}"
    ;;
  rpm)
    run_as_root rpm -Uvh --replacepkgs "${rpm_files[@]}"
    ;;
esac

echo "Running OpenProject configure + restart + version check"
run_as_root openproject configure
run_as_root openproject restart
run_as_root openproject run bundle exec rake version

echo "Done."
