#!/usr/bin/env bash
# Generate (and validate) a packages/<name>.json reference for the autobott
# APT repo from an app's built .deb files. Git operations are the caller's job
# (the composite action commits+pushes; a maintainer commits by hand locally).
#
# Usage:
#   scripts/register.sh --name <pkg> --dist-dir <dir> --repo <owner/app> \
#                       --tag <vX.Y.Z> --out <path/to/packages/pkg.json>
set -euo pipefail

NAME=""; DIST_DIR="dist"; SRC_REPO=""; TAG=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name)     NAME="$2"; shift 2;;
    --dist-dir) DIST_DIR="$2"; shift 2;;
    --repo)     SRC_REPO="$2"; shift 2;;
    --tag)      TAG="$2"; shift 2;;
    --out)      OUT="$2"; shift 2;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
: "${NAME:?--name is required}"
: "${SRC_REPO:?--repo is required (source app repo, owner/name)}"
: "${TAG:?--tag is required}"
: "${OUT:?--out is required}"

ver="${TAG#v}"
base="https://github.com/${SRC_REPO}/releases/download/${TAG}"

shopt -s nullglob
debs=("$DIST_DIR"/*.deb)
[ ${#debs[@]} -gt 0 ] || { echo "❌ no .deb files in '$DIST_DIR'" >&2; exit 1; }

# every .deb in the dir must belong to this package
for d in "${debs[@]}"; do
  p=$(dpkg-deb -f "$d" Package)
  [ "$p" = "$NAME" ] || { echo "❌ $(basename "$d"): Package '$p' != --name '$NAME'" >&2; exit 1; }
done

artifacts=$(for d in "${debs[@]}"; do
  jq -n --arg arch "$(dpkg-deb -f "$d" Architecture)" \
        --arg url  "$base/$(basename "$d")" \
        --arg sha  "$(sha256sum "$d" | cut -d' ' -f1)" \
        '{arch:$arch, url:$url, sha256:$sha}'
done | jq -s 'sort_by(.arch)')

mkdir -p "$(dirname "$OUT")"
jq -n --arg name "$NAME" --arg version "$ver" --argjson artifacts "$artifacts" \
  '{name:$name, version:$version, artifacts:$artifacts}' > "$OUT"
echo "✅ wrote $OUT ($NAME $ver, $(echo "$artifacts" | jq length) artifact(s))"

# validate against the repo's schema when the validator is available
SCHEMA="$(cd "$(dirname "$0")/.." && pwd)/schema/package.schema.json"
if command -v check-jsonschema >/dev/null 2>&1; then
  # capture output so a clean pass stays quiet, but surface the errors on a
  # failure (otherwise set -e aborts here with no clue why).
  if err=$(check-jsonschema --schemafile "$SCHEMA" "$OUT" 2>&1); then
    echo "✅ validates against schema"
  else
    printf '%s\n' "$err" >&2
    echo "❌ $OUT failed schema validation against $SCHEMA" >&2
    exit 1
  fi
else
  echo "⚠️  check-jsonschema not found — skipping local validation (CI validates too)"
fi
