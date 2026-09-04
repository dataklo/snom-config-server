# Snom Config Server für Ubuntu-/Proxmox-CT

Dieses Repository installiert einen Snom-Provisioning-Server auf einem Ubuntu-Container. Die Domain zeigt ausschließlich auf den automatisch erzeugten Ordner `www`; die aus dem privaten Git-Repository geladenen XML-Dateien liegen daneben in `private/config` und können deshalb niemals als statische Dateien vom Webserver ausgeliefert werden.

## Architektur

Bei den Standardwerten entsteht folgende Trennung:

```text
/srv/snom-config/                 # FTPS-/SFTP-Chroot, root-owned
├── www/                          # einziger Webroot; PHP-Endpunkte
└── private/config/               # sensible Repo-Daten; nicht öffentlich
/opt/snom-config-server/          # Anwendung und Betriebs-Skripte
/etc/snom-config/                 # Deploy Key und Secrets (0600)
```

Nginx lauscht auf HTTP-Port `8080`; TLS und die öffentliche Domain können weiterhin am vorgeschalteten Proxy enden. Dateiübertragung ist per **explizitem FTPS auf Port 21** (passive Ports `40000–40100`) und **SFTP auf Port 22** möglich. Beide verwenden den beim Setup abgefragten Benutzer. Dessen SFTP-Sitzung ist auf den Site-Root beschränkt. Das Verzeichnis `private` ist nur für root und PHP lesbar.

## Installation per Copy & Paste

Auf einem frischen Ubuntu-CT kann die komplette Installation mit diesem einen Befehl gestartet werden:

```bash
curl -fsSL https://raw.githubusercontent.com/dataklo/snom-config-server/main/install-ubuntu-ct.sh \
  -o /tmp/install-snom-config.sh \
  && sudo bash /tmp/install-snom-config.sh
```

Das Bootstrap-Skript installiert zunächst Git und CA-Zertifikate, lädt dieses öffentliche Repository über HTTPS in ein temporäres Verzeichnis und startet anschließend den interaktiven Installer. Es benötigt für das Server-Repository keinen GitHub-Schlüssel. Optional können vor dem Start `SERVER_REPO_URL` und `SERVER_REPO_BRANCH` gesetzt werden.

Der Container erzeugt während der Installation selbst einen neuen Ed25519-Schlüssel. Nur der **öffentliche** Teil wird deutlich im Terminal ausgegeben. Nach dem Einfügen unter **GitHub → privates Config-Repository → Settings → Deploy keys → Add deploy key** wartet das Setup auf Enter und prüft den Zugriff. Die Option für Schreibzugriff darf nicht aktiviert werden.

## Installation aus einem vorhandenen Checkout

Auf einem frischen Ubuntu-CT das Repository übertragen/klonen und ausführen:

```bash
cd snom-config-server
sudo bash ops/install.sh
```

Der Installer fragt interaktiv ab:

- Installations- und Site-Root-Pfad;
- gemeinsamen FTPS-/SFTP-Benutzer und Passwort;
- SSH-URL und Branch des privaten Config-Repositories;
- Sync-Intervall;
- Nginx-Bind-Adresse und HTTP-Basic-Auth-Zugang;
- Zugangsdaten, die in `http_user`/`http_pass` der Telefon-XML eingesetzt werden.

Falls noch nicht vorhanden, erzeugt er einen separaten Ed25519 Deploy Key. Er zeigt den öffentlichen Schlüssel an und wartet, bis dieser im privaten GitHub-Repository als **read-only Deploy Key** eingetragen wurde. Der private Schlüssel verlässt den Container nicht. Das Config-Repo muss enthalten:

```text
Config/fkey/*.xml
Config/global-settings/*.xml
Config/macs.json
```

Danach richtet das Skript Nginx, PHP-FPM, OpenSSH/SFTP, vsftpd/FTPS und den systemd-Sync-Timer ein. Es erkennt den installierten PHP-FPM-Socket dynamisch und funktioniert daher ohne fest codierte PHP-Version auf unterstützten Ubuntu-Versionen.

> Die Domain bzw. der externe Proxy muss auf `<SITE_ROOT>/www` zeigen. Niemals den Site-Root selbst als Webroot konfigurieren.

## Betrieb

Standard-Endpunkte:

- `GET /global-settings.php?file=default`
- `GET /fkey.php?file=default`
- `GET /snomD385.php?version=10.1.215.13`
- `GET /snomD785.php?version=10.1.215.13`

Alle Endpunkte sind durch den abgefragten HTTP-Basic-Auth-Zugang geschützt.

```bash
# Sync sofort ausführen
sudo systemctl start snom-config-sync.service

# Timer und letzten Lauf prüfen
systemctl status snom-config-sync.timer
journalctl -u snom-config-sync.service

# Konfiguration sperren/entsperren
sudo touch /etc/snom-config/maintenance.on
sudo rm /etc/snom-config/maintenance.on
```

Der Sync prüft zuerst den Remote-Commit, klont nur bei Änderungen in ein temporäres Verzeichnis, validiert die erwartete Struktur und veröffentlicht anschließend atomarm mit restriktiven Rechten. Telefon-Zugangsdaten werden bei **jedem** Sync in der temporären Kopie eingesetzt; sie müssen daher nicht im Git-Repository stehen und werden nicht beim nächsten Update überschrieben.

## Netzwerk / Firewall

Freizugeben sind nur die tatsächlich benötigten Ports:

- `22/tcp` für SFTP/SSH;
- `21/tcp` und `40000:40100/tcp` für explizites FTPS;
- `8080/tcp` möglichst ausschließlich für den Reverse Proxy.

Das automatisch vorhandene Snakeoil-Zertifikat ermöglicht die Erstinstallation von FTPS, sollte für den Produktivbetrieb aber in `/etc/vsftpd.conf` durch ein eigenes vertrauenswürdiges Zertifikat ersetzt werden. Weitere Härtungshinweise stehen in [SECURITY.md](SECURITY.md).
