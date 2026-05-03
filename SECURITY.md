# Security Hardening Guide

## 1) Netzwerkgrenze
- Server nur auf privaten Interfaces betreiben oder an Proxy-Netz binden.
- Optional im Installer `TRUSTED_PROXY_CIDR` setzen, damit nur dein externer Proxy zugreifen darf.

## 2) Authentifizierung
- Starke, lange Passwörter für URL-Login und Telefon-HTTP-Login verwenden.
- Passwort-Rotation regelmäßig durchführen.

## 3) Sync-Sicherheit
- Deploy-Key nur **Read-Only** in GitHub eintragen.
- Key-Rechte: `0600`, keine Weitergabe.

## 4) Host-Härtung
- Unattended Security Updates aktivieren.
- `fail2ban` für Auth-Bruteforce aktivieren.
- Firewall: nur Port 8080 aus Proxy-Netz erreichbar.

## 5) Monitoring
- `journalctl -u snom-config-sync.service` auf Fehler prüfen.
- `fail2ban-client status` regelmäßig prüfen.
