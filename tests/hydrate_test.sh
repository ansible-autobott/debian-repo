#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/tests/helpers.sh"
need dpkg-deb
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
conf="$tmp/dists.conf"; printf 'DISTS="bookworm trixie"\nALIASES="stable:bookworm"\nARCHES="amd64 arm64"\n' > "$conf"
site="$tmp/_site"; debs="$tmp/debs"

# one 'any' deb -> lands in every codename pool; one bookworm-only deb
make_deb "$debs" widget 1.0 amd64 any >/dev/null
make_deb "$debs/bookworm" gadget 2.0 amd64 bk >/dev/null

DISTS_CONF="$conf" "$ROOT/scripts/hydrate.sh" "$site" "$debs" || { echo "FAIL hydrate ran"; exit 1; }

fail=0
[ -f "$site/pool/bookworm/main/w/widget/"*.deb ] 2>/dev/null || { echo "❌ widget missing from bookworm"; fail=1; }
[ -f "$site/pool/trixie/main/w/widget/"*.deb ]   2>/dev/null || { echo "❌ widget missing from trixie (any should expand)"; fail=1; }
[ -f "$site/pool/bookworm/main/g/gadget/"*.deb ] 2>/dev/null || { echo "❌ gadget missing from bookworm"; fail=1; }
ls "$site/pool/trixie/main/g/gadget/" >/dev/null 2>&1 && { echo "❌ gadget must NOT be in trixie"; fail=1; }

# unknown release subdir (not in DISTS, not "any") must fail hard, not silently skip
site2="$tmp/_site2"; debs2="$tmp/debs2"
make_deb "$debs2/bogus" widget 1.0 amd64 x >/dev/null
if DISTS_CONF="$conf" "$ROOT/scripts/hydrate.sh" "$site2" "$debs2" >/dev/null 2>&1; then
  echo "❌ hydrate must fail on unknown release subdir"; fail=1
else
  echo "✅ unknown release subdir rejected"
fi

[ "$fail" = 0 ] && echo "PASS hydrate_test" || { echo "FAIL hydrate_test"; exit 1; }
