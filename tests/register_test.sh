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
[ "$fail" = 0 ] && echo "PASS register_test" || { echo "FAIL register_test"; exit 1; }
