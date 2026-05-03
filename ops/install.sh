#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/snom-config-server"
SSH_DIR="/root/.ssh"
KEY_PATH="$SSH_DIR/snom_config_repo_ed25519"
KNOWN_HOSTS="$SSH_DIR/known_hosts"
SERVICE_SRC="$APP_DIR/ops/snom-config-sync.service"
TIMER_SRC="$APP_DIR/ops/snom-config-sync.timer"
SERVICE_DST="/etc/systemd/system/snom-config-sync.service"
TIMER_DST="/etc/systemd/system/snom-config-sync.timer"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Bitte als root ausführen."
  exit 1
fi

read -r -p "Installationspfad [$APP_DIR]: " input_app_dir
APP_DIR="${input_app_dir:-$APP_DIR}"

read -r -p "GitHub Repo SSH URL [git@github.com:dataklo/lbs-snom-config.git]: " input_repo
REPO_SSH_URL="${input_repo:-git@github.com:dataklo/lbs-snom-config.git}"

read -r -p "Git Branch [main]: " input_branch
BRANCH="${input_branch:-main}"

read -r -p "Sync-Zielpfad [$APP_DIR/data/config]: " input_target
TARGET_DIR="${input_target:-$APP_DIR/data/config}"

read -r -p "Sync-Intervall in Minuten [15]: " input_interval
SYNC_INTERVAL_MIN="${input_interval:-15}"

read -r -p "Nginx bind Adresse [0.0.0.0]: " input_bind
BIND_ADDR="${input_bind:-0.0.0.0}"

read -r -p "Optional: Erlaubtes Proxy-Netz (CIDR, leer = alle) []: " input_proxy_cidr
TRUSTED_PROXY_CIDR="${input_proxy_cidr:-}"

read -r -p "Admin-IP für Maintenance-Bypass [127.0.0.1]: " input_admin_ip
ADMIN_IP="${input_admin_ip:-127.0.0.1}"

read -r -p "URL-Login Benutzername für XML-Download [admin]: " input_user
BASIC_USER="${input_user:-admin}"

read -r -s -p "URL-Login Passwort für XML-Download: " BASIC_PASS
echo
if [[ -z "$BASIC_PASS" ]]; then
  echo "Passwort darf nicht leer sein."
  exit 1
fi


read -r -p "Telefon-HTTP Benutzername (für XML, z.B. root) [root]: " input_phone_user
PHONE_HTTP_USER="${input_phone_user:-root}"

read -r -s -p "Telefon-HTTP Passwort (für XML): " PHONE_HTTP_PASS
echo
if [[ -z "$PHONE_HTTP_PASS" ]]; then
  echo "Telefon-HTTP Passwort darf nicht leer sein."
  exit 1
fi

apt update
apt install -y nginx php-fpm php-cli php-xml apache2-utils git rsync openssh-client

install -d -m 0750 "$TARGET_DIR/fkey" "$TARGET_DIR/global-settings"
install -d -m 0750 /etc/snom-config /var/log/snom-config
install -d -m 0700 "$SSH_DIR"

if [[ ! -f "$KEY_PATH" ]]; then
  echo "Erzeuge neuen SSH Deploy Key..."
  ssh-keygen -t ed25519 -C "snom-config-deploy@$(hostname)" -f "$KEY_PATH" -N ""
fi

if ! ssh-keygen -F github.com -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
  ssh-keyscan -t ed25519 github.com >> "$KNOWN_HOSTS"
fi

chmod 0600 "$KEY_PATH"
chmod 0644 "$KEY_PATH.pub" "$KNOWN_HOSTS"

echo "Prüfe Zugriff auf Config-Repo..."
SSH_CMD="ssh -i $KEY_PATH -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
while true; do
  if GIT_SSH_COMMAND="$SSH_CMD" git ls-remote --heads "$REPO_SSH_URL" "$BRANCH" >/dev/null 2>&1; then
    echo "Repo-Zugriff erfolgreich."
    break
  fi

  echo "Repo-Zugriff fehlgeschlagen."
  echo "Bitte Deploy Key in GitHub hinterlegen (Read-only) und SSH-Berechtigung prüfen."
  echo "Public Key:"
  cat "$KEY_PATH.pub"
  echo
  read -r -p "Erneut versuchen? [Enter]" _retry
done


cat <<CFG > "$APP_DIR/ops/sync-config.env"
REPO_SSH_URL="$REPO_SSH_URL"
BRANCH="$BRANCH"
TARGET_DIR="$TARGET_DIR"
CFG
chmod 0600 "$APP_DIR/ops/sync-config.env"

