#!/bin/sh
# Instala (solo COPIA) la unidad systemd --user del agente y hace `daemon-reload`.
# NO ejecuta `enable`, NO ejecuta `start`, NO activa linger: eso lo decides tú (ver docs/agent-service.md).
#
# Uso: scripts/install-user-unit.sh [--dry-run] [--force] [--chopshop RUTA] [--dest DIR] [--no-reload] [-- ARGS_DE_PRINT_UNIT...]
#   --dry-run     muestra qué haría y la unidad renderizada; no escribe nada ni llama a systemctl
#   --force       reemplaza una unidad ya instalada que sea distinta (sin esto se muestra la diferencia y se aborta)
#   --chopshop    ejecutable `chopshop` (por defecto apps/agent/bin/chopshop de este repo)
#   --dest        carpeta destino (por defecto $XDG_CONFIG_HOME/systemd/user o ~/.config/systemd/user)
#   --no-reload   no ejecuta `systemctl --user daemon-reload`
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CHOPSHOP="$HERE/apps/agent/bin/chopshop"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
DRY=0; FORCE=0; RELOAD=1
UNIT=chopshop-agent.service

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --force) FORCE=1 ;;
    --no-reload) RELOAD=0 ;;
    --chopshop) CHOPSHOP="$2"; shift ;;
    --dest) DEST="$2"; shift ;;
    --) shift; break ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "opción desconocida: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -x "$CHOPSHOP" ] || { echo "no encuentro el ejecutable chopshop: $CHOPSHOP (usa --chopshop)" >&2; exit 2; }

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
"$CHOPSHOP" agent print-unit --exec "$CHOPSHOP" "$@" > "$TMP"

TARGET="$DEST/$UNIT"
if [ "$DRY" -eq 1 ]; then
  echo "[dry-run] destino: $TARGET"
  if [ -f "$TARGET" ] && cmp -s "$TMP" "$TARGET"; then echo "[dry-run] ya está instalada y es idéntica"
  elif [ -f "$TARGET" ]; then echo "[dry-run] existe y es distinta: haría falta --force"
  else echo "[dry-run] se crearía"; fi
  [ "$RELOAD" -eq 1 ] && echo "[dry-run] luego: systemctl --user daemon-reload (sin enable ni start)"
  echo "[dry-run] unidad renderizada:"
  cat "$TMP"
  exit 0
fi

if [ -f "$TARGET" ]; then
  if cmp -s "$TMP" "$TARGET"; then
    echo "sin cambios: $TARGET ya es idéntica"
  elif [ "$FORCE" -eq 1 ]; then
    echo "reemplazando $TARGET"
  else
    echo "$TARGET ya existe y es distinta (usa --force para reemplazarla). Diferencias:" >&2
    diff -u "$TARGET" "$TMP" >&2 || true
    exit 3
  fi
fi

mkdir -p "$DEST"
cp "$TMP" "$TARGET"
chmod 644 "$TARGET"
echo "unidad instalada: $TARGET"

if [ "$RELOAD" -eq 1 ]; then
  systemctl --user daemon-reload
  echo "daemon-reload hecho"
fi
echo "No se ha habilitado ni arrancado nada. Para probar: systemctl --user start $UNIT"
