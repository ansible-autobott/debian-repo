#!/usr/bin/env bash
# Generate and GPG-sign the APT index for <site> from its hydrated pool, then
# stage the static site files (public key, sources, .nojekyll) and render the
# landing page with the pool's package listing injected into its Packages tab.
# Usage: gen-index.sh <site> <apt-ftparchive-conf> <key-email> [arch...]
# GNUPGHOME must point at the keyring holding the signing key (set by the Makefile).
set -euo pipefail

SITE="${1:-_site}"
CONF="${2:?apt-ftparchive conf path (relative to repo root)}"
KEY_EMAIL="${3:?signing key email}"
shift 3
ARCHES=("$@")
[ ${#ARCHES[@]} -gt 0 ] || ARCHES=(amd64 arm64)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF_ABS="$ROOT/$CONF"

# The landing page is rendered by scripts/render-index.sh (shared with
# `make serve`, which reuses it to preview an empty repo with demo content).

mkdir -p "$SITE/pool/main"
rm -rf "$SITE/dists"
for arch in "${ARCHES[@]}"; do
  mkdir -p "$SITE/dists/stable/main/binary-$arch"
done

(
  cd "$SITE"
  for arch in "${ARCHES[@]}"; do
    echo ">> indexing $arch"
    apt-ftparchive --arch "$arch" packages pool/main > "dists/stable/main/binary-$arch/Packages"
    gzip -9 -kf "dists/stable/main/binary-$arch/Packages"
  done
  echo ">> generating Release"
  apt-ftparchive -c "$CONF_ABS" release dists/stable > dists/stable/Release
  echo ">> signing (InRelease + Release.gpg)"
  gpg --batch --yes --local-user "$KEY_EMAIL" --clearsign -o dists/stable/InRelease dists/stable/Release
  gpg --batch --yes --local-user "$KEY_EMAIL" -abs -o dists/stable/Release.gpg dists/stable/Release
)

# static files served from the site root
cp "$ROOT/autobott-archive-keyring.gpg" \
   "$ROOT/autobott-archive-keyring.asc" \
   "$ROOT/autobott.sources" \
   "$SITE/"
# landing page, with the package listing injected into the "Packages" tab
"$ROOT/scripts/render-index.sh" "$SITE" "${ARCHES[@]}"
touch "$SITE/.nojekyll"

echo "✅ built + signed $SITE/"
