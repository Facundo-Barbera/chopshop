#!/usr/bin/env bash
# Valida que existan TODOS los secrets/vars requeridos y lista los que faltan (solo nombres, nunca valores).
#   preflight.sh <release|rollback>
#   PREFLIGHT_MODE=release (por defecto) | dryrun
# Se ejecuta en el primer job del workflow, antes de tocar keychain, red o credenciales. Los secrets llegan
# como indicador, no como valor: el workflow pasa `'set'` si el secret existe y vacío si no (`secrets.X != ''`),
# de modo que este job nunca ve su contenido.
# En dryrun (sin firma Developer ID, sin notarización ni release) NO se exigen MACOS_CERT_P12_BASE64, MACOS_CERT_PASSWORD
# ni SIGNING_IDENTITY; todo lo demás sí (la notarización, Sparkle y R2 también se prueban allí o se necesitarán después).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SCOPE="${1:-}"
MODE="${PREFLIGHT_MODE:-release}"

# NOMBRE|tipo|para qué sirve (la lista completa y cómo obtenerlos está en docs/release.md)
SPEC_VARS=(
  "APPLE_TEAM_ID|var|Team ID de Apple Developer (10 caracteres)"
  "BUNDLE_ID|var|bundle id de la app (p. ej. com.example.chopshop)"
  "SIGNING_IDENTITY|var|identidad de firma: «Developer ID Application: Nombre (TEAMID)»"
  "SPARKLE_ED_PUBLIC_KEY|var|clave pública EdDSA de Sparkle (generate_keys)"
  "R2_ACCOUNT_ID|var|Account ID de Cloudflare (endpoint S3 de R2)"
  "R2_BUCKET|var|nombre del bucket de R2"
  "UPDATES_BASE_URL|var|URL pública base de R2 (el feed es <URL>/appcast.xml)"
)
SPEC_SIGN=(
  "MACOS_CERT_P12_BASE64|secret|certificado Developer ID Application (.p12) en base64"
  "MACOS_CERT_PASSWORD|secret|contraseña del .p12"
  "KEYCHAIN_PASSWORD|secret|contraseña del keychain temporal del runner"
  "ASC_API_KEY_P8_BASE64|secret|clave de la API de App Store Connect (.p8) en base64"
  "ASC_API_KEY_ID|secret|Key ID de la API key de notarización"
  "ASC_API_ISSUER_ID|secret|Issuer ID de App Store Connect"
)
SPEC_PUBLISH=(
  "SPARKLE_ED_PRIVATE_KEY|secret|clave privada EdDSA de Sparkle (generate_keys -x)"
  "R2_ACCESS_KEY_ID|secret|Access Key ID del token S3 de R2"
  "R2_SECRET_ACCESS_KEY|secret|Secret Access Key del token S3 de R2"
)

case "$SCOPE" in
  release) SPEC=("${SPEC_VARS[@]}" "${SPEC_SIGN[@]}" "${SPEC_PUBLISH[@]}") ;;
  # El rollback solo publica un feed: no firma ni notariza
  rollback) SPEC=(
    "SPARKLE_ED_PUBLIC_KEY|var|clave pública EdDSA de Sparkle (generate_keys)"
    "R2_ACCOUNT_ID|var|Account ID de Cloudflare (endpoint S3 de R2)"
    "R2_BUCKET|var|nombre del bucket de R2"
    "UPDATES_BASE_URL|var|URL pública base de R2"
    "${SPEC_PUBLISH[@]}"
  ) ;;
  *) die "uso: preflight.sh <release|rollback>" ;;
esac

problems=()
missing_lines=()
for spec in "${SPEC[@]}"; do
  IFS='|' read -r name kind desc <<< "$spec"
  if [ "$MODE" = dryrun ]; then
    case "$name" in MACOS_CERT_P12_BASE64 | MACOS_CERT_PASSWORD | SIGNING_IDENTITY) continue ;; esac
  fi
  if [ -z "${!name:-}" ]; then
    problems+=("$name ($kind)")
    missing_lines+=("| \`$name\` | $kind | $desc |")
  fi
done

# Formato de las variables públicas que estén definidas (nunca de los secretos)
bad_format=()
if [ -n "${UPDATES_BASE_URL:-}" ] && ! [[ "$UPDATES_BASE_URL" =~ ^https://[^[:space:]?#]+$ ]]; then
  bad_format+=("UPDATES_BASE_URL debe ser una URL https:// sin query ni fragmento")
fi
if [ -n "${SPARKLE_ED_PUBLIC_KEY:-}" ] && [ "$(b64_len "$SPARKLE_ED_PUBLIC_KEY")" != 32 ]; then
  bad_format+=("SPARKLE_ED_PUBLIC_KEY debe ser base64 de 32 bytes (salida de generate_keys)")
fi
if [ -n "${APPLE_TEAM_ID:-}" ] && ! [[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  bad_format+=("APPLE_TEAM_ID debe tener 10 caracteres alfanuméricos en mayúsculas")
fi
if [ -n "${R2_ACCOUNT_ID:-}" ] && ! [[ "$R2_ACCOUNT_ID" =~ ^[0-9a-fA-F]{32}$ ]]; then
  bad_format+=("R2_ACCOUNT_ID debe ser el Account ID de Cloudflare (32 caracteres hexadecimales)")
fi
if [ "$MODE" = release ] && [ -n "${SIGNING_IDENTITY:-}" ] && ! [[ "$SIGNING_IDENTITY" =~ ^(Developer\ ID\ Application:\ .+|[0-9A-Fa-f]{40})$ ]]; then
  bad_format+=("SIGNING_IDENTITY debe ser «Developer ID Application: Nombre (TEAMID)» o el hash SHA-1 de la identidad")
fi
if [ "$MODE" = release ] && [ -n "${SIGNING_IDENTITY:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [[ "$SIGNING_IDENTITY" == Developer* ]] && [[ "$SIGNING_IDENTITY" != *"($APPLE_TEAM_ID)" ]]; then
  bad_format+=("SIGNING_IDENTITY no termina en (APPLE_TEAM_ID): identidad y Team ID no corresponden")
fi
if [ -n "${BUNDLE_ID:-}" ]; then
  if ! [[ "$BUNDLE_ID" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
    bad_format+=("BUNDLE_ID no es un identificador DNS inverso válido")
  elif [ "$MODE" = release ] && [[ "$BUNDLE_ID" == com.example.* ]]; then
    bad_format+=("BUNDLE_ID sigue con el valor genérico com.example.*; define el tuyo para publicar")
  fi
fi

total=$(( ${#problems[@]} + ${#bad_format[@]} ))
if [ "$total" -eq 0 ]; then
  log "preflight[$SCOPE]: todo definido"
  exit 0
fi

if [ "${#missing_lines[@]}" -gt 0 ]; then
  summary "### Faltan secrets/variables"
  summary "| Nombre | Tipo | Para qué |"
  summary "|---|---|---|"
  for l in "${missing_lines[@]}"; do summary "$l"; done
  summary ""
  summary "Créalos en Settings → Secrets and variables → Actions (secrets y variables de **repositorio**). Guía: docs/release.md"
fi
if [ "${#problems[@]}" -gt 0 ]; then
  printf '::error::Faltan %d secret(s)/variable(s) requeridos: %s. Créalos en Settings → Secrets and variables → Actions (guía: docs/release.md)\n' "${#problems[@]}" "${problems[*]}" >&2
fi
for m in ${bad_format[@]+"${bad_format[@]}"}; do printf '::error::%s\n' "$m" >&2; done
exit 1
