#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="/opt/snom-config-server"
SITE_ROOT="/srv/snom-config"
TRANSFER_USER="snomupload"
REPO_SSH_URL="git@github.com:dataklo/lbs-snom-config.git"
BRANCH="main"
SYNC_INTERVAL_MIN="15"

die() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }
prompt() { local __name="$1" __text="$2" __default="$3" __value; read -r -p "$__text [$__default]: " __value; printf -v "$__name" '%s' "${__value:-$__default}"; }
secret() { local __name="$1" __text="$2" __value; read -r -s -p "$__text: " __value; echo; [[ -n "$__value" ]] || die "$__text darf nicht leer sein."; printf -v "$__name" '%s' "$__value"; }
valid_path() { [[ "$1" = /* && "$1" != "/" && "$1" != *$'\n'* ]] || die "Ungültiger absoluter Pfad: $1"; }
secure_app_path() {
  local path="$1" require_complete="${2:-no}" owner mode

  while :; do
    if [[ -e "$path" ]]; then
      [[ -d "$path" && ! -L "$path" ]] || die "APP_DIR-Pfadkomponente ist kein echtes Verzeichnis: $path"
      owner="$(stat -c '%u' -- "$path")"
      mode="$(stat -c '%a' -- "$path")"
      [[ "$owner" -eq 0 ]] || die "APP_DIR muss vollständig unter root-eigenen Verzeichnissen liegen: $path"
      (( (8#$mode & 0022) == 0 )) || die "APP_DIR-Pfadkomponente darf nicht für Gruppe/Andere schreibbar sein: $path"
    elif [[ "$require_complete" == yes ]]; then
      die "APP_DIR-Pfadkomponente fehlt nach der Installation: $path"
    fi
    [[ "$path" == / ]] && break
    path="$(dirname -- "$path")"
  done
}

[[ "$EUID" -eq 0 ]] || die "Bitte als root ausführen."

echo "=== Snom Config Server – Ubuntu/Proxmox-CT Installer ==="
prompt APP_DIR "Pfad für Programmdateien (nicht im Webroot)" "$APP_DIR"
prompt SITE_ROOT "FTP/SFTP-Root (Uploads; nicht als Webroot verwenden)" "$SITE_ROOT"
prompt TRANSFER_USER "Benutzer für FTPS und SFTP" "$TRANSFER_USER"
secret TRANSFER_PASS "Passwort für FTPS/SFTP-Benutzer"
prompt REPO_SSH_URL "Privates Config-Repo (SSH URL)" "$REPO_SSH_URL"
prompt BRANCH "Git Branch" "$BRANCH"
prompt SYNC_INTERVAL_MIN "Sync-Intervall in Minuten" "$SYNC_INTERVAL_MIN"
prompt FTP_PUBLIC_HOST "Öffentliche IP oder DNS-Name für FTPS (Passive Mode)" "$(hostname -f 2>/dev/null || hostname)"
prompt BIND_ADDR "Nginx Bind-Adresse" "0.0.0.0"
prompt BASIC_USER "URL-Login Benutzername" "admin"
secret BASIC_PASS "URL-Login Passwort"
prompt PHONE_HTTP_USER "Telefon-HTTP Benutzername für die XML" "root"
secret PHONE_HTTP_PASS "Telefon-HTTP Passwort für die XML"

valid_path "$APP_DIR"; valid_path "$SITE_ROOT"
# Nginx erhält unten den normalisierten Pfad. Dadurch können Symlink-Komponenten
# nicht später auf ein anderes Ziel zeigen. Alle bereits vorhandenen Komponenten
# müssen root gehören und dürfen nicht von weniger privilegierten Benutzern
# ersetzt werden können.
APP_DIR="$(realpath -m -- "$APP_DIR")"
SITE_ROOT="$(realpath -m -- "$SITE_ROOT")"
secure_app_path "$APP_DIR"
[[ "$SYNC_INTERVAL_MIN" =~ ^[1-9][0-9]*$ ]] || die "Das Sync-Intervall muss eine positive Ganzzahl sein."
[[ "$TRANSFER_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Ungültiger Benutzername."
[[ "$FTP_PUBLIC_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "Ungültige öffentliche FTPS-Adresse."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx php-fpm php-cli php-xml apache2-utils git rsync openssh-client openssh-server vsftpd ssl-cert python3 util-linux

# Der Chroot selbst muss root gehören. Nur uploads ist für den Transfer-Benutzer
# schreibbar; ausführbarer Anwendungscode bleibt außerhalb dieses Baums.
install -d -o root -g root -m 0755 "$SITE_ROOT"
install -d -o root -g www-data -m 0750 "$SITE_ROOT/private" "$SITE_ROOT/private/config"
if ! id "$TRANSFER_USER" >/dev/null 2>&1; then
  useradd --home-dir / --shell /usr/sbin/nologin --no-create-home "$TRANSFER_USER"
fi
printf '%s:%s\n' "$TRANSFER_USER" "$TRANSFER_PASS" | chpasswd
install -d -o "$TRANSFER_USER" -g "$TRANSFER_USER" -m 0750 "$SITE_ROOT/uploads"

# Installationsquellen kopieren; Repo-Geheimnisse und Config bleiben außerhalb
# des root-eigenen öffentlichen Anwendungsverzeichnisses.
if [[ "$SOURCE_DIR" != "$APP_DIR" ]]; then
  install -d -m 0755 "$APP_DIR"
  rsync -a --delete --exclude data --exclude ops/sync-config.env "$SOURCE_DIR/public/" "$APP_DIR/public/"
  rsync -a --delete "$SOURCE_DIR/ops/" "$APP_DIR/ops/"
else
  install -d -m 0755 "$APP_DIR/public" "$APP_DIR/ops"
fi
# Auch ein bereits vorhandenes APP_DIR wird nicht stillschweigend mit seinen
# bisherigen Rechten weiterverwendet. Die zweite Prüfung erfasst außerdem alle
# von install(1) neu angelegten Zwischenverzeichnisse.
chown root:root "$APP_DIR"
chmod 0755 "$APP_DIR"
secure_app_path "$APP_DIR" yes
# PHP wird direkt aus dem root-eigenen APP_DIR ausgeliefert. Transfer-Zugangsdaten
# können daher niemals zum Ersetzen oder Hochladen ausführbarer Endpunkte dienen.
chown -R root:root "$APP_DIR/public"
find "$APP_DIR/public" -type d -exec chmod 0755 {} +
find "$APP_DIR/public" -type f -exec chmod 0644 {} +

# www-data darf nur runtime.env lesen und das Verzeichnis dafür durchqueren. Die
# Deploy- und Telefon-Secrets bleiben root:root und 0600.
install -d -o root -g www-data -m 0710 /etc/snom-config
install -d -m 0750 /var/lib/snom-config-server /var/log/snom-config
KEY_PATH=/etc/snom-config/config_repo_ed25519
if [[ ! -f "$KEY_PATH" ]]; then ssh-keygen -q -t ed25519 -C "snom-config-deploy@$(hostname)" -f "$KEY_PATH" -N ''; fi
chmod 0600 "$KEY_PATH"; chmod 0644 "$KEY_PATH.pub"

echo
echo "======================================================================"
echo "Diesen PUBLIC KEY jetzt im privaten Config-Repo als Read-only Deploy Key hinterlegen:"
echo "GitHub: Repository > Settings > Deploy keys > Add deploy key"
echo "----------------------------------------------------------------------"
cat "$KEY_PATH.pub"
echo "======================================================================"
echo
read -r -p "Wenn der Public Key bei GitHub hinterlegt ist, Enter drücken: " _

# Viele Hoster und Firewalls sperren ausgehendes SSH auf Port 22. GitHub stellt
# dafür offiziell ssh.github.com auf Port 443 bereit. Der ursprüngliche Repo-URL
# bleibt unverändert; Hostname/Port werden ausschließlich im SSH-Aufruf ersetzt.
echo "Lade GitHub SSH-Host-Key über ssh.github.com:443 ..."
KNOWN_HOSTS_TMP="$(mktemp)"
trap 'rm -f "$KNOWN_HOSTS_TMP"' EXIT
if ! ssh-keyscan -T 10 -p 443 -H ssh.github.com > "$KNOWN_HOSTS_TMP" 2>/dev/null || [[ ! -s "$KNOWN_HOSTS_TMP" ]]; then
  die "GitHub Host-Key konnte über Port 443 nicht geladen werden (DNS/HTTPS-Firewall prüfen)."
fi
install -o root -g root -m 0644 "$KNOWN_HOSTS_TMP" /etc/snom-config/known_hosts
rm -f "$KNOWN_HOSTS_TMP"
trap - EXIT
chmod 0644 /etc/snom-config/known_hosts
SSH_HOSTNAME=ssh.github.com
SSH_PORT=443
SSH_COMMAND="ssh -i $KEY_PATH -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/snom-config/known_hosts -o StrictHostKeyChecking=yes -o Hostname=$SSH_HOSTNAME -p $SSH_PORT"
until GIT_SSH_COMMAND="$SSH_COMMAND" git ls-remote --exit-code --heads "$REPO_SSH_URL" "$BRANCH" >/dev/null 2>&1; do
  read -r -p "Repo noch nicht erreichbar. Deploy Key hinterlegt? Mit Enter erneut prüfen (q = Abbruch): " retry
  [[ "$retry" != q ]] || die "Installation abgebrochen."
done

{
  printf 'REPO_SSH_URL=%q\n' "$REPO_SSH_URL"
  printf 'BRANCH=%q\n' "$BRANCH"
  printf 'TARGET_DIR=%q\n' "$SITE_ROOT/private/config"
  printf 'KEY_PATH=%q\n' "$KEY_PATH"
  printf 'KNOWN_HOSTS=%q\n' /etc/snom-config/known_hosts
  printf 'SSH_HOSTNAME=%q\n' "$SSH_HOSTNAME"
  printf 'SSH_PORT=%q\n' "$SSH_PORT"
  printf 'PHONE_SECRETS=%q\n' /etc/snom-config/phone.env
} > /etc/snom-config/sync.env
{
  printf 'PHONE_HTTP_USER=%q\n' "$PHONE_HTTP_USER"
  printf 'PHONE_HTTP_PASS=%q\n' "$PHONE_HTTP_PASS"
} > /etc/snom-config/phone.env
cat > /etc/snom-config/runtime.env <<EOF
DATA_DIR=$SITE_ROOT/private/config
MAINTENANCE_FILE=/etc/snom-config/maintenance.on
AUDIT_LOG_PATH=/var/log/snom-config/audit.log
EOF
chmod 0600 /etc/snom-config/{sync,phone}.env
chown root:www-data /etc/snom-config/runtime.env
chmod 0640 /etc/snom-config/runtime.env

# FTPS (explizites TLS auf Port 21); SFTP wird in einen eigenen, beschränkten Chroot gesetzt.
cat > /etc/vsftpd.conf <<EOF
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
chroot_local_user=YES
allow_writeable_chroot=NO
local_root=$SITE_ROOT
local_umask=027
ssl_enable=YES
force_local_logins_ssl=YES
force_local_data_ssl=YES
rsa_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem
rsa_private_key_file=/etc/ssl/private/ssl-cert-snakeoil.key
ssl_tlsv1=YES
ssl_sslv2=NO
ssl_sslv3=NO
pasv_min_port=40000
pasv_max_port=40100
pasv_address=$FTP_PUBLIC_HOST
pasv_addr_resolve=YES
EOF
cat > /etc/ssh/sshd_config.d/60-snom-sftp.conf <<EOF
Match User $TRANSFER_USER
    ChrootDirectory $SITE_ROOT
    ForceCommand internal-sftp
    PasswordAuthentication yes
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
EOF

PHP_SOCKET="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' | sort -V | tail -1)"
[[ -n "$PHP_SOCKET" ]] || die "Kein PHP-FPM Socket gefunden."
cat > /etc/nginx/sites-available/snom-config <<EOF
server {
    listen $BIND_ADDR:8080 default_server;
    server_name _;
    root $APP_DIR/public;
    index index.php;
    auth_basic "Snom Config";
    auth_basic_user_file /etc/nginx/.htpasswd-snom;
    server_tokens off;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;
    if (\$request_method !~ ^(GET|HEAD)\$) { return 405; }
    location / { try_files \$uri \$uri/ =404; }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:$PHP_SOCKET;
    }
    location ~ /\. { deny all; }
}
EOF
htpasswd -cb /etc/nginx/.htpasswd-snom "$BASIC_USER" "$BASIC_PASS" >/dev/null
ln -sfn /etc/nginx/sites-available/snom-config /etc/nginx/sites-enabled/snom-config
rm -f /etc/nginx/sites-enabled/default

sed -e "s|@APP_DIR@|$APP_DIR|g" -e "s|@SITE_ROOT@|$SITE_ROOT|g" "$APP_DIR/ops/snom-config-sync.service" > /etc/systemd/system/snom-config-sync.service
sed "s|OnUnitActiveSec=15min|OnUnitActiveSec=${SYNC_INTERVAL_MIN}min|" "$APP_DIR/ops/snom-config-sync.timer" > /etc/systemd/system/snom-config-sync.timer
ln -sfn "$APP_DIR/ops/edit-config.sh" /usr/local/sbin/snom-config-edit
sshd -t
systemctl daemon-reload
systemctl enable --now ssh vsftpd
systemctl enable --now snom-config-sync.timer
systemctl start snom-config-sync.service
nginx -t
systemctl enable --now nginx
systemctl reload nginx

echo; echo "=== Installation abgeschlossen ==="
echo "Webroot der Domain: $APP_DIR/public (Nginx lokal auf Port 8080, root-owned)"
echo "Transfer-Uploads:    $SITE_ROOT/uploads (nicht durch Nginx/PHP ausgeführt)"
echo "Sensible Config:     $SITE_ROOT/private/config (nicht unter dem Webroot)"
echo "FTPS: Port 21 (+ passive Ports 40000-40100), SFTP: Port 22, Benutzer: $TRANSFER_USER"
echo "FTPS extern:         $FTP_PUBLIC_HOST"
echo "Config bearbeiten:   sudo snom-config-edit [relative/datei.xml]"
echo "Provisioning: http://SERVER:8080/global-settings.php?file=default"
