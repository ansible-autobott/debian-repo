#!/usr/bin/env bash
# Assemble <site>/pool/<codename>/main from two sources:
#   1. packages/*.json  — download each referenced .deb, verify sha256, cross-check
#      control fields, and place it into the pool of every release it targets.
#   2. debs/<release>/*.deb (and bare debs/*.deb = "any") — committed binaries.
# Releases come from conf/dists.conf; "any" expands to every configured codename.
# Fails hard on any mismatch so a partial/incorrect set is never published.
set -euo pipefail

SITE="${1:-_site}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_DIR="${2:-$ROOT/debs}"
PKG_DIR="$ROOT/packages"
. "$(dirname "$0")/dists-lib.sh"; dists_load "${DISTS_CONF:-$ROOT/conf/dists.conf}"

rm -rf "$SITE/pool"; for cn in $DISTS; do mkdir -p "$SITE/pool/$cn/main"; done
placed=""

place() { # <deb> <pkg> <dest-basename> <codename>
  local dest="$SITE/pool/$4/main/${2:0:1}/$2"; mkdir -p "$dest"; cp "$1" "$dest/$3"
}
guard() { # <pkg> <codename> <arch>  — fail on a repeated (pkg,codename,arch)
  case " $placed " in *" $1|$2|$3 "*) echo "❌ duplicate artifact: $1 for $2/$3" >&2; exit 1;; esac
  placed="$placed $1|$2|$3"
}

shopt -s nullglob
json_files=("$PKG_DIR"/*.json)
if [ ${#json_files[@]} -eq 0 ]; then echo "⚠️  no package files in packages/"; else
  for f in "${json_files[@]}"; do
    name=$(jq -r '.name' "$f"); version=$(jq -r '.version' "$f"); count=$(jq '.artifacts | length' "$f")
    echo ">> $name $version ($(basename "$f"))"
    for i in $(seq 0 $((count - 1))); do
      arch=$(jq -r ".artifacts[$i].arch" "$f"); release=$(jq -r ".artifacts[$i].release" "$f")
      url=$(jq -r ".artifacts[$i].url" "$f");   want=$(jq -r ".artifacts[$i].sha256" "$f")
      arch_valid "$arch" || { echo "❌ $f: arch '$arch' not in ARCHES" >&2; exit 1; }
      targets=$(release_targets "$release") || exit 1
      tmp=$(mktemp --suffix .deb); curl -fsSL "$url" -o "$tmp"
      got=$(sha256sum "$tmp" | cut -d' ' -f1)
      [ "$got" = "$want" ] || { echo "❌ $name/$arch: sha256 mismatch (want $want, got $got)" >&2; rm -f "$tmp"; exit 1; }
      p=$(dpkg-deb -f "$tmp" Package); v=$(dpkg-deb -f "$tmp" Version); a=$(dpkg-deb -f "$tmp" Architecture)
      [ "$p" = "$name" ]    || { echo "❌ $f: name '$name' != deb Package '$p'" >&2; rm -f "$tmp"; exit 1; }
      [ "$v" = "$version" ] || { echo "❌ $f: version '$version' != deb Version '$v'" >&2; rm -f "$tmp"; exit 1; }
      [ "$a" = "$arch" ]    || { echo "❌ $f: arch '$arch' != deb Architecture '$a'" >&2; rm -f "$tmp"; exit 1; }
      for cn in $targets; do guard "$name" "$cn" "$arch"; place "$tmp" "$name" "$(basename "$url")" "$cn"; done
      rm -f "$tmp"; echo "   ✅ $release/$arch  $(basename "$url")"
    done
  done
fi

handle_manual() { # <deb> <release>
  dpkg-deb --info "$1" >/dev/null 2>&1 || { echo "❌ invalid .deb: $1" >&2; exit 1; }
  local name arch cn; name=$(dpkg-deb -f "$1" Package); arch=$(dpkg-deb -f "$1" Architecture)
  arch_valid "$arch" || { echo "❌ $1: arch '$arch' not in ARCHES" >&2; exit 1; }
  for cn in $(release_targets "$2"); do guard "$name" "$cn" "$arch"; place "$1" "$name" "$(basename "$1")" "$cn"; done
  echo "   ✅ $2/$arch  $(basename "$1")"
}

if [ -d "$LOCAL_DIR" ]; then
  echo ">> including manually-added debs from $LOCAL_DIR"
  for d in "$LOCAL_DIR"/*.deb;   do [ -e "$d" ] && handle_manual "$d" any; done
  for sub in "$LOCAL_DIR"/*/;    do [ -d "$sub" ] || continue; rel=$(basename "$sub")
    for d in "$sub"*.deb; do [ -e "$d" ] && handle_manual "$d" "$rel"; done; done
fi

echo "✅ hydrated $SITE/pool"
