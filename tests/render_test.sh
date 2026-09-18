#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/tests/helpers.sh"
need dpkg-deb apt-ftparchive gpg
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
conf="$tmp/dists.conf"; printf 'DISTS="bookworm trixie"\nALIASES=""\nARCHES="amd64"\n' > "$conf"
site="$tmp/_site"; debs="$tmp/debs"
make_deb "$debs" widget 1.0 amd64 any >/dev/null       # any -> both suites
make_deb "$debs/bookworm" gadget 2.0 amd64 bk >/dev/null
export GNUPGHOME="$tmp/gnupg"; make_test_key "$GNUPGHOME" contact@andresbott.com
DISTS_CONF="$conf" "$ROOT/scripts/hydrate.sh" "$site" "$debs"
DISTS_CONF="$conf" "$ROOT/scripts/gen-index.sh" "$site" "$ROOT/conf/apt-ftparchive.conf" contact@andresbott.com
DISTS_CONF="$conf" "$ROOT/scripts/render-index.sh" "$site"

fail=0
grep -q 'widget' "$site/index.html" || { echo "❌ widget not listed"; fail=1; }
grep -q 'gadget' "$site/index.html" || { echo "❌ gadget not listed"; fail=1; }
grep -q 'bookworm' "$site/index.html" || { echo "❌ release tag 'bookworm' missing"; fail=1; }
grep -q 'trixie'   "$site/index.html" || { echo "❌ release tag 'trixie' missing"; fail=1; }
# gadget is bookworm-only: it must not advertise trixie in its own row (spot check)
[ "$fail" = 0 ] && echo "PASS render_test" || { echo "FAIL render_test"; exit 1; }
