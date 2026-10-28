#!/usr/bin/env bash
# Cloudflare R2 (API S3 compatible) desde el RUNNER con aws CLI. Subcomandos:
#   r2.sh pull <dir> [--all]            baja appcast.xml y los zips/deltas que referencia (--all: todo el prefijo)
#   r2.sh push <dir> [<version>]        sube zips/deltas (inmutables), notas y, AL FINAL, appcast.xml
#   r2.sh push-appcast <dir>            sube solo appcast.xml
#   r2.sh retire <nombre>...            mueve objetos a retired/ (rollback; nunca se borran)
#   r2.sh verify <dir> [<zip>]          comprueba por HTTP público que el feed publicado es el nuestro y el zip es idéntico
# Env: R2_ACCOUNT_ID (var), R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY (secrets), R2_BUCKET, UPDATES_BASE_URL (el bucket se
# sirve en la raíz de esa URL).
# Política: NUNCA se usa --delete ni se borran zips anteriores (los necesitan los deltas); solo `retire` mueve.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

r2_env() {
  require_env R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET
  mask_value "$R2_ACCOUNT_ID"
  export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export AWS_DEFAULT_REGION=auto AWS_EC2_METADATA_DISABLED=true AWS_PAGER=""
  # R2 no acepta las sumas de verificación CRC por defecto de las versiones recientes del CLI
  export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
  ENDPOINT="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"
  PREFIX=""   # el bucket se usa en su raíz: UPDATES_BASE_URL apunta ahí
  S3="s3://$R2_BUCKET/$PREFIX"
}
r2() { aws --endpoint-url "$ENDPOINT" "$@"; }

# Nombres de archivo seguros (lo que diga un appcast remoto no debe poder escribir fuera del directorio)
safe_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$1" != *..* ]]; }

REMOTE_SIZE=""
# 0 = existe (tamaño en REMOTE_SIZE), 1 = no existe, 2 = error (p. ej. credenciales): NUNCA debe tratarse como "no existe",
# porque en la primera publicación se parte de un feed vacío y se pisaría el feed real.
remote_stat() {
  local out
  REMOTE_SIZE=""
  if out="$(r2 s3api head-object --bucket "$R2_BUCKET" --key "$PREFIX$1" --query ContentLength --output text 2>&1)"; then
    REMOTE_SIZE="$out"
    return 0
  fi
  case "$out" in
    *"Not Found"* | *404* | *NoSuchKey*) return 1 ;;
  esac
  printf '::error::no se pudo consultar %s en R2: %s\n' "$1" "${out:0:200}" >&2
  return 2
}

put() { # archivo clave tipo cache-control
  r2 s3 cp "$1" "$S3$2" --only-show-errors --content-type "$3" --cache-control "$4"
}

cmd_pull() {
  local dir="${1:?uso: r2.sh pull <dir> [--all]}" all="${2:-}"
  mkdir -p "$dir"
  local rc=0
  remote_stat appcast.xml || rc=$?
  case "$rc" in
    0)
      r2 s3 cp "${S3}appcast.xml" "$dir/appcast.xml" --only-show-errors
      log "appcast.xml descargado ($REMOTE_SIZE bytes)"
      ;;
    1)
      log "no hay appcast.xml en el bucket: primera publicación"
      return 0
      ;;
    *) exit 1 ;;
  esac
  local names
  if [ "$all" = "--all" ]; then
    names="$(r2 s3api list-objects-v2 --bucket "$R2_BUCKET" --prefix "$PREFIX" --query 'Contents[].Key' --output text | tr '\t' '\n' | sed "s|^$PREFIX||" | grep -E '^[^/]+\.(zip|delta)$' || true)"
  else
    names="$(python3 -I "$HERE/appcast.py" list-files --appcast "$dir/appcast.xml")"
  fi
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    safe_name "$n" || die "nombre de archivo sospechoso en el appcast remoto"
    r2 s3 cp "$S3$n" "$dir/$n" --only-show-errors
  done <<< "$names"
  log "descargados $(printf '%s\n' "$names" | grep -c . || true) archivo(s) referenciados"
}

