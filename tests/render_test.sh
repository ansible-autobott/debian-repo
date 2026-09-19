#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/tests/helpers.sh"
need dpkg-deb apt-ftparchive gpg
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
conf="$tmp/dists.conf"; printf 'DISTS="bookworm trixie"\nALIASES="stable:bookworm testing:trixie"\nARCHES="amd64 arm64"\n' > "$conf"
site="$tmp/_site"; debs="$tmp/debs"
make_deb "$debs" widget 1.0 amd64 any >/dev/null       # any -> both suites (identical bytes)
make_deb "$debs/bookworm" gadget 2.0 amd64 bk >/dev/null
# foo 1.0 amd64 is built DIFFERENTLY per release (distinct tag -> distinct bytes ->
# distinct sha256), exercising the per-release download grouping.
make_deb "$debs/bookworm" foo 1.0 amd64 foo-bkw >/dev/null
make_deb "$debs/trixie"   foo 1.0 amd64 foo-trx >/dev/null
# bar ships a DIFFERENT VERSION per release (the klassy shape: stable's libraries
# can only build an older upstream). It is still one package and must be listed
# once, not as "bar 1.2.0" plus a separate "bar 2.0.0" entry.
make_deb "$debs/bookworm" bar 1.2.0-1~bookworm amd64 bar-bkw >/dev/null
make_deb "$debs/trixie"   bar 2.0.0-1~trixie   amd64 bar-trx >/dev/null
# baz is the pathological case uniqueness allows: within ONE release its two
# arches sit at different versions (a half-finished matrix). No single version
# describes the trixie group, so the version must move onto each download link.
make_deb "$debs/trixie" baz 3.0.0-1 amd64 baz-a >/dev/null
make_deb "$debs/trixie" baz 3.1.0-1 arm64 baz-b >/dev/null
export GNUPGHOME="$tmp/gnupg"; make_test_key "$GNUPGHOME" contact@andresbott.com
DISTS_CONF="$conf" "$ROOT/scripts/hydrate.sh" "$site" "$debs"
DISTS_CONF="$conf" "$ROOT/scripts/gen-index.sh" "$site" "$ROOT/conf/apt-ftparchive.conf" contact@andresbott.com
DISTS_CONF="$conf" "$ROOT/scripts/render-index.sh" "$site"

fail=0
grep -q 'widget' "$site/index.html" || { echo "❌ widget not listed"; fail=1; }
grep -q 'gadget' "$site/index.html" || { echo "❌ gadget not listed"; fail=1; }
grep -q 'bookworm' "$site/index.html" || { echo "❌ release tag 'bookworm' missing"; fail=1; }
grep -q 'trixie'   "$site/index.html" || { echo "❌ release tag 'trixie' missing"; fail=1; }

# row-scoped checks: each package is rendered as one <details>...</details> line,
# so grepping that line's own <span class="rel"> tags proves per-package release
# scoping — not just that a codename string appears somewhere on the page.
widget_row=$(grep '<code>widget</code>' "$site/index.html")
gadget_row=$(grep '<code>gadget</code>' "$site/index.html")
echo "$widget_row" | grep -q 'class="rel">bookworm</span>' && echo "$widget_row" | grep -q 'class="rel">trixie</span>' \
  || { echo "❌ widget (any) must carry both bookworm and trixie tags"; fail=1; }
echo "$gadget_row" | grep -q 'class="rel">bookworm</span>' || { echo "❌ gadget must carry its bookworm tag"; fail=1; }
echo "$gadget_row" | grep -q 'class="rel">trixie</span>'  && { echo "❌ gadget (bookworm-only) must NOT advertise trixie"; fail=1; }

# issue #1 — per-release builds must each be downloadable. foo has DIFFERENT
# bytes in bookworm vs trixie, so both pool copies must appear as download links
# (grouped by release), not collapse to a single per-arch link.
foo_row=$(grep '<code>foo</code>' "$site/index.html")
echo "$foo_row" | grep -q 'href="pool/bookworm/main/f/foo/foo_1.0_amd64.deb"' \
  || { echo "❌ foo's bookworm build is not downloadable"; fail=1; }
echo "$foo_row" | grep -q 'href="pool/trixie/main/f/foo/foo_1.0_amd64.deb"' \
  || { echo "❌ foo's trixie build is not downloadable"; fail=1; }
echo "$foo_row" | grep -q 'downloads-by-rel' \
  || { echo "❌ foo (differing per-release builds) must group downloads by release"; fail=1; }

# widget is "any" (identical bytes in every suite) -> stays a flat per-arch list.
echo "$widget_row" | grep -q 'downloads-by-rel' \
  && { echo "❌ widget (identical 'any' build) must NOT be grouped by release"; fail=1; }

# A package with a DIFFERENT VERSION per release is ONE listing, never one row per
# version — the whole point of grouping by name. The collapsed row shows the newest
# version plus a "+N more" hint; the versions themselves live in the expanded body,
# one beside each release's downloads.
[ "$(grep -c '<code>bar</code>' "$site/index.html")" = 1 ] \
  || { echo "❌ bar must be listed exactly once, not once per version"; fail=1; }
bar_row=$(grep '<code>bar</code>' "$site/index.html")
echo "$bar_row" | grep -q 'class="ver">2.0.0-1~trixie</span>' \
  || { echo "❌ bar's summary must show the newest version (2.0.0-1~trixie)"; fail=1; }
echo "$bar_row" | grep -q 'class="ver-multi">+1 more</span>' \
  || { echo "❌ bar's summary must hint that another version exists"; fail=1; }
echo "$bar_row" | grep -q 'class="rel-h">bookworm<span class="rel-v">1.2.0-1~bookworm</span>' \
  || { echo "❌ bar's bookworm group must be labelled with its own version"; fail=1; }
