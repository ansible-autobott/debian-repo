#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/tests/helpers.sh"
need dpkg-deb apt-ftparchive gpg
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
conf="$tmp/dists.conf"; printf 'DISTS="bookworm trixie"\nALIASES="stable:bookworm testing:trixie"\nARCHES="amd64"\n' > "$conf"
site="$tmp/_site"; debs="$tmp/debs"
make_deb "$debs" widget 1.0 amd64 any >/dev/null       # any -> both suites (identical bytes)
make_deb "$debs/bookworm" gadget 2.0 amd64 bk >/dev/null
# foo 1.0 amd64 is built DIFFERENTLY per release (distinct tag -> distinct bytes ->
# distinct sha256), exercising the per-release download grouping.
make_deb "$debs/bookworm" foo 1.0 amd64 foo-bkw >/dev/null
make_deb "$debs/trixie"   foo 1.0 amd64 foo-trx >/dev/null
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

# issue #2 — the "Add the repository" step lets you pick a suite ONLY when its
# release carries at least one package: a codename by its own pool, an alias by
# its target codename's pool. bookworm and trixie both carry packages here, so
# their codename tabs AND the aliases pointing at them (stable, testing) show.
for s in stable testing bookworm trixie; do
  grep -q "id=\"su-$s\"" "$site/index.html" || { echo "❌ suite picker missing radio for '$s'"; fail=1; }
  grep -q "Suites: $s"   "$site/index.html" || { echo "❌ suite picker missing 'Suites: $s' snippet"; fail=1; }
done

# A genuinely empty repo has nothing installable in any release, so NO suite is
# selectable — neither codenames nor the aliases pointing at them — and a short
# note stands in for the picker.
empty="$tmp/_empty"; mkdir -p "$empty"
DISTS_CONF="$conf" "$ROOT/scripts/render-index.sh" "$empty" >/dev/null 2>&1
grep -q 'id="su-' "$empty/index.html" && { echo "❌ empty repo must offer no selectable suites"; fail=1; }
grep -q 'No releases published yet' "$empty/index.html" || { echo "❌ empty repo should show the 'no releases' note in place of the picker"; fail=1; }

[ "$fail" = 0 ] && echo "PASS render_test" || { echo "FAIL render_test"; exit 1; }
