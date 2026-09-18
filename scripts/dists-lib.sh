# Shared loader + validation for conf/dists.conf. Source this, then call
# dists_load. Sourced by hydrate.sh, gen-index.sh, render-index.sh.
# shellcheck shell=bash

dists_has() { local d; for d in $DISTS; do [ "$d" = "$1" ] && return 0; done; return 1; }
arch_valid() { [ "$1" = all ] && return 0; local a; for a in $ARCHES; do [ "$a" = "$1" ] && return 0; done; return 1; }

release_targets() {
  if [ "$1" = any ]; then printf '%s\n' $DISTS; return 0; fi
  dists_has "$1" || { echo "❌ unknown release '$1' (not in DISTS, not 'any')" >&2; return 1; }
  printf '%s\n' "$1"
}

alias_pairs() { local p; for p in ${ALIASES:-}; do printf '%s %s\n' "${p%%:*}" "${p##*:}"; done; }

dists_validate() {
  local name target pair
  [ -n "${DISTS// }" ] || { echo "❌ DISTS is empty in config" >&2; return 1; }
  [ -n "${ARCHES// }" ] || { echo "❌ ARCHES is empty in config" >&2; return 1; }
  for name in $DISTS; do
    printf '%s' "$name" | grep -qE '^[a-z0-9][a-z0-9.-]*$' \
      || { echo "❌ invalid suite name '$name'" >&2; return 1; }
  done
  for pair in ${ALIASES:-}; do
    name="${pair%%:*}"; target="${pair##*:}"
    { [ "$name" != "$pair" ] && [ -n "$name" ] && [ -n "$target" ]; } \
      || { echo "❌ malformed ALIASES entry '$pair' (want alias:target)" >&2; return 1; }
    printf '%s' "$name" | grep -qE '^[a-z0-9][a-z0-9.-]*$' \
      || { echo "❌ invalid alias name '$name'" >&2; return 1; }
    dists_has "$name" && { echo "❌ alias '$name' clashes with a codename in DISTS" >&2; return 1; }
    dists_has "$target" || { echo "❌ alias '$name' -> unknown target '$target'" >&2; return 1; }
  done
  return 0
}

dists_load() {
  local conf="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/conf/dists.conf}"
  [ -f "$conf" ] || { echo "❌ missing config: $conf" >&2; return 1; }
  # shellcheck disable=SC1090
  . "$conf"
  : "${DISTS:?DISTS must be set in $conf}"
  : "${ARCHES:?ARCHES must be set in $conf}"
  ALIASES="${ALIASES:-}"
  dists_validate
}
