#!/usr/bin/env bash
# Utilidades comunes de los scripts de release (se cargan con `source`; no se ejecuta solo).
# Compatible con bash 3.2 (el de macOS): sin arrays asociativos, mapfile ni ${var,,}.
# Regla de oro: ningún valor secreto se imprime. Lo derivado y sensible se registra con ::add-mask::.

log()  { printf '==> %s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*" >&2; }
die()  { printf '::error::%s\n' "$*" >&2; exit 1; }

# Directorio de los scripts de release y de apps/mac
RELEASE_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(cd "$RELEASE_SCRIPTS/.." && pwd)"
REPO_ROOT="$(cd "$MAC_DIR/../.." && pwd)"
export RELEASE_SCRIPTS MAC_DIR REPO_ROOT

# Registra cada línea de un valor para que Actions lo oculte en los logs; no imprime nada más.
mask_value() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$line" ]; then printf '::add-mask::%s\n' "$line"; fi
  done <<< "${1:-}"
  return 0
}

# Falla listando las variables vacías o ausentes (solo nombres, nunca valores).
require_env() {
  local n
  local -a missing=()
  for n in "$@"; do
    if [ -z "${!n:-}" ]; then missing+=("$n"); fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then die "faltan variables de entorno: ${missing[*]}"; fi
}

# Salidas de un paso (solo datos NO secretos).
set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi
  printf '%s=%s\n' "$1" "$2"
}

# Variable de entorno para los pasos siguientes del job (solo datos NO secretos).
set_env() {
  if [ -n "${GITHUB_ENV:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_ENV"; fi
  export "$1=$2"
}

# Añade una sección al resumen del job si existe.
summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; fi
  return 0
}

# version_ge A B -> 0 si A >= B (versiones numéricas con puntos, p. ej. 26.0 >= 13.0)
version_ge() {
  local IFS=.
  local -a a b
  local i x y
  read -r -a a <<< "$1"
  read -r -a b <<< "$2"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    x=$((10#${a[i]:-0}))
    y=$((10#${b[i]:-0}))
    if [ "$x" -gt "$y" ]; then return 0; fi
    if [ "$x" -lt "$y" ]; then return 1; fi
  done
  return 0
}

# Normaliza una URL base quitando barras finales
strip_slash() { local u="$1"; while [ "${u%/}" != "$u" ]; do u="${u%/}"; done; printf '%s' "$u"; }

# Escribe <archivo>.sha256 (formato `shasum -c`, con el nombre base) e imprime el hash.
write_sha256() {
  local sum
  sum="$(shasum -a 256 "$1" | awk '{print $1}')"
  printf '%s  %s\n' "$sum" "$(basename "$1")" > "$1.sha256"
  printf '%s\n' "$sum"
}

# Número de bytes decodificados de un base64 (para validar claves)
b64_len() { printf '%s' "$1" | base64 --decode 2>/dev/null | wc -c | tr -d ' '; }

# ¿Es un binario Mach-O (o fat)? Se mira la cabecera, sin depender de `file`.
is_macho() {
  local magic
  magic="$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')"
  case "$magic" in
    feedface | feedfacf | cefaedfe | cffaedfe | cafebabe | bebafeca) return 0 ;;
  esac
  return 1
}

# stapler_retry <staple|validate> <ruta>: ejecuta `xcrun stapler <acción> <ruta>` con reintentos y backoff exponencial.
# staple/validate consultan CloudKit (ticket-delivery) y fallan a veces por la red de Apple (NSURLErrorDomain -1005,
# «Error 68») aunque la notarización esté aceptada. Se reintenta ante cualquier salida no cero de stapler; al agotar los
# intentos falla con el último código. NO sustituye ninguna verificación: el éxito exige que stapler termine en 0.
# Env: STAPLER_ATTEMPTS (8), STAPLER_RETRY_DELAY (5 s, se duplica en cada intento), STAPLER_RETRY_MAX_DELAY (60 s);
# con STAPLER_RETRY_DELAY=0 no hay espera (pruebas). Con los valores por defecto espera 5,10,20,40,60,60,60 s.
stapler_retry() {
  local action="${1:-}" target="${2:-}"
  local max="${STAPLER_ATTEMPTS:-8}" delay="${STAPLER_RETRY_DELAY:-5}" cap="${STAPLER_RETRY_MAX_DELAY:-60}"
  local attempt=1 rc=0
  case "$action" in staple | validate) ;; *) die "stapler_retry: acción no válida '$action' (staple|validate)" ;; esac
  if [ -z "$target" ]; then die "stapler_retry: falta la ruta a $action"; fi
  case "$max$delay$cap" in '' | *[!0-9]*) die "stapler_retry: STAPLER_ATTEMPTS, STAPLER_RETRY_DELAY y STAPLER_RETRY_MAX_DELAY deben ser enteros" ;; esac
  if [ "$max" -lt 1 ]; then die "stapler_retry: STAPLER_ATTEMPTS debe ser >= 1"; fi
  while true; do
    rc=0
    xcrun stapler "$action" "$target" || rc=$?
    if [ "$rc" -eq 0 ]; then return 0; fi
    if [ "$attempt" -ge "$max" ]; then
      printf '::error::stapler %s falló tras %s intentos (último código de salida: %s)\n' "$action" "$attempt" "$rc" >&2
      return "$rc"
    fi
    warn "stapler $action falló (código $rc; intento $attempt/$max); reintento en ${delay}s"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    if [ "$delay" -gt "$cap" ]; then delay="$cap"; fi
  done
}
