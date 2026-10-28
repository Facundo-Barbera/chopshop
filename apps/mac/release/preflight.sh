#!/usr/bin/env bash
# Valida que existan los secrets/vars requeridos de un ámbito y lista los que faltan.
#   preflight.sh <vars|sign|publish>
#   PREFLIGHT_MODE=release (por defecto) | dryrun
# Solo comprueba "no vacío" y el formato de las vars públicas; NUNCA imprime valores.
# En dryrun no falla: avisa de lo que faltaría para una release real.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SCOPE="${1:-}"
MODE="${PREFLIGHT_MODE:-release}"

# NOMBRE|tipo|para qué sirve (la lista completa y cómo obtenerlos está en docs/release.md)
VARS_SPEC=(
  "BUNDLE_ID|var|bundle id de la app (p. ej. com.example.chopshop)"
  "SPARKLE_PUBLIC_ED_KEY|var|clave pública EdDSA de Sparkle (generate_keys)"
  "SPARKLE_FEED_URL|var|URL pública del appcast.xml (SUFeedURL)"
  "UPDATES_BASE_URL|var|URL pública base donde viven los zips (dominio de R2)"
  "R2_BUCKET|var|nombre del bucket de R2"
)
SIGN_SPEC=(
  "MACOS_CERT_P12_BASE64|secret|certificado Developer ID Application (.p12) en base64"
  "MACOS_CERT_PASSWORD|secret|contraseña del .p12"
  "APPLE_API_KEY_P8_BASE64|secret|clave de la API de App Store Connect (.p8) en base64"
  "APPLE_API_KEY_ID|secret|Key ID de la API key de notarización"
  "APPLE_API_ISSUER|secret|Issuer ID de App Store Connect"
)
PUBLISH_SPEC=(
  "SPARKLE_ED_PRIVATE_KEY|secret|clave privada EdDSA de Sparkle (generate_keys -x)"
  "R2_ACCOUNT_ID|secret|Account ID de Cloudflare (endpoint S3 de R2)"
  "R2_ACCESS_KEY_ID|secret|Access Key ID del token S3 de R2"
  "R2_SECRET_ACCESS_KEY|secret|Secret Access Key del token S3 de R2"
  "R2_BUCKET|var|nombre del bucket de R2"
  "UPDATES_BASE_URL|var|URL pública base donde viven los zips"
  "SPARKLE_PUBLIC_ED_KEY|var|clave pública EdDSA de Sparkle"
)

case "$SCOPE" in
  vars) SPEC=("${VARS_SPEC[@]}") ;;
  sign) SPEC=("${SIGN_SPEC[@]}") ;;
  publish) SPEC=("${PUBLISH_SPEC[@]}") ;;
  *) die "uso: preflight.sh <vars|sign|publish>" ;;
esac

problems=()
missing_lines=()
for spec in "${SPEC[@]}"; do
  IFS='|' read -r name kind desc <<< "$spec"
  if [ -z "${!name:-}" ]; then
    problems+=("$name ($kind)")
    missing_lines+=("| \`$name\` | $kind | $desc |")
  fi
done

# Formato de las variables públicas que estén definidas (nunca de los secretos)
bad_format=()
check_https() { local n="$1" v="${!1:-}"; if [ -n "$v" ] && ! [[ "$v" =~ ^https://[^[:space:]?#]+$ ]]; then bad_format+=("$n debe ser una URL https:// sin query ni fragmento"); fi; return 0; }
check_https SPARKLE_FEED_URL
check_https UPDATES_BASE_URL
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ] && [ "$(b64_len "$SPARKLE_PUBLIC_ED_KEY")" != 32 ]; then
  bad_format+=("SPARKLE_PUBLIC_ED_KEY debe ser base64 de 32 bytes (salida de generate_keys)")
fi
if [ -n "${SPARKLE_SIGNING_PUBLIC_ED_KEY:-}" ] && [ "$(b64_len "$SPARKLE_SIGNING_PUBLIC_ED_KEY")" != 32 ]; then
  bad_format+=("SPARKLE_SIGNING_PUBLIC_ED_KEY debe ser base64 de 32 bytes")
fi
if [ -n "${BUNDLE_ID:-}" ]; then
  if ! [[ "$BUNDLE_ID" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
    bad_format+=("BUNDLE_ID no es un identificador DNS inverso válido")
  elif [ "$MODE" = release ] && [[ "$BUNDLE_ID" == com.example.* ]]; then
    bad_format+=("BUNDLE_ID sigue con el valor genérico com.example.*; define el tuyo para publicar")
  fi
fi
if [ -n "${MIN_MACOS_VERSION:-}" ] && ! [[ "$MIN_MACOS_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  bad_format+=("MIN_MACOS_VERSION debe ser numérico (p. ej. 13.0)")
fi
if [ -n "${SPARKLE_CHECK_INTERVAL:-}" ] && { ! [[ "$SPARKLE_CHECK_INTERVAL" =~ ^[0-9]+$ ]] || [ "$SPARKLE_CHECK_INTERVAL" -lt 3600 ]; }; then
  bad_format+=("SPARKLE_CHECK_INTERVAL debe ser un entero >= 3600 (segundos)")
fi
for n in MAX_DELTAS MAX_VERSIONS PHASED_ROLLOUT_INTERVAL; do
  v="${!n:-}"
  if [ -n "$v" ] && ! [[ "$v" =~ ^[0-9]+$ ]]; then bad_format+=("$n debe ser un entero"); fi
done

total=$(( ${#problems[@]} + ${#bad_format[@]} ))
if [ "$total" -eq 0 ]; then
  log "preflight[$SCOPE]: todo definido"
  exit 0
fi

if [ "$MODE" = dryrun ]; then
  [ "${#problems[@]}" -eq 0 ] || warn "dry-run: para una release real faltarían [$SCOPE]: ${problems[*]}"
  for m in ${bad_format[@]+"${bad_format[@]}"}; do warn "dry-run: $m"; done
  exit 0
fi

if [ "${#missing_lines[@]}" -gt 0 ]; then
  summary "### Faltan secrets/variables ($SCOPE)"
  summary "| Nombre | Tipo | Para qué |"
  summary "|---|---|---|"
  for l in "${missing_lines[@]}"; do summary "$l"; done
  summary ""
  summary "Cómo crearlos: docs/release.md (Settings → Secrets and variables → Actions)."
fi
[ "${#problems[@]}" -eq 0 ] || printf '::error::Faltan %d valor(es) requeridos [%s]: %s. Ver docs/release.md\n' "${#problems[@]}" "$SCOPE" "${problems[*]}" >&2
for m in ${bad_format[@]+"${bad_format[@]}"}; do printf '::error::%s\n' "$m" >&2; done
exit 1
