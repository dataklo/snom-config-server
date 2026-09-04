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

[[ "$EUID" -eq 0 ]] || die "Bitte als root ausführen."

echo "=== Snom Config Server – Ubuntu/Proxmox-CT Installer ==="
prompt APP_DIR "Pfad für Programmdateien (nicht im Webroot)" "$APP_DIR"
prompt SITE_ROOT "FTP/SFTP-Root (die Domain muss auf SITE_ROOT/www zeigen)" "$SITE_ROOT"
prompt TRANSFER_USER "Benutzer für FTPS und SFTP" "$TRANSFER_USER"
secret TRANSFER_PASS "Passwort für FTPS/SFTP-Benutzer"
prompt REPO_SSH_URL "Privates Config-Repo (SSH URL)" "$REPO_SSH_URL"
prompt BRANCH "Git Branch" "$BRANCH"
prompt SYNC_INTERVAL_MIN "Sync-Intervall in Minuten" "$SYNC_INTERVAL_MIN"
prompt BIND_ADDR "Nginx Bind-Adresse" "0.0.0.0"
prompt BASIC_USER "URL-Login Benutzername" "admin"
secret BASIC_PASS "URL-Login Passwort"
prompt PHONE_HTTP_USER "Telefon-HTTP Benutzername für die XML" "root"
secret PHONE_HTTP_PASS "Telefon-HTTP Passwort für die XML"

valid_path "$APP_DIR"; valid_path "$SITE_ROOT"
[[ "$SYNC_INTERVAL_MIN" =~ ^[1-9][0-9]*$ ]] || die "Das Sync-Intervall muss eine positive Ganzzahl sein."
[[ "$TRANSFER_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Ungültiger Benutzername."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx php-fpm php-cli php-xml apache2-utils git rsync openssh-client openssh-server vsftpd ssl-cert python3 util-linux

# Der Chroot selbst muss root gehören. Nur www ist für den Transfer-Benutzer schreibbar.
install -d -o root -g root -m 0755 "$SITE_ROOT"
install -d -o root -g www-data -m 0750 "$SITE_ROOT/private" "$SITE_ROOT/private/config"
if ! id "$TRANSFER_USER" >/dev/null 2>&1; then
  useradd --home-dir / --shell /usr/sbin/nologin --no-create-home "$TRANSFER_USER"
fi
printf '%s:%s\n' "$TRANSFER_USER" "$TRANSFER_PASS" | chpasswd
install -d -o "$TRANSFER_USER" -g "$TRANSFER_USER" -m 0750 "$SITE_ROOT/www"

# Installationsquellen kopieren; Repo-Geheimnisse und Config bleiben außerhalb von www.
if [[ "$SOURCE_DIR" != "$APP_DIR" ]]; then
  install -d -m 0755 "$APP_DIR"
  rsync -a --delete --exclude data --exclude ops/sync-config.env "$SOURCE_DIR/public/" "$APP_DIR/public/"
  rsync -a --delete "$SOURCE_DIR/ops/" "$APP_DIR/ops/"
else
  install -d -m 0755 "$APP_DIR/public" "$APP_DIR/ops"
fi
rsync -a --delete "$APP_DIR/public/" "$SITE_ROOT/www/"
chown -R "$TRANSFER_USER:$TRANSFER_USER" "$SITE_ROOT/www"
find "$SITE_ROOT/www" -type d -exec chmod 0755 {} +
find "$SITE_ROOT/www" -type f -exec chmod 0644 {} +

install -d -m 0750 /etc/snom-config /var/lib/snom-config-server /var/log/snom-config
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

ssh-keyscan -H github.com > /etc/snom-config/known_hosts 2>/dev/null || die "GitHub Host-Key konnte nicht geladen werden (DNS/Netz prüfen)."
chmod 0644 /etc/snom-config/known_hosts
SSH_COMMAND="ssh -i $KEY_PATH -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/snom-config/known_hosts -o StrictHostKeyChecking=yes"
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
    root $SITE_ROOT/www;
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
sshd -t
systemctl daemon-reload
systemctl enable --now ssh vsftpd
systemctl enable --now snom-config-sync.timer
systemctl start snom-config-sync.service
nginx -t
systemctl enable --now nginx
systemctl reload nginx

echo; echo "=== Installation abgeschlossen ==="
echo "Webroot der Domain: $SITE_ROOT/www (Nginx lokal auf Port 8080)"
echo "Sensible Config:     $SITE_ROOT/private/config (nicht unter dem Webroot)"
echo "FTPS: Port 21 (+ passive Ports 40000-40100), SFTP: Port 22, Benutzer: $TRANSFER_USER"
echo "Provisioning: http://SERVER:8080/global-settings.php?file=default"
