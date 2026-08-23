#!/usr/bin/env bash

set -Eeuo pipefail

CONFIG_PATH="${1:-/etc/httpd/conf.d/openproject.conf}"
DOCROOT="${DOCROOT:-/opt/openproject/public}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

if [[ "${EUID}" -ne 0 ]]; then
  die "run this script as root, for example: sudo $0"
fi

[[ -f "${CONFIG_PATH}" ]] || die "Apache config not found: ${CONFIG_PATH}"
command -v httpd >/dev/null || die "httpd command not found"
command -v systemctl >/dev/null || die "systemctl command not found"

[[ -d "${DOCROOT%/}/assets" ]] || die "assets directory not found: ${DOCROOT%/}/assets"

if ! httpd -M 2>/dev/null | grep -q 'deflate_module'; then
  die "mod_deflate is not loaded; no changes made. Check: httpd -M | grep deflate"
fi

vhost_tmp="$(mktemp)"
output_tmp="$(mktemp)"
trap 'rm -f "${vhost_tmp}" "${output_tmp}"' EXIT

if ! awk '
  BEGIN { in_ssl = 0; count = 0; closed = 0 }
  /^[[:space:]]*<VirtualHost[[:space:]]+\*:443[[:space:]]*>/ {
    if (in_ssl) exit 2
    in_ssl = 1
    count++
  }
  in_ssl { print }
  in_ssl && /^[[:space:]]*<\/VirtualHost[[:space:]]*>/ {
    in_ssl = 0
    closed = 1
  }
  END {
    if (count != 1 || !closed) exit 3
  }
' "${CONFIG_PATH}" >"${vhost_tmp}"; then
  die "expected exactly one complete <VirtualHost *:443> block in ${CONFIG_PATH}"
fi

add_assets_exclusion=1
if grep -Eq '^[[:space:]]*ProxyPass[[:space:]]+/assets([[:space:]]|/)[[:space:]]+!' "${vhost_tmp}"; then
  add_assets_exclusion=0
fi

add_deflate=1
if grep -Eq '^[[:space:]]*AddOutputFilterByType[[:space:]]+DEFLATE[[:space:]].*application/javascript' "${vhost_tmp}"; then
  add_deflate=0
fi

if ! awk -v add_assets="${add_assets_exclusion}" -v add_deflate="${add_deflate}" '
  BEGIN { in_ssl = 0; assets_inserted = 0; deflate_inserted = 0 }
  /^[[:space:]]*<VirtualHost[[:space:]]+\*:443[[:space:]]*>/ { in_ssl = 1 }

  {
    if (in_ssl && add_assets && $1 == "ProxyPass" && $2 == "/" && index($3, "http://127.0.0.1:6000/") == 1) {
      print "  ProxyPass /assets !"
      assets_inserted = 1
    }

    if (in_ssl && add_deflate && $0 ~ /^[[:space:]]*<\/VirtualHost[[:space:]]*>/) {
      print "  <IfModule mod_deflate.c>"
      print "    AddOutputFilterByType DEFLATE application/javascript"
      print "    AddOutputFilterByType DEFLATE text/javascript"
      print "    AddOutputFilterByType DEFLATE text/css"
      print "    AddOutputFilterByType DEFLATE application/json"
      print "  </IfModule>"
      deflate_inserted = 1
    }

    print

    if (in_ssl && $0 ~ /^[[:space:]]*<\/VirtualHost[[:space:]]*>/) {
      in_ssl = 0
    }
  }

  END {
    if (add_assets && !assets_inserted) exit 4
    if (add_deflate && !deflate_inserted) exit 5
  }
' "${CONFIG_PATH}" >"${output_tmp}"; then
  die "could not find the expected catch-all ProxyPass inside the HTTPS vhost"
fi

if cmp -s "${CONFIG_PATH}" "${output_tmp}"; then
  echo "No changes needed; Apache configuration already contains the requested rules."
  exit 0
fi

echo "Planned changes:"
diff -u "${CONFIG_PATH}" "${output_tmp}" || true

backup_path="${CONFIG_PATH}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp -a -- "${CONFIG_PATH}" "${backup_path}"

config_mode="$(stat -c '%a' "${CONFIG_PATH}")"
config_uid="$(stat -c '%u' "${CONFIG_PATH}")"
config_gid="$(stat -c '%g' "${CONFIG_PATH}")"
install -o "${config_uid}" -g "${config_gid}" -m "${config_mode}" "${output_tmp}" "${CONFIG_PATH}"

if ! httpd -t; then
  cp -a -- "${backup_path}" "${CONFIG_PATH}"
  die "Apache validation failed; restored ${backup_path}"
fi

if ! systemctl reload httpd; then
  cp -a -- "${backup_path}" "${CONFIG_PATH}"
  httpd -t >/dev/null 2>&1 || true
  systemctl reload httpd >/dev/null 2>&1 || true
  die "Apache reload failed; restored ${backup_path}"
fi

echo "Apache reloaded successfully. Backup: ${backup_path}"
echo "The /assets URL tree is now excluded from the backend proxy."
echo "Verify a representative asset with:"
echo "  curl -k -sS -H 'Accept-Encoding: gzip' -D - -o /dev/null https://openpr.epochbase.com/assets/<asset-path>"
