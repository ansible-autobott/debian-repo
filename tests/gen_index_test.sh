#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/tests/helpers.sh"
need dpkg-deb apt-ftparchive gpg
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
conf="$tmp/dists.conf"; printf 'DISTS="bookworm trixie"\nALIASES="stable:bookworm"\nARCHES="amd64 arm64"\n' > "$conf"
site="$tmp/_site"; debs="$tmp/debs"
make_deb "$debs" widget 1.0 amd64 any >/dev/null
export GNUPGHOME="$tmp/gnupg"; make_test_key "$GNUPGHOME" contact@andresbott.com

DISTS_CONF="$conf" "$ROOT/scripts/hydrate.sh" "$site" "$debs"
DISTS_CONF="$conf" "$ROOT/scripts/gen-index.sh" "$site" "$ROOT/conf/apt-ftparchive.conf" contact@andresbott.com

fail=0
for s in bookworm trixie stable; do
  [ -f "$site/dists/$s/InRelease" ] || { echo "❌ $s/InRelease missing"; fail=1; continue; }
  GNUPGHOME="$GNUPGHOME" gpg --verify "$site/dists/$s/InRelease" >/dev/null 2>&1 || { echo "❌ $s signature bad"; fail=1; }
done
grep -q '^Suite: stable$'    "$site/dists/stable/Release" || { echo "❌ alias Suite wrong"; fail=1; }
grep -q '^Codename: bookworm$' "$site/dists/stable/Release" || { echo "❌ alias Codename wrong"; fail=1; }
[ "$fail" = 0 ] && echo "PASS gen_index_test" || { echo "FAIL gen_index_test"; exit 1; }
