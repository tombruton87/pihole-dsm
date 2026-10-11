# Changelog

## 1.0.0 — 2026-10-11

First release. Pi-hole v6 in Container Manager, answering DNS on port 53. The
package checks the port is free and says so if DSM's DNS Server package has
it. Your password is set at the first start and shown once; the package has
an app password of its own.

The DSM window adds:
- **Blocking:** today's figures, pause (with a timer) and resume, and the
  sites blocked most and just now.
- **Lists:** blocklists (add, remove, update), and sites always allowed or
  blocked.
- **Setup:** router steps, upstream DNS, and a new password.
- **Alerts:** a DSM notification when blocking is left off.
- **Site address:** HTTPS with DSM's certificate.

Also included: backups (with Pi-hole's own Teleporter export), updates and
removal.