cat <<RUNTIME > /etc/snom-config/runtime.env
ADMIN_IP=$ADMIN_IP
MAINTENANCE_FILE=/etc/snom-config/maintenance.on
AUDIT_LOG_PATH=/var/log/snom-config/audit.log
RUNTIME
chmod 0640 /etc/snom-config/runtime.env

cp "$SERVICE_SRC" "$SERVICE_DST"
cp "$TIMER_SRC" "$TIMER_DST"

sed -i "s|OnUnitActiveSec=15min|OnUnitActiveSec=${SYNC_INTERVAL_MIN}min|" "$TIMER_DST"

cat > /etc/nginx/sites-available/snom-config <<NGINX
server {
    listen ${BIND_ADDR}:8080 default_server;
    listen [::]:8080 default_server;
    server_name _;

    root $APP_DIR/public;
    index index.php;

    auth_basic "Snom Config";
    auth_basic_user_file /etc/nginx/.htpasswd-snom;

    server_tokens off;
    client_max_body_size 1m;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy no-referrer always;
    add_header Cache-Control "no-store" always;

    if ($request_method !~ ^(GET|HEAD)$) { return 405; }

    
    # __PROXY_ALLOWLIST__
    location / { try_files \$uri \$uri/ =404; }
    location ^~ /data/ { deny all; return 403; }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    location ~ /\.|/\.git { deny all; }
}
NGINX
ln -sf /etc/nginx/sites-available/snom-config /etc/nginx/sites-enabled/snom-config
rm -f /etc/nginx/sites-enabled/default

if [[ -n "$TRUSTED_PROXY_CIDR" ]]; then
  sed -i "s|# __PROXY_ALLOWLIST__|allow $TRUSTED_PROXY_CIDR;\n    deny all;|" /etc/nginx/sites-available/snom-config
else
  sed -i "s|# __PROXY_ALLOWLIST__|# kein Proxy-Filter gesetzt|" /etc/nginx/sites-available/snom-config
fi

htpasswd -cb /etc/nginx/.htpasswd-snom "$BASIC_USER" "$BASIC_PASS"

systemctl daemon-reload
systemctl enable --now snom-config-sync.timer
nginx -t
systemctl reload nginx


apply_phone_http_credentials() {
  local xml_file="$TARGET_DIR/global-settings/default.xml"
  if [[ ! -f "$xml_file" ]]; then
    return 0
  fi

  PHONE_HTTP_USER="$PHONE_HTTP_USER" PHONE_HTTP_PASS="$PHONE_HTTP_PASS" XML_FILE="$xml_file" python3 - <<'PYXML'
import os
import re
from pathlib import Path

xml_file = Path(os.environ["XML_FILE"])
phone_user = os.environ["PHONE_HTTP_USER"]
phone_pass = os.environ["PHONE_HTTP_PASS"]
text = xml_file.read_text(encoding="utf-8")
text = re.sub(r"<http_user[^>]*>[^<]*</http_user>", f'<http_user perm="R">{phone_user}</http_user>', text)
text = re.sub(r"<http_pass[^>]*>[^<]*</http_pass>", f'<http_pass perm="R">{phone_pass}</http_pass>', text)
xml_file.write_text(text, encoding="utf-8")
PYXML
}

"$APP_DIR/ops/sync-config.sh" || true
apply_phone_http_credentials

echo ""
echo "=== FERTIG ==="
echo "1) Hinterlege diesen Public Key als Deploy Key (Read only) in GitHub:"
cat "$KEY_PATH.pub"
echo ""
echo "2) Teste den Sync danach manuell:"
echo "   systemctl start snom-config-sync.service"
echo ""
echo "3) Timer-Status:"
echo "   systemctl status snom-config-sync.timer"
echo ""
echo "4) Audit-Log: /var/log/snom-config/audit.log"
echo "5) Panikschalter aktivieren: touch /etc/snom-config/maintenance.on"
echo "   Panikschalter deaktivieren: rm /etc/snom-config/maintenance.on"
echo ""
echo "6) In den Snom-Telefonen als Provisioning URL eintragen:"
echo "   http://<URL-LOGIN-USER>:<URL-LOGIN-PASS>@<DEIN-SERVER-ODER-PROXY>:8080/global-settings.php?file=default"
echo "   http://<URL-LOGIN-USER>:<URL-LOGIN-PASS>@<DEIN-SERVER-ODER-PROXY>:8080/fkey.php?file=default"
