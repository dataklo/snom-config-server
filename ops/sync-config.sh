#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${SNOM_SYNC_ENV:-/etc/snom-config/sync.env}"
[[ -r "$ENV_FILE" ]] || { echo "Konfiguration fehlt: $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${REPO_SSH_URL:?}" "${BRANCH:?}" "${TARGET_DIR:?}" "${KEY_PATH:?}" "${KNOWN_HOSTS:?}"

STATE_DIR=/var/lib/snom-config-server
TMP_DIR="$(mktemp -d /tmp/snom-config-sync.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
install -d -m 0750 "$TARGET_DIR" "$STATE_DIR"
exec 9>/var/lock/snom-config-sync.lock
flock -n 9 || { echo "Sync läuft bereits – übersprungen."; exit 0; }

export GIT_SSH_COMMAND="ssh -i $KEY_PATH -o IdentitiesOnly=yes -o UserKnownHostsFile=$KNOWN_HOSTS -o StrictHostKeyChecking=yes"
remote_head="$(git ls-remote --heads "$REPO_SSH_URL" "$BRANCH" | awk 'NR==1 {print $1}')"
[[ -n "$remote_head" ]] || { echo "Remote-Commit nicht gefunden." >&2; exit 1; }
last_file="$STATE_DIR/last_synced_commit"
[[ ! -f "$last_file" || "$(cat "$last_file")" != "$remote_head" ]] || { echo "Kein Update verfügbar ($remote_head)."; exit 0; }

git clone --quiet --depth 1 --branch "$BRANCH" --single-branch "$REPO_SSH_URL" "$TMP_DIR/repo"
SOURCE="$TMP_DIR/repo/Config"
[[ -d "$SOURCE/fkey" && -d "$SOURCE/global-settings" && -f "$SOURCE/macs.json" ]] || {
  echo "Repo-Struktur ungültig: erwartet Config/{fkey,global-settings,macs.json}." >&2; exit 1;
}

if [[ -n "${PHONE_SECRETS:-}" && -r "$PHONE_SECRETS" ]]; then
  # shellcheck disable=SC1090
  source "$PHONE_SECRETS"
  export PHONE_HTTP_USER PHONE_HTTP_PASS XML_FILE="$SOURCE/global-settings/default.xml"
  [[ -f "$XML_FILE" ]] && python3 - <<'PY'
import os
from pathlib import Path
import xml.etree.ElementTree as ET
p = Path(os.environ["XML_FILE"])
tree = ET.parse(p)
for node in tree.iter():
    tag = node.tag.rsplit("}", 1)[-1]
    if tag == "http_user": node.text = os.environ["PHONE_HTTP_USER"]
    if tag == "http_pass": node.text = os.environ["PHONE_HTTP_PASS"]
tree.write(p, encoding="utf-8", xml_declaration=True)
PY
fi

STAGE="$TMP_DIR/stage"
install -d "$STAGE"
rsync -a "$SOURCE/" "$STAGE/"
chown -R root:www-data "$STAGE"; find "$STAGE" -type d -exec chmod 0750 {} +; find "$STAGE" -type f -exec chmod 0640 {} +
rsync -a --delete "$STAGE/" "$TARGET_DIR/"
printf '%s\n' "$remote_head" > "$last_file"
echo "Sync abgeschlossen: $remote_head"
