#!/usr/bin/env bash
# Generate (and validate) a packages/<name>.json reference for the autobott
# APT repo from an app's built .deb files. Git operations are the caller's job
# (the composite action commits+pushes; a maintainer commits by hand locally).
#
# The version is read from the .deb's own control field, not from --tag: a tag
# need not be a bare version (klassy-deb tags `debian_sid-v6.7.2`) and a suite
# suffix or packaging revision only exists in the .deb (6.7.2-1~sid). hydrate.sh
# cross-checks name/version/arch against every downloaded .deb, so anything
# derived from the tag would be rejected there. --tag only builds the asset URL.
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

base="https://github.com/${SRC_REPO}/releases/download/${TAG}"

shopt -s nullglob
rels=(); debs=()
for d in "$DIST_DIR"/*.deb;  do rels+=("any"); debs+=("$d"); done          # bare = any
for sub in "$DIST_DIR"/*/;   do [ -d "$sub" ] || continue; r=$(basename "$sub")
  for d in "$sub"*.deb; do rels+=("$r"); debs+=("$d"); done; done
[ ${#debs[@]} -gt 0 ] || { echo "❌ no .deb files in '$DIST_DIR' (flat or dist/<release>/)" >&2; exit 1; }

# Every .deb must belong to this package and carry the same Version: one package
# file describes exactly one version (the schema has a single `version`, and
# hydrate.sh compares it against every .deb it downloads). An app that ships
# DIFFERENT versions to different suites — e.g. an old upstream release for
# stable because newer ones need newer libraries — registers each version group
# into its own file via --out; hydrate merges them, since the only uniqueness
# rule is one (package, release, arch) across all of packages/*.json and debs/.
ver=""; ver_from=""
for idx in "${!debs[@]}"; do
  d="${debs[$idx]}"
  p=$(dpkg-deb -f "$d" Package)
  [ "$p" = "$NAME" ] || { echo "❌ $(basename "$d"): Package '$p' != --name '$NAME'" >&2; exit 1; }
  v=$(dpkg-deb -f "$d" Version)
  here="${rels[$idx]}/$(basename "$d")"
  if [ -z "$ver" ]; then ver="$v"; ver_from="$here"
  elif [ "$v" != "$ver" ]; then
    echo "❌ '$DIST_DIR' mixes versions: '$ver' ($ver_from) vs '$v' ($here)" >&2
    echo "   one package file describes one version — register each version group" >&2
    echo "   separately, e.g. --out packages/${NAME}.<release>.json" >&2
    exit 1
  fi
done

artifacts=$(for idx in "${!debs[@]}"; do
  d="${debs[$idx]}"; r="${rels[$idx]}"
  jq -n --arg release "$r" --arg arch "$(dpkg-deb -f "$d" Architecture)" \
        --arg url "$base/$(basename "$d")" --arg sha "$(sha256sum "$d" | cut -d' ' -f1)" \
        '{release:$release, arch:$arch, url:$url, sha256:$sha}'
done | jq -s 'sort_by(.release, .arch)')

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
