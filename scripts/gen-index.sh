#!/usr/bin/env bash
# Generate and GPG-sign the APT index for <site>, for every Debian codename in
# conf/dists.conf (from its hydrated per-codename pool, scripts/hydrate.sh)
# plus a signed tree for every rolling-suite alias (conf/dists.conf ALIASES),
# then stage the static site files (public key, sources, .nojekyll) and render
# the landing page with the pool's package listing injected into its Packages
# tab.
# Usage: gen-index.sh <site> <apt-ftparchive-conf> <key-email>
# GNUPGHOME must point at the keyring holding the signing key (set by the Makefile).
# DISTS_CONF may override the conf/dists.conf path (used by tests).
set -euo pipefail

SITE="${1:-_site}"
CONF="${2:?apt-ftparchive conf path}"
KEY_EMAIL="${3:?signing key email}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF_ABS="$ROOT/$CONF"; [ -f "$CONF_ABS" ] || CONF_ABS="$CONF"
. "$(dirname "$0")/dists-lib.sh"; dists_load "${DISTS_CONF:-$ROOT/conf/dists.conf}"

# The landing page is rendered by scripts/render-index.sh (shared with
# `make serve`, which reuses it to preview an empty repo with demo content).

sign_dist() { # <dist-dir>
  gpg --batch --yes --local-user "$KEY_EMAIL" --clearsign -o "$1/InRelease" "$1/Release"
  gpg --batch --yes --local-user "$KEY_EMAIL" -abs        -o "$1/Release.gpg" "$1/Release"
}

mkdir -p "$SITE"; rm -rf "$SITE/dists"
(
  cd "$SITE"
  for cn in $DISTS; do
    mkdir -p "pool/$cn/main"
    for arch in $ARCHES; do
      mkdir -p "dists/$cn/main/binary-$arch"
      echo ">> indexing $cn/$arch"
      apt-ftparchive --arch "$arch" packages "pool/$cn/main" > "dists/$cn/main/binary-$arch/Packages"
      gzip -9 -kf "dists/$cn/main/binary-$arch/Packages"
    done
    echo ">> Release + sign: $cn"
    apt-ftparchive -c "$CONF_ABS" \
      -o APT::FTPArchive::Release::Suite="$cn" \
      -o APT::FTPArchive::Release::Codename="$cn" \
      -o APT::FTPArchive::Release::Architectures="$ARCHES" \
      release "dists/$cn" > "dists/$cn/Release"
    sign_dist "dists/$cn"
  done
  while read -r al target; do
    [ -n "$al" ] || continue
    echo ">> alias $al -> $target"
    rm -rf "dists/$al"; mkdir -p "dists/$al/main"
    cp -r "dists/$target/main/binary-"* "dists/$al/main/"
    apt-ftparchive -c "$CONF_ABS" \
      -o APT::FTPArchive::Release::Suite="$al" \
      -o APT::FTPArchive::Release::Codename="$target" \
      -o APT::FTPArchive::Release::Architectures="$ARCHES" \
      release "dists/$al" > "dists/$al/Release"
    sign_dist "dists/$al"
  done < <(alias_pairs)
)

# static files served from the site root
cp "$ROOT/autobott-archive-keyring.gpg" \
   "$ROOT/autobott-archive-keyring.asc" \
   "$ROOT/autobott.sources" \
   "$SITE/"
# landing page, with the package listing injected into the "Packages" tab
"$ROOT/scripts/render-index.sh" "$SITE"
touch "$SITE/.nojekyll"

echo "✅ built + signed $SITE/"
