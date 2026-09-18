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

# empty-suite: a configured codename that nothing targets must still get a signed Release
confE="$tmp/distsE.conf"; printf 'DISTS="bookworm sid"\nALIASES=""\nARCHES="amd64"\n' > "$confE"
siteE="$tmp/_siteE"; debsE="$tmp/debsE"
make_deb "$debsE/bookworm" widget 1.0 amd64 bk >/dev/null   # bookworm only => sid stays empty
DISTS_CONF="$confE" "$ROOT/scripts/hydrate.sh"   "$siteE" "$debsE"
DISTS_CONF="$confE" "$ROOT/scripts/gen-index.sh" "$siteE" "$ROOT/conf/apt-ftparchive.conf" contact@andresbott.com
if [ -f "$siteE/dists/sid/InRelease" ] && gpg --verify "$siteE/dists/sid/InRelease" >/dev/null 2>&1; then
  echo "✅ empty suite sid signed"
else
  echo "❌ empty suite sid must have a verifying InRelease"; fail=1
fi
[ -f "$siteE/dists/sid/main/binary-amd64/Packages" ] || { echo "❌ empty suite sid missing Packages index"; fail=1; }
grep -q '^Suite: sid$' "$siteE/dists/sid/Release" && grep -q '^Codename: sid$' "$siteE/dists/sid/Release" || { echo "❌ sid Release Suite/Codename wrong"; fail=1; }

# --arch filename footgun: a SOURCE .deb whose filename is NOT arch-trailing must still
# be indexed. apt-ftparchive --arch selects debs by filename (*_<arch>.deb / *_all.deb),
# ignoring the control Architecture field, so a source name like widget_9.9_amd64_EXTRA.deb
# (arch not last) would be silently dropped — unless hydrate canonicalizes the pooled
# filename to <Package>_<Version>_<Architecture>.deb (which it does). RED before that fix.
confF="$tmp/distsF.conf"; printf 'DISTS="bookworm"\nALIASES=""\nARCHES="amd64"\n' > "$confF"
siteF="$tmp/_siteF"; debsF="$tmp/debsF"; mkdir -p "$debsF/bookworm"
srcF=$(make_deb "$tmp/buildF" widget 9.9 amd64 EXTRA)          # control Architecture: amd64
mv "$srcF" "$debsF/bookworm/widget_9.9_amd64_EXTRA.deb"        # SOURCE name: arch NOT trailing
DISTS_CONF="$confF" "$ROOT/scripts/hydrate.sh"   "$siteF" "$debsF"
DISTS_CONF="$confF" "$ROOT/scripts/gen-index.sh" "$siteF" "$ROOT/conf/apt-ftparchive.conf" contact@andresbott.com
if grep -q '^Package: widget' "$siteF/dists/bookworm/main/binary-amd64/Packages"; then
  echo "✅ non-arch-trailing source name still indexed (pool filename canonicalized)"
else
  echo "❌ non-arch-trailing source name dropped from Packages index"; fail=1
fi

[ "$fail" = 0 ] && echo "PASS gen_index_test" || { echo "FAIL gen_index_test"; exit 1; }