echo "$bar_row" | grep -q 'class="rel-h">trixie<span class="rel-v">2.0.0-1~trixie</span>' \
  || { echo "❌ bar's trixie group must be labelled with its own version"; fail=1; }
# both per-release builds must remain downloadable, each from its own suite's pool
echo "$bar_row" | grep -q 'href="pool/bookworm/main/b/bar/bar_1.2.0-1~bookworm_amd64.deb"' \
  || { echo "❌ bar's bookworm build is not downloadable"; fail=1; }
echo "$bar_row" | grep -q 'href="pool/trixie/main/b/bar/bar_2.0.0-1~trixie_amd64.deb"' \
  || { echo "❌ bar's trixie build is not downloadable"; fail=1; }
# bar's arches agree within each release, so the version belongs on the group
# heading and must NOT be repeated on every download link
echo "$bar_row" | grep -q 'dl-v' \
  && { echo "❌ bar must label the release group, not each download"; fail=1; }

# baz: arches disagree INSIDE trixie, so no group version is truthful — each link
# carries its own instead, and the heading carries none.
[ "$(grep -c '<code>baz</code>' "$site/index.html")" = 1 ] \
  || { echo "❌ baz must be listed exactly once"; fail=1; }
baz_row=$(grep '<code>baz</code>' "$site/index.html")
echo "$baz_row" | grep -q 'class="rel-h">trixie</span>' \
  || { echo "❌ baz's trixie heading must claim no single version"; fail=1; }
echo "$baz_row" | grep -q 'class="dl-v">3.0.0-1</span>' \
  || { echo "❌ baz's amd64 download must be labelled 3.0.0-1"; fail=1; }
echo "$baz_row" | grep -q 'class="dl-v">3.1.0-1</span>' \
  || { echo "❌ baz's arm64 download must be labelled 3.1.0-1"; fail=1; }

# a single-version package must NOT carry the multi-version hint
echo "$gadget_row" | grep -q 'ver-multi' \
  && { echo "❌ gadget (one version) must not show a '+N more' hint"; fail=1; }
# ...nor repeat its single version next to each release group (the summary has it)
echo "$foo_row" | grep -q 'rel-v' \
  && { echo "❌ foo (one version) must not repeat its version per release group"; fail=1; }

# issue #2 — the "Add the repository" step lets you pick a suite ONLY when its
# release carries at least one package: a codename by its own pool, an alias by
# its target codename's pool. bookworm and trixie both carry packages here, so
# their codename tabs AND the aliases pointing at them (stable, testing) show.
for s in stable testing bookworm trixie; do
  grep -q "id=\"su-$s\"" "$site/index.html" || { echo "❌ suite picker missing radio for '$s'"; fail=1; }
  grep -q "Suites: $s"   "$site/index.html" || { echo "❌ suite picker missing 'Suites: $s' snippet"; fail=1; }
done

# A package's releases are listed in conf/dists.conf order (most stable first),
# NOT alphabetically: "forky, sid, trixie" tells a user nothing about which suite
# to pick. This needs its own conf — in the bookworm/trixie one above the two
# orders coincide, so it could not detect a regression.
ord_conf="$tmp/ord.conf"
printf 'DISTS="trixie forky sid"\nALIASES="stable:trixie testing:forky unstable:sid"\nARCHES="amd64"\n' > "$ord_conf"
ord_site="$tmp/_ord"; ord_debs="$tmp/ord_debs"
make_deb "$ord_debs/trixie" klassy '6.5.3-1~trixie' amd64 t >/dev/null
make_deb "$ord_debs/forky"  klassy '6.7.2-1~forky'  amd64 f >/dev/null
make_deb "$ord_debs/sid"    klassy '6.7.2-1~sid'    amd64 s >/dev/null
DISTS_CONF="$ord_conf" "$ROOT/scripts/hydrate.sh" "$ord_site" "$ord_debs" >/dev/null
DISTS_CONF="$ord_conf" "$ROOT/scripts/gen-index.sh" "$ord_site" "$ROOT/conf/apt-ftparchive.conf" contact@andresbott.com >/dev/null
DISTS_CONF="$ord_conf" "$ROOT/scripts/render-index.sh" "$ord_site"
klassy_row=$(grep '<code>klassy</code>' "$ord_site/index.html")
got=$(printf '%s' "$klassy_row" | grep -o 'class="rel">[a-z]*' | awk -F'>' '{print $2}' | tr '\n' ' ')
[ "$got" = "trixie forky sid " ] || { echo "❌ summary release tags must follow DISTS order, got: $got"; fail=1; }
got=$(printf '%s' "$klassy_row" | grep -o 'class="rel-h">[a-z]*' | awk -F'>' '{print $2}' | tr '\n' ' ')
[ "$got" = "trixie forky sid " ] || { echo "❌ download groups must follow DISTS order, got: $got"; fail=1; }

# A genuinely empty repo has nothing installable in any release, so NO suite is
# selectable — neither codenames nor the aliases pointing at them — and a short
# note stands in for the picker.
empty="$tmp/_empty"; mkdir -p "$empty"
DISTS_CONF="$conf" "$ROOT/scripts/render-index.sh" "$empty" >/dev/null 2>&1
grep -q 'id="su-' "$empty/index.html" && { echo "❌ empty repo must offer no selectable suites"; fail=1; }
grep -q 'No releases published yet' "$empty/index.html" || { echo "❌ empty repo should show the 'no releases' note in place of the picker"; fail=1; }

[ "$fail" = 0 ] && echo "PASS render_test" || { echo "FAIL render_test"; exit 1; }
