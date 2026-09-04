# Snom Config Server für Ubuntu-/Proxmox-CT

Dieses Repository installiert einen Snom-Provisioning-Server auf einem Ubuntu-Container. Die Domain wird ausschließlich aus dem root-eigenen Anwendungsverzeichnis bedient; die aus dem privaten Git-Repository geladenen XML-Dateien liegen im getrennten Site-Root und können deshalb niemals als statische Dateien vom Webserver ausgeliefert werden.

## Architektur

Bei den Standardwerten entsteht folgende Trennung:

```text
/srv/snom-config/                 # FTPS-/SFTP-Chroot, root-owned
├── uploads/                      # transfer-user-owned; niemals PHP/Webroot
└── private/config/               # sensible Repo-Daten; nicht öffentlich
/opt/snom-config-server/          # root-owned Anwendung und Betriebs-Skripte
└── public/                       # einziger Nginx-Webroot; PHP-Endpunkte
/etc/snom-config/                 # Deploy Key/Secrets (0600), runtime.env für PHP lesbar
```

Nginx lauscht auf HTTP-Port `8080`; TLS und die öffentliche Domain können weiterhin am vorgeschalteten Proxy enden. Dateiübertragung ist per **explizitem FTPS auf Port 21** (passive Ports `40000–40100`) und **SFTP auf Port 22** möglich. Beide verwenden den beim Setup abgefragten Benutzer. Dessen SFTP-Sitzung ist auf den Site-Root beschränkt und kann nur nach `uploads` schreiben. Anwendungscode liegt außerhalb dieses Baums und gehört root. Das Verzeichnis `private` ist nur für root und PHP lesbar.

## Installation per Copy & Paste

Auf einem frischen Ubuntu-CT kann die komplette Installation mit diesem einen Befehl gestartet werden:

```bash
apt-get update && apt-get install -y curl && \
curl -fsSL https://raw.githubusercontent.com/dataklo/snom-config-server/main/install-ubuntu-ct.sh \
  -o /tmp/install-snom-config.sh \
  && bash /tmp/install-snom-config.sh
```

Der erste Teil installiert auch auf einem Minimal-Container das für den Download benötigte `curl`. Das Bootstrap-Skript installiert anschließend Git und CA-Zertifikate, lädt dieses öffentliche Repository über HTTPS in ein temporäres Verzeichnis und startet den interaktiven Installer. Es benötigt für das Server-Repository keinen GitHub-Schlüssel. Optional können vor dem Start `SERVER_REPO_URL` und `SERVER_REPO_BRANCH` gesetzt werden.

Der Container erzeugt während der Installation selbst einen neuen Ed25519-Schlüssel. Nur der **öffentliche** Teil wird deutlich im Terminal ausgegeben. Nach dem Einfügen unter **GitHub → privates Config-Repository → Settings → Deploy keys → Add deploy key** wartet das Setup auf Enter und prüft den Zugriff. Die Option für Schreibzugriff darf nicht aktiviert werden.

Der Zugriff auf das private GitHub-Repository erfolgt über `ssh.github.com:443`, weil ausgehender SSH-Verkehr auf Port 22 bei vielen Hostern gesperrt ist. Bricht die interaktive Installation ab, wird der temporäre Checkout absichtlich gelöscht. Nach Beheben der Ursache daher einfach den vollständigen Bootstrap-Befehl erneut ausführen; ein Verzeichnis `~/snom-config-server` wird dabei nicht angelegt.

### Abgebrochene Installation erneut starten

Der Bootstrap klont das Server-Repository nur vorübergehend nach `/tmp` und räumt es beim Beenden wieder auf. Deshalb funktionieren nach einem Abbruch weder `cd snom-config-server` noch `bash ops/install.sh`, sofern das Repository nicht separat geklont wurde. Auch die systemd-Units werden erst gegen Ende einer erfolgreichen Installation angelegt.

Zum Fortsetzen den Bootstrap vollständig erneut starten:

