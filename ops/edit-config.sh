#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${SNOM_SYNC_ENV:-/etc/snom-config/sync.env}"

die() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || die "Bitte als root ausführen."
[[ -r "$ENV_FILE" ]] || die "Sync-Konfiguration fehlt: $ENV_FILE"
# Diese Datei wird vom Installer root:root/0600 erzeugt und darf Shell-quotierte
# Werte enthalten.
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${TARGET_DIR:?TARGET_DIR fehlt in $ENV_FILE}"
[[ -d "$TARGET_DIR" ]] || die "Noch keine synchronisierte Config in $TARGET_DIR gefunden."
TARGET_DIR="$(realpath -e -- "$TARGET_DIR")"

choose_file() {
  local -a files
  mapfile -t files < <(find "$TARGET_DIR" -type f \( -name '*.xml' -o -name '*.json' \) -printf '%P\n' | sort)
  ((${#files[@]})) || die "Keine XML- oder JSON-Dateien gefunden."
  printf 'Zu bearbeitende Datei wählen:\n' >&2
  select selected in "${files[@]}"; do
    [[ -n "${selected:-}" ]] && { printf '%s\n' "$selected"; return; }
    printf 'Ungültige Auswahl.\n' >&2
  done
}

relative_path="${1:-}"
[[ -n "$relative_path" ]] || relative_path="$(choose_file)"
[[ "$relative_path" != /* && "$relative_path" != *$'\n'* ]] || die "Nur relative Dateipfade sind erlaubt."

target="$(realpath -e -- "$TARGET_DIR/$relative_path")" || die "Datei nicht gefunden: $relative_path"
case "$target" in
  "$TARGET_DIR"/*) ;;
  *) die "Datei liegt außerhalb der Config: $relative_path" ;;
esac
[[ -f "$target" ]] || die "Keine reguläre Datei: $relative_path"
[[ "$target" == *.xml || "$target" == *.json ]] || die "Nur XML- und JSON-Dateien können bearbeitet werden."

tmp="$(mktemp --tmpdir="$(dirname "$target")" .snom-config-edit.XXXXXX)"
trap 'rm -f "$tmp"' EXIT
cp -- "$target" "$tmp"
"${EDITOR:-editor}" "$tmp"

if [[ "$target" == *.xml ]]; then
  php -r '$d = new DOMDocument(); if (!@$d->load($argv[1])) { fwrite(STDERR, "Ungültiges XML\n"); exit(1); }' "$tmp"
else
  python3 -m json.tool "$tmp" >/dev/null
fi

chown root:www-data "$tmp"
chmod 0640 "$tmp"
mv -f -- "$tmp" "$target"
trap - EXIT
printf 'Gespeichert: %s\n' "$target"
printf 'Hinweis: Der nächste Repository-Sync kann diese lokale Änderung überschreiben.\n'
