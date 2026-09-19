#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/tests/helpers.sh"
need dpkg-deb jq
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
dist="$tmp/dist"; out="$tmp/go-deps-view.json"
make_deb "$dist/bookworm" go-deps-view 1.3.0 amd64 bookworm >/dev/null
make_deb "$dist/trixie"   go-deps-view 1.3.0 amd64 trixie   >/dev/null
make_deb "$dist"          go-deps-view 1.3.0 arm64 flat     >/dev/null   # bare => any

"$ROOT/scripts/register.sh" --name go-deps-view --dist-dir "$dist" \
  --repo ansible-autobott/go-deps-view --tag v1.3.0 --out "$out"

fail=0
[ "$(jq -r '.artifacts | length' "$out")" = 3 ] || { echo "❌ expected 3 artifacts"; fail=1; }
jq -e '.artifacts[] | select(.arch=="arm64") | .release=="any"'      "$out" >/dev/null || { echo "❌ bare deb should be any"; fail=1; }
jq -e '[.artifacts[].release] | index("bookworm")' "$out" >/dev/null || { echo "❌ missing bookworm release"; fail=1; }
jq -e '[.artifacts[].release] | index("trixie")'   "$out" >/dev/null || { echo "❌ missing trixie release"; fail=1; }
if command -v check-jsonschema >/dev/null 2>&1; then
  check-jsonschema --schemafile "$ROOT/schema/package.schema.json" "$out" >/dev/null || { echo "❌ output fails schema"; fail=1; }
fi

# The version is read from the .deb, NOT derived from the tag: a tag need not be a
# bare version (klassy-deb tags "debian_sid-v6.7.2") and the packaging revision +
# suite suffix exist only in the .deb. hydrate cross-checks the .deb, so a
# tag-derived version would be rejected there instead of here.
dist2="$tmp/dist2"; out2="$tmp/klassy.sid.json"
make_deb "$dist2/sid" klassy '6.7.2-1~sid' amd64 sid >/dev/null
"$ROOT/scripts/register.sh" --name klassy --dist-dir "$dist2" \
  --repo ansible-autobott/klassy-deb --tag debian_sid-v6.7.2 --out "$out2" >/dev/null
[ "$(jq -r .version "$out2")" = '6.7.2-1~sid' ] \
  || { echo "❌ version must come from the deb (got '$(jq -r .version "$out2")')"; fail=1; }
# --tag still drives the asset URL
jq -e '.artifacts[0].url | test("/releases/download/debian_sid-v6\\.7\\.2/")' "$out2" >/dev/null \
  || { echo "❌ asset URL must be built from --tag"; fail=1; }
# and --out may be any packages/*.json name, so one app can own a file per
# release group (that is how differing per-suite versions are expressed)
[ "$(jq -r .name "$out2")" = klassy ] || { echo "❌ name should stay the package name"; fail=1; }

# One file describes ONE version, so a dist-dir mixing versions must fail loudly
# rather than silently picking one and having hydrate reject it later.
dist3="$tmp/dist3"
make_deb "$dist3/trixie" klassy '6.5.3-1~trixie' amd64 trx >/dev/null
make_deb "$dist3/sid"    klassy '6.7.2-1~sid'    amd64 sid >/dev/null
if err=$("$ROOT/scripts/register.sh" --name klassy --dist-dir "$dist3" \
           --repo ansible-autobott/klassy-deb --tag v6.7.2 --out "$tmp/mixed.json" 2>&1); then
  echo "❌ register must reject a dist-dir that mixes versions"; fail=1
else
  printf '%s' "$err" | grep -q 'mixes versions' \
    && echo "✅ mixed versions rejected" \
    || { echo "❌ mixed-version failure should say so, got: $err"; fail=1; }
fi

[ "$fail" = 0 ] && echo "PASS register_test" || { echo "FAIL register_test"; exit 1; }