cmd_push() {
  local dir="${1:?uso: r2.sh push <dir> [<version>]}" version="${2:-}" f name lsize rc
  [ -f "$dir/appcast.xml" ] || die "no hay appcast.xml que publicar"
  # 1) zips y deltas: inmutables. Si ya existen con otro tamaño se aborta (no se pisa un release publicado)
  for f in "$dir"/*.zip "$dir"/*.delta; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    safe_name "$name" || die "nombre no permitido: $name"
    lsize="$(wc -c < "$f" | tr -d ' ')"
    rc=0
    remote_stat "$name" || rc=$?
    case "$rc" in
      0)
        [ "$REMOTE_SIZE" = "$lsize" ] || die "$name ya existe en R2 con otro tamaño; no se sobrescribe"
        continue
        ;;
      1) ;;
      *) exit 1 ;;
    esac
    log "subiendo $name"
    case "$name" in
      *.zip) put "$f" "$name" application/zip "public, max-age=31536000, immutable" ;;
      *) put "$f" "$name" application/octet-stream "public, max-age=31536000, immutable" ;;
    esac
  done
  # 2) notas por versión
  if [ -n "$version" ] && [ -f "$dir/notes/$version.html" ]; then
    put "$dir/notes/$version.html" "notes/$version.html" "text/html; charset=utf-8" "public, max-age=300"
  fi
  # 3) el appcast, siempre al final: ningún cliente ve un feed que apunte a archivos aún no subidos
  cmd_push_appcast "$dir"
}

cmd_push_appcast() {
  local dir="${1:?}"
  put "$dir/appcast.xml" appcast.xml "application/xml; charset=utf-8" "public, max-age=60"
  log "appcast.xml publicado (Cache-Control: max-age=60)"
}

cmd_retire() {
  local n rc
  for n in "$@"; do
    safe_name "$n" || die "nombre no permitido: $n"
    rc=0
    remote_stat "$n" || rc=$?
    case "$rc" in
      0)
        r2 s3 mv "$S3$n" "${S3}retired/$n" --only-show-errors
        log "$n movido a retired/"
        ;;
      1) log "$n ya no estaba en el bucket" ;;
      *) exit 1 ;;
    esac
  done
}

cmd_verify() {
  local dir="${1:?uso: r2.sh verify <dir> [<zip>]}" zip="${2:-}"
  require_env UPDATES_BASE_URL
  local base
  base="$(strip_slash "$UPDATES_BASE_URL")"
  tmp="$(mktemp -d)"   # global a propósito: el trap EXIT lo necesita fuera del ámbito de la función
  trap 'rm -rf "$tmp"' EXIT
  local curl_opts=(--fail --silent --show-error --location --proto '=https' --retry 6 --retry-delay 5 --retry-all-errors -H 'Cache-Control: no-cache')
  curl "${curl_opts[@]}" --output "$tmp/appcast.xml" "$base/appcast.xml?cb=$(date +%s)"
  cmp -s "$tmp/appcast.xml" "$dir/appcast.xml" || die "el appcast servido en UPDATES_BASE_URL no coincide con el publicado (¿caché, prefijo o dominio incorrectos?)"
  if [ -n "$zip" ]; then
    curl "${curl_opts[@]}" --output "$tmp/$zip" "$base/$zip"
    cmp -s "$tmp/$zip" "$dir/$zip" || die "el zip servido públicamente no es idéntico al construido"
  fi
  # todo lo que referencia el feed debe responder 200
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    curl --fail --silent --show-error --head --proto '=https' --retry 3 --retry-all-errors --output /dev/null "$base/$n" || die "el feed referencia $n pero no se descarga"
  done <<< "$(python3 -I "$HERE/appcast.py" list-files --appcast "$tmp/appcast.xml")"
  log "verificación pública OK: feed y archivos accesibles en la URL de actualizaciones"
}

sub="${1:-}"; shift || true
case "$sub" in
  pull | push | push-appcast | retire) r2_env ;;
esac
case "$sub" in
  pull) cmd_pull "$@" ;;
  push) cmd_push "$@" ;;
  push-appcast) cmd_push_appcast "$@" ;;
  retire) cmd_retire "$@" ;;
  verify) cmd_verify "$@" ;;
  *) die "uso: r2.sh <pull|push|push-appcast|retire|verify> ..." ;;
esac
