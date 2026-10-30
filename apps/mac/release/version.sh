#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ref_type="" ref_name="" dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ref-type) ref_type="${2:-}"; shift 2 ;;
    --ref-name) ref_name="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) die "argumento desconocido: $1" ;;
  esac
done
[ -n "$ref_type" ] || die "falta --ref-type"

ID='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
SEMVER_RE="^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-($ID(\\.$ID)*))?\$"

tag="" short="" pre=""
if [ "$ref_type" = "tag" ]; then
  if [[ "$ref_name" =~ $SEMVER_RE ]]; then
    tag="$ref_name"
    short="${ref_name#v}"
    pre="${BASH_REMATCH[5]:-}"
  else
    die "el tag '$ref_name' no es semver vX.Y.Z[-prerelease] (sin metadatos '+'); no se publica"
  fi
elif [ "$dry_run" = 1 ]; then
  short="0.0.0-dryrun"
else
  die "una release real solo sale de un tag vX.Y.Z (ref actual: $ref_type '$ref_name')"
fi

build="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
[[ "$build" =~ ^[0-9]{1,15}$ ]] || die "BUILD_NUMBER debe ser numérico (recibido con formato inválido)"

channel=""
prerelease=false
if [ -n "$pre" ]; then channel="beta"; prerelease=true; fi

set_output tag "$tag"
set_output short_version "$short"
set_output build_number "$build"
set_output channel "$channel"
set_output prerelease "$prerelease"
