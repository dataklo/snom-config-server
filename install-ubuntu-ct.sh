#!/usr/bin/env bash
# Ein-Datei-Bootstrap für einen frischen Ubuntu-Container (Proxmox CT).
set -Eeuo pipefail

SERVER_REPO_URL="${SERVER_REPO_URL:-https://github.com/dataklo/snom-config-server.git}"
SERVER_REPO_BRANCH="${SERVER_REPO_BRANCH:-main}"
WORK_DIR=""

cleanup() {
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

die() {
  printf 'FEHLER: %s\n' "$*" >&2
  exit 1
}

[[ "$EUID" -eq 0 ]] || die "Bitte als root ausführen (z. B. sudo bash install-ubuntu-ct.sh)."
[[ -r /etc/os-release ]] || die "/etc/os-release fehlt; unterstützt wird Ubuntu."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die "Dieses Installationsskript unterstützt Ubuntu; erkannt wurde: ${ID:-unbekannt}."

echo "=== Snom Config Server Bootstrap ==="
echo "Installiere die zum Abruf des öffentlichen Server-Repositories benötigten Pakete ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates git

WORK_DIR="$(mktemp -d /tmp/snom-config-server-install.XXXXXX)"
echo "Lade $SERVER_REPO_URL (Branch: $SERVER_REPO_BRANCH) ..."
git clone --quiet --depth 1 --branch "$SERVER_REPO_BRANCH" --single-branch \
  "$SERVER_REPO_URL" "$WORK_DIR/repository"

[[ -x "$WORK_DIR/repository/ops/install.sh" ]] || die "ops/install.sh fehlt oder ist nicht ausführbar."
echo "Starte jetzt die interaktive Container-Installation."
bash "$WORK_DIR/repository/ops/install.sh"
