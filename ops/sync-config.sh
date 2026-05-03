#!/usr/bin/env bash
set -euo pipefail

REPO_SSH_URL="git@github.com:dataklo/lbs-snom-config.git"
BRANCH="main"
TARGET_DIR="/opt/snom-config-server/data/config"
STATE_DIR="/var/lib/snom-config-server"
LOCK_FILE="/var/lock/snom-config-sync.lock"
TMP_DIR="$(mktemp -d /tmp/lbs-snom-config-sync.XXXXXX)"
ENV_FILE="/opt/snom-config-server/ops/sync-config.env"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

install -d "$TARGET_DIR" "$STATE_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Sync läuft bereits - übersprungen."
  exit 0
fi

remote_head="$(git ls-remote --heads "$REPO_SSH_URL" "$BRANCH" | awk '{print $1}')"
if [[ -z "$remote_head" ]]; then
  echo "Konnte Remote-Commit nicht ermitteln."
  exit 1
fi

last_synced_file="$STATE_DIR/last_synced_commit"
if [[ -f "$last_synced_file" ]] && [[ "$(cat "$last_synced_file")" == "$remote_head" ]]; then
  echo "Kein Update verfügbar ($remote_head)."
  exit 0
fi

git clone --depth 1 --branch "$BRANCH" "$REPO_SSH_URL" "$TMP_DIR/repo"

rsync -a --delete "$TMP_DIR/repo/Config/fkey/" "$TARGET_DIR/fkey/"
rsync -a --delete "$TMP_DIR/repo/Config/global-settings/" "$TARGET_DIR/global-settings/"
install -m 0640 "$TMP_DIR/repo/Config/macs.json" "$TARGET_DIR/macs.json"

echo "$remote_head" > "$last_synced_file"
echo "Sync abgeschlossen: $(date -u +%Y-%m-%dT%H:%M:%SZ) ($remote_head)"
