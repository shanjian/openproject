---
sidebar_navigation:
  title: SSRF protection
---

# SSRF protection

Server-Side Request Forgery (SSRF) is an attack where a user makes the server contact a destination the user could
not reach themselves, typically an internal service or a cloud metadata endpoint such as `169.254.169.254`.

OpenProject refuses hosts that resolve to private or reserved address ranges for the features listed below.

## Where it applies

- Remote Subversion and Git repository URLs, checked only when the URL is set (see
  [Repository Integration](../repositories/#ssrf-protection-for-remote-repositories))

## Blocked address ranges

Loopback (`127.0.0.0/8`, `::1`), private networks (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fc00::/7`),
link-local (`169.254.0.0/16`, `fe80::/10`), shared address space (`100.64.0.0/10`), multicast and other reserved
ranges, as defined by the [ssrf_filter](https://github.com/arkadiyt/ssrf_filter/blob/main/lib/ssrf_filter/ssrf_filter.rb)
gem. A hostname is resolved first, so a name that points to a private address is blocked as well.

## Allowing internal hosts

If you need to link a repository on an internal server, add its address or network to the allowlist. The setting takes
a comma or space separated list of IPv4 and IPv6 addresses, including ranges:

```shell
OPENPROJECT_SSRF_PROTECTION_IP_ALLOWLIST="10.1.2.3 192.168.10.0/24"
```

For the packaged installation, set it with `openproject config:set OPENPROJECT_SSRF_PROTECTION_IP_ALLOWLIST="10.1.2.3 192.168.10.0/24"`
and restart OpenProject. An address on the allowlist is accepted even if it lies in a blocked range.
