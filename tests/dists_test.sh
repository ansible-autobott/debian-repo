#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok(){ echo "✅ $1"; }
bad(){ echo "❌ $1"; fail=1; }

# load the lib fresh with a given config body; returns dists_load's exit code
try_load(){ ( set +e; . "$ROOT/scripts/dists-lib.sh"; dists_load "$1" >/dev/null 2>&1; echo $?; ); }

good="$tmp/good.conf"
printf 'DISTS="bookworm trixie sid"\nALIASES="stable:bookworm testing:trixie"\nARCHES="amd64 arm64"\n' > "$good"
[ "$(try_load "$good")" = 0 ] && ok "valid config loads" || bad "valid config should load"

# expansion + membership
( . "$ROOT/scripts/dists-lib.sh"; dists_load "$good" >/dev/null
  [ "$(release_targets any | tr '\n' ' ')" = "bookworm trixie sid " ] || exit 1
  [ "$(release_targets trixie)" = "trixie" ] || exit 1
  release_targets forky >/dev/null 2>&1 && exit 1
  arch_valid all && arch_valid amd64 && ! arch_valid ppc64 || exit 1
  [ "$(alias_pairs | sort | tr '\n' ';')" = "stable bookworm;testing trixie;" ] || exit 1
) && ok "helpers behave" || bad "helpers wrong"

# bad configs must fail
for body in \
  'DISTS=""\nARCHES="amd64"' \
  'DISTS="bookworm"\nALIASES="stable:sid"\nARCHES="amd64"' \
  'DISTS="bookworm"\nALIASES="bookworm:bookworm"\nARCHES="amd64"' \
  'DISTS="Bad Name"\nARCHES="amd64"' ; do
  c="$tmp/bad.conf"; printf "$body\n" > "$c"
  [ "$(try_load "$c")" != 0 ] && ok "rejected: $body" || bad "should reject: $body"
done

[ "$fail" = 0 ] && echo "PASS dists_test" || { echo "FAIL dists_test"; exit 1; }
