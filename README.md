# Snom Config Server (hardened)

Dieses Repository enthält eine abgesicherte Referenz für einen Snom-Konfigurationsserver im Container auf Port `8080`.

## Wichtiges Architektur-Prinzip

- Der **Container macht nur HTTP auf Port 8080**.
- **Kein HTTPS und keine Proxy-Logik im Container**.
- TLS/HTTPS und öffentliches Routing werden vollständig vom **externen Proxy** übernommen.
- XML-Dateien liegen **nicht im Webverzeichnis**, sondern ausschließlich in `data/config/`.

## Zielbild

- Ubuntu 25.04 LXC/Container unter Proxmox
- lokaler Webserver nur auf `8080`
- Zugriffsschutz via Benutzername/Passwort (HTTP Basic Auth)
- Trennung von Code und Konfigurationsdaten
- Konfigurationsdaten werden aus privatem GitHub-Repo (`Config/`) synchronisiert

## Verzeichnisstruktur

- `public/` – Webroot mit PHP-Endpunkten
- `data/config/` – lokale Spiegelung von `Config/` aus privatem Repo (nicht öffentlich)
- `ops/` – Nginx/PHP-FPM/Systemd-Beispiele

## Schnellstart

1. Pakete installieren:
   - `sudo apt update`
   - `sudo apt install -y nginx php-fpm php-cli php-xml apache2-utils git rsync`
2. Diese Dateien nach `/opt/snom-config-server` kopieren.
3. GitHub Deploy Key anlegen (nur Read-Only) und in `~/.ssh` hinterlegen.
4. `ops/sync-config.sh` anpassen (Repo-URL + Branch + Zielpfad).
5. Nginx-Config aus `ops/nginx-snom-config.conf` aktivieren.
6. Passwortdatei erstellen:
   - `sudo htpasswd -c /etc/nginx/.htpasswd-snom admin`
7. Service neu laden:
   - `sudo nginx -t && sudo systemctl reload nginx`
8. Sync starten:
   - `sudo bash ops/sync-config.sh`

## Endpunkte

- `GET /fkey.php?file=default`
- `GET /global-settings.php?file=default`
- `GET /snomD385.php?version=10.1.215.13`
- `GET /snomD785.php?version=10.1.215.13`

Alle Endpunkte liefern XML und erwarten HTTP Basic Auth auf Webserver-Ebene.


## Automatisches Update alle 15 Minuten

1. Unit-Dateien installieren:
   - `sudo cp ops/snom-config-sync.service /etc/systemd/system/`
   - `sudo cp ops/snom-config-sync.timer /etc/systemd/system/`
2. Systemd neu laden und Timer aktivieren:
   - `sudo systemctl daemon-reload`
   - `sudo systemctl enable --now snom-config-sync.timer`
3. Status prüfen:
   - `systemctl status snom-config-sync.timer`
   - `systemctl list-timers | grep snom-config-sync`

Der Sync prüft zunächst den Remote-Commit und synchronisiert nur bei Änderungen. Dadurch ist die Last niedrig und unnötige Clones werden vermieden.


## Interaktiver Installer

Für eine komplette interaktive Einrichtung (inkl. SSH-Key-Erzeugung für GitHub Deploy Key, Repo-Konfiguration, Basic Auth und 15-Minuten-Timer):

```bash
sudo bash /opt/snom-config-server/ops/install.sh
```

Der Installer:
- fragt Repo-URL, Branch, Zielpfad und Sync-Intervall ab,
- erzeugt bei Bedarf einen neuen `ed25519` SSH-Key,
- zeigt den Public Key direkt zur Hinterlegung in GitHub,
- legt `sync-config.env` für deine Repo-Parameter an,
- richtet Nginx, Basic Auth und den systemd-Timer automatisch ein.

## Telefon-Provisioning (wichtig)

Der Installer fragt explizit nach den Telefon-Zugangsdaten (`http_user` / `http_pass`) und schreibt diese nach dem ersten Sync in `global-settings/default.xml`.

### URLs für Snom-Telefone

In den Telefonen trägst du als Settings-URL (Provisioning URL) ein:

- `http://<DEIN-HOST>:8080/global-settings.php?file=default`

Falls du Funktionstasten getrennt laden möchtest, zusätzlich:

- `http://<DEIN-HOST>:8080/fkey.php?file=default`

Firmware-Status-URL (Beispiel für D385):

- `http://<DEIN-HOST>:8080/snomD385.php?version=10.1.215.13`

> Hinweis: Wenn ein externer Proxy davor hängt, kannst du `<DEIN-HOST>` durch deine externe URL ersetzen. Der Container selbst bleibt weiterhin HTTP/8080-only.


### URL-Login für XML-Abruf

Der Installer fragt zusätzlich den **URL-Login** (HTTP Basic Auth) ab. Das sind die Zugangsdaten, die beim Abruf der XML-Dateien am Server benötigt werden.

Beispiel (nur zum Verständnis, nicht im Klartext speichern):

- `http://<URL-LOGIN-USER>:<URL-LOGIN-PASS>@<DEIN-HOST>:8080/global-settings.php?file=default`

Besser ist, im Telefon Benutzername/Passwort in den jeweiligen Feldern zu hinterlegen und die URL ohne Klartext-Passwort zu verwenden.


## Beispielstruktur für das private Config-Repo

Im Ordner `example-config-repo/` liegt eine lauffähige Beispielstruktur, wie dein privates GitHub-Config-Repo aufgebaut sein muss:

- `Config/fkey/*.xml`
- `Config/global-settings/*.xml`
- `Config/macs.json`

Du kannst diese Struktur 1:1 als Vorlage übernehmen.


## Fail2ban (optional)

Zum Schutz gegen Brute-Force auf den URL-Login sind Beispieldateien enthalten:

- `ops/fail2ban/jail.d-snom-config.local`
- `ops/fail2ban/filter.d-nginx-snom-config-auth.conf`

Beispielinstallation:

```bash
sudo apt install -y fail2ban
sudo cp ops/fail2ban/jail.d-snom-config.local /etc/fail2ban/jail.d/snom-config.local
sudo cp ops/fail2ban/filter.d-nginx-snom-config-auth.conf /etc/fail2ban/filter.d/nginx-snom-config-auth.conf
sudo systemctl restart fail2ban
sudo fail2ban-client status nginx-snom-config-auth
```


## Security-Checkliste

Wenn der Server private Daten ausliefert, solltest du mindestens Folgendes aktivieren:

- Zugriff auf Port `8080` auf Proxy-IP/CIDR begrenzen (Installer-Feld `Erlaubtes Proxy-Netz`).
- Fail2ban aktivieren (`ops/fail2ban/*`).
- Nur starke Passwörter für URL-Login/Telefon-Zugang verwenden.
- Security Updates automatisch einspielen.
- Logs überwachen (`journalctl`, `fail2ban-client`).

Details: siehe `SECURITY.md`.


## Audit-Logging

Jeder Request auf die XML/Firmware-Endpunkte wird zusätzlich in eine Audit-Datei geschrieben:

- `/var/log/snom-config/audit.log`

Pro Eintrag werden Zeitstempel, Client-IP, User, Endpoint, Statuscode und URI protokolliert.

## Panikschalter / Maintenance Mode

Wenn du den Server kurzfristig abschotten willst:

```bash
sudo touch /etc/snom-config/maintenance.on
```

Dann erhalten alle Clients `503`, außer der konfigurierten Admin-IP.

Deaktivieren:

```bash
sudo rm /etc/snom-config/maintenance.on
```
