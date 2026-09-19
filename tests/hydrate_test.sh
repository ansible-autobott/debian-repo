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

# collision guard: two debs, same Package/Version/Arch, both -> bookworm => hard fail
site3="$tmp/_site3"; debs3="$tmp/debs3"
make_deb "$debs3/bookworm" widget 1.0 amd64 one >/dev/null
make_deb "$debs3/bookworm" widget 1.0 amd64 two >/dev/null
if err=$(DISTS_CONF="$conf" "$ROOT/scripts/hydrate.sh" "$site3" "$debs3" 2>&1); then
  echo "❌ hydrate must fail on duplicate (pkg,codename,arch)"; fail=1
else
  echo "✅ collision guard rejected duplicate"
  # the message must name BOTH claimants: with several packages/*.json per app this
  # is the failure you hit, and "duplicate artifact: x for y/z" alone is undebuggable
  printf '%s' "$err" | grep -q "widget_1.0_one_amd64.deb" && printf '%s' "$err" | grep -q "widget_1.0_two_amd64.deb" \
    || { echo "❌ collision message must name both sources, got: $err"; fail=1; }
fi

# Same package name, DIFFERENT version per release (the klassy shape) must merge:
# one version for bookworm, another for trixie. Different releases never collide,
# so both land — this is what lets an app publish per-suite versions.
site4="$tmp/_site4"; debs4="$tmp/debs4"
make_deb "$debs4/bookworm" klassy '6.5.3-1~bookworm' amd64 bkw >/dev/null
make_deb "$debs4/trixie"   klassy '6.7.2-1~trixie'   amd64 trx >/dev/null
if DISTS_CONF="$conf" "$ROOT/scripts/hydrate.sh" "$site4" "$debs4" >/dev/null 2>&1; then
  [ -f "$site4/pool/bookworm/main/k/klassy/klassy_6.5.3-1~bookworm_amd64.deb" ] \
    || { echo "❌ klassy 6.5.3 missing from bookworm pool"; fail=1; }
  [ -f "$site4/pool/trixie/main/k/klassy/klassy_6.7.2-1~trixie_amd64.deb" ] \
    || { echo "❌ klassy 6.7.2 missing from trixie pool"; fail=1; }
else
  echo "❌ hydrate must accept one package at a different version per release"; fail=1
fi

[ "$fail" = 0 ] && echo "PASS hydrate_test" || { echo "FAIL hydrate_test"; exit 1; }
