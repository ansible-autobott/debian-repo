#!/usr/bin/env bash
# Assemble <site>/pool from two sources:
#   1. packages/*.json  — download each referenced .deb, verify its sha256, and
#      cross-check the .deb's control fields against the JSON.
#   2. debs/*.deb        — manually-added, git-committed binaries, copied as-is.
# Fails hard on any mismatch so a partial/incorrect set is never published.
set -euo pipefail

SITE="${1:-_site}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$ROOT/packages"
LOCAL_DIR="$ROOT/debs"
POOL="$SITE/pool/main"

rm -rf "$SITE/pool"
mkdir -p "$POOL"

place() { # <deb-file> <package-name> <dest-basename>
  local dest="$POOL/${2:0:1}/$2"
  mkdir -p "$dest"
  cp "$1" "$dest/$3"
}

# --- 1. referenced artifacts from packages/*.json --------------------------
shopt -s nullglob
json_files=("$PKG_DIR"/*.json)
if [ ${#json_files[@]} -eq 0 ]; then
  echo "⚠️  no package files in packages/"
else
  for f in "${json_files[@]}"; do
    name=$(jq -r '.name' "$f")
    version=$(jq -r '.version' "$f")
    count=$(jq '.artifacts | length' "$f")
    echo ">> $name $version ($(basename "$f"))"
    for i in $(seq 0 $((count - 1))); do
      arch=$(jq -r ".artifacts[$i].arch" "$f")
      url=$(jq -r ".artifacts[$i].url" "$f")
      want=$(jq -r ".artifacts[$i].sha256" "$f")
      tmp=$(mktemp --suffix .deb)
      curl -fsSL "$url" -o "$tmp"
      got=$(sha256sum "$tmp" | cut -d' ' -f1)
      [ "$got" = "$want" ] || { echo "❌ $name/$arch: sha256 mismatch (want $want, got $got)"; rm -f "$tmp"; exit 1; }
      p=$(dpkg-deb -f "$tmp" Package); v=$(dpkg-deb -f "$tmp" Version); a=$(dpkg-deb -f "$tmp" Architecture)
      [ "$p" = "$name" ]    || { echo "❌ $f: name '$name' != deb Package '$p'"; rm -f "$tmp"; exit 1; }
      [ "$v" = "$version" ] || { echo "❌ $f: version '$version' != deb Version '$v'"; rm -f "$tmp"; exit 1; }
      [ "$a" = "$arch" ]    || { echo "❌ $f: arch '$arch' != deb Architecture '$a'"; rm -f "$tmp"; exit 1; }
      place "$tmp" "$name" "$(basename "$url")"
      rm -f "$tmp"
      echo "   ✅ $arch  $(basename "$url")"
    done
  done
fi

# --- 2. manually-added, committed binaries from debs/ ----------------------
local_debs=("$LOCAL_DIR"/*.deb)
if [ ${#local_debs[@]} -gt 0 ]; then
  echo ">> including manually-added debs from debs/"
  for d in "${local_debs[@]}"; do
    dpkg-deb --info "$d" >/dev/null 2>&1 || { echo "❌ invalid .deb: $d"; exit 1; }
    name=$(dpkg-deb -f "$d" Package)
    place "$d" "$name" "$(basename "$d")"
    echo "   ✅ $(basename "$d")"
  done
fi

echo "✅ hydrated $SITE/pool"
