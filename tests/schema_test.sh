#!/usr/bin/env bash
# Schema regression tests. Every fixture under tests/fixtures/valid/ must validate
# against schema/package.schema.json; every one under tests/fixtures/invalid/ must
# be rejected. Run via `make test`.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEMA="$ROOT/schema/package.schema.json"

command -v check-jsonschema >/dev/null 2>&1 || {
  echo "❌ check-jsonschema not found (pip install check-jsonschema)"; exit 1; }

fail=0
shopt -s nullglob

for f in "$ROOT"/tests/fixtures/valid/*.json; do
  if check-jsonschema --schemafile "$SCHEMA" "$f" >/dev/null 2>&1; then
    echo "✅ valid:   $(basename "$f")"
  else
    echo "❌ expected VALID but was rejected:   $(basename "$f")"; fail=1
  fi
done

for f in "$ROOT"/tests/fixtures/invalid/*.json; do
  if check-jsonschema --schemafile "$SCHEMA" "$f" >/dev/null 2>&1; then
    echo "❌ expected INVALID but was accepted: $(basename "$f")"; fail=1
  else
    echo "✅ invalid: $(basename "$f") (correctly rejected)"
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "✅ all schema tests passed"
else
  echo "❌ schema tests failed"
fi
exit "$fail"