```bash
apt-get update && apt-get install -y curl && \
curl -fsSL https://raw.githubusercontent.com/dataklo/snom-config-server/main/install-ubuntu-ct.sh \
  -o /tmp/install-snom-config.sh \
  && bash /tmp/install-snom-config.sh
```

Bereits installierte Pakete und der unter `/etc/snom-config/config_repo_ed25519` erzeugte Deploy Key werden dabei wiederverwendet. Der zuvor bei GitHub hinterlegte öffentliche Schlüssel bleibt daher gültig. Alle als Passwort abgefragten Werte müssen erneut eingegeben werden und dürfen nicht leer sein. Nach der Ausgabe des Public Keys zuerst kontrollieren, dass genau dieser Schlüssel im privaten Config-Repository als read-only Deploy Key hinterlegt ist, und erst dann Enter drücken.

Falls der Zugriff auf das private Repository weiterhin nicht klappt, die Verbindung unabhängig vom Installer prüfen:

```bash
ssh -T -p 443 \
  -i /etc/snom-config/config_repo_ed25519 \
  -o IdentitiesOnly=yes \
  -o Hostname=ssh.github.com \
  -o UserKnownHostsFile=/etc/snom-config/known_hosts \
  -o StrictHostKeyChecking=yes \
  git@github.com
```

Die GitHub-Meldung, dass keine Shell bereitgestellt wird, ist bei erfolgreicher Authentifizierung normal. Erst nachdem der Installer vollständig durchgelaufen ist, sind `snom-config-sync.service` und `snom-config-sync.timer` verfügbar.

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
- öffentlich erreichbare IP oder DNS-Adresse für den passiven FTPS-Modus;
- Nginx-Bind-Adresse und HTTP-Basic-Auth-Zugang;
- Zugangsdaten, die in `http_user`/`http_pass` der Telefon-XML eingesetzt werden.

Falls noch nicht vorhanden, erzeugt er einen separaten Ed25519 Deploy Key. Er zeigt den öffentlichen Schlüssel an und wartet, bis dieser im privaten GitHub-Repository als **read-only Deploy Key** eingetragen wurde. Der private Schlüssel verlässt den Container nicht. Das Config-Repo muss enthalten:

```text
Config/fkey/*.xml
Config/global-settings/*.xml
Config/macs.json
```

Danach richtet das Skript Nginx, PHP-FPM, OpenSSH/SFTP, vsftpd/FTPS und den systemd-Sync-Timer ein. Es erkennt den installierten PHP-FPM-Socket dynamisch und funktioniert daher ohne fest codierte PHP-Version auf unterstützten Ubuntu-Versionen.

> Nginx verwendet `<APP_DIR>/public` als Webroot. Niemals den Site-Root oder dessen transferbeschreibbares Verzeichnis `uploads` als Webroot konfigurieren.

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

Die aktuell veröffentlichte XML-/JSON-Konfiguration kann interaktiv oder durch Angabe eines relativen Pfads bearbeitet werden:

```bash
sudo snom-config-edit
sudo snom-config-edit global-settings/default.xml
```

Das Skript lässt nur Dateien innerhalb von `private/config` zu, prüft XML bzw. JSON vor dem atomaren Speichern und stellt die Leserechte für PHP wieder her. Diese Änderungen sind lokal und können beim nächsten Repository-Sync überschrieben werden; dauerhafte Änderungen gehören weiterhin in das private Config-Repository.

## Netzwerk / Firewall

Freizugeben sind nur die tatsächlich benötigten Ports:

- `22/tcp` für SFTP/SSH;
- `21/tcp` und `40000:40100/tcp` für explizites FTPS;
- `8080/tcp` möglichst ausschließlich für den Reverse Proxy.

Das automatisch vorhandene Snakeoil-Zertifikat ermöglicht die Erstinstallation von FTPS, sollte für den Produktivbetrieb aber in `/etc/vsftpd.conf` durch ein eigenes vertrauenswürdiges Zertifikat ersetzt werden. Weitere Härtungshinweise stehen in [SECURITY.md](SECURITY.md).
