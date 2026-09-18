# Multi-release APT suites Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish genuinely different `.deb` builds per Debian release from one repo, so `apt` on each host installs the build matching its release.

**Architecture:** A single config file (`conf/dists.conf`) lists the real codename suites and rolling aliases. Each codename gets its own pool subtree and signed `dists/<codename>/`; each alias gets its own signed `dists/<alias>/` mirroring its target. Package entries tag every artifact with a release (or `any`). Shared config/validation lives in one sourced helper.

**Tech Stack:** Bash (`set -euo pipefail`), `apt-ftparchive` (apt-utils), `gpg`, `jq`, `dpkg-deb`, `check-jsonschema`, GNU Make, GitHub Actions + Pages.

**Spec:** `docs/superpowers/specs/2026-09-17-multi-release-apt-suites-design.md`

## Global Constraints

- Release/suite names configurable only via `conf/dists.conf`; **no codename hardcoded** in any script or the JSON schema.
- Suite/alias name pattern: `^[a-z0-9][a-z0-9.-]*$`. Artifact `arch` pattern: `^(all|[a-z0-9][a-z0-9-]*)$`. Artifact `release` pattern: `^(any|[a-z0-9][a-z0-9.-]*)$`.
- Package JSON: `release` is **required** per artifact; URLs must match `^https://`; `additionalProperties: false`; top-level `version` is single (partition by pool, not by version string).
- Membership checks (`release ∈ DISTS∪{any}`, `arch ∈ ARCHES∪{all}`) happen at hydrate time against `conf/dists.conf`, not in the schema.
- Default config: `DISTS="bookworm trixie sid"`, `ALIASES="stable:bookworm testing:trixie unstable:sid"`, `ARCHES="amd64 arm64"`.
- Aliases are **generated signed trees, never symlinks** (GitHub Pages does not serve symlinks reliably).
- Signing key email: `contact@andresbott.com`. Match existing script idioms: `set -euo pipefail`, `❌`/`✅`/`⚠️`/`>>` echo prefixes.
- Migration is non-breaking: a bare `dist/*.deb` / `debs/*.deb` (no release subdir) is treated as `release: "any"` → one build in every suite (today's behavior).
- Client default (spec §6, accepted): README leads with **match-the-host** install; the served `autobott.sources` keeps `Suites: stable` (the alias) as the simple alternative.

---

### Task 1: Config file + shared loader/validator

**Files:**
- Create: `conf/dists.conf`
- Create: `scripts/dists-lib.sh`
- Test: `tests/dists_test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces (sourced by later tasks):
  - `dists_load [conf-path]` — sources config, applies defaults, validates; sets globals `DISTS ALIASES ARCHES`. Non-zero on bad config.
  - `dists_has <name>` — true if `<name>` ∈ `DISTS`.
  - `arch_valid <arch>` — true if `<arch>` ∈ `ARCHES ∪ {all}`.
  - `release_targets <release>` — prints codenames a release expands to (`any`→all `DISTS`, codename→itself), one per line; non-zero + stderr on unknown.
  - `alias_pairs` — prints `alias target` per configured alias.

- [ ] **Step 1: Write the failing test**

```bash
# tests/dists_test.sh
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/dists_test.sh`
Expected: FAIL — `scripts/dists-lib.sh` does not exist yet.

- [ ] **Step 3: Create the config file**

```sh
# conf/dists.conf
# Which Debian releases this repository publishes, and the rolling-suite aliases.
# Single source of truth — sourced by scripts/dists-lib.sh (used by hydrate,
# gen-index, render-index) and read by the Makefile. No release name is
# hardcoded in any script. Move `stable` forward by editing ALIASES here.

# Real codename suites. Each gets a pool subtree and a signed dists/<codename>/.
DISTS="bookworm trixie sid"

# Rolling-suite aliases, "<alias>:<target>" space-separated. Each is published as
# its own signed dists/<alias>/ mirroring the target's Packages, with Release
# fields Suite=<alias>, Codename=<target>. No separate pool.
ALIASES="stable:bookworm testing:trixie unstable:sid"

# Architectures indexed in every suite.
ARCHES="amd64 arm64"
```

- [ ] **Step 4: Create the shared loader/validator**

```sh
# scripts/dists-lib.sh
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/dists_test.sh`
Expected: `PASS dists_test`.

- [ ] **Step 6: Commit**

```bash
git add conf/dists.conf scripts/dists-lib.sh tests/dists_test.sh
git commit -m "feat: configurable release/suite matrix (conf/dists.conf + loader)"
```

---

### Task 2: Schema — add `release`, relax `arch`; update fixtures

**Files:**
- Modify: `schema/package.schema.json:29-56` (artifact items)
- Modify: `tests/fixtures/valid/all-arch.json`
- Create: `tests/fixtures/valid/any-release.json`
- Create: `tests/fixtures/valid/per-release.json`
- Create: `tests/fixtures/invalid/missing-release.json`
- Create: `tests/fixtures/invalid/bad-release.json`
- Modify: `tests/schema_test.sh` (if it enumerates fixtures explicitly — otherwise it auto-discovers)

**Interfaces:**
- Consumes: nothing.
- Produces: artifact object shape `{release, arch, url, sha256}` consumed by Task 3 (hydrate) and Task 6 (register).

- [ ] **Step 1: Write the failing fixtures**

Create `tests/fixtures/valid/any-release.json`:

```json
{
  "name": "tool",
  "version": "0.9.0",
  "artifacts": [
    { "release": "any", "arch": "amd64", "url": "https://example.com/tool_0.9.0_amd64.deb", "sha256": "0000000000000000000000000000000000000000000000000000000000000000" }
  ]
}
```

Create `tests/fixtures/valid/per-release.json`:

```json
{
  "name": "go-deps-view",
  "version": "1.3.0",
  "artifacts": [
    { "release": "bookworm", "arch": "amd64", "url": "https://example.com/g_amd64_bookworm.deb", "sha256": "1111111111111111111111111111111111111111111111111111111111111111" },
    { "release": "trixie",   "arch": "arm64", "url": "https://example.com/g_arm64_trixie.deb",   "sha256": "2222222222222222222222222222222222222222222222222222222222222222" }
  ]
}
```

Create `tests/fixtures/invalid/missing-release.json` (no `release`):

```json
{
  "name": "tool",
  "version": "0.9.0",
  "artifacts": [
    { "arch": "amd64", "url": "https://example.com/tool_0.9.0_amd64.deb", "sha256": "0000000000000000000000000000000000000000000000000000000000000000" }
  ]
}
```

Create `tests/fixtures/invalid/bad-release.json` (`release` breaks the pattern):

```json
{
  "name": "tool",
  "version": "0.9.0",
  "artifacts": [
    { "release": "Bad Name", "arch": "amd64", "url": "https://example.com/tool_0.9.0_amd64.deb", "sha256": "0000000000000000000000000000000000000000000000000000000000000000" }
  ]
}
```

Add `release` to every artifact in `tests/fixtures/valid/all-arch.json` (use `"any"`).

- [ ] **Step 2: Run test to verify it fails**

Run: `make test` (or `bash tests/schema_test.sh`)
Expected: FAIL — under the current schema, `additionalProperties:false` rejects `release`, so the new *valid* fixtures fail validation.

- [ ] **Step 3: Update the schema**

Replace the artifact `items` block (`schema/package.schema.json:34-55`) so `release` is required and `arch`/`release` are patterns, not enums:

```json
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["release", "arch", "url", "sha256"],
        "properties": {
          "release": {
            "type": "string",
            "pattern": "^(any|[a-z0-9][a-z0-9.-]*)$",
            "description": "Target Debian release codename (must be one of conf/dists.conf DISTS), or \"any\" for a release-agnostic build placed into every configured suite. Membership is checked at hydrate time against the repo config, not here, so DISTS stays editable without touching this schema."
          },
          "arch": {
            "type": "string",
            "pattern": "^(all|[a-z0-9][a-z0-9-]*)$",
            "description": "Debian architecture (must match the .deb's Architecture and be one of conf/dists.conf ARCHES). \"all\" is arch-independent and indexed under every architecture."
          },
          "url": {
            "type": "string",
            "format": "uri",
            "pattern": "^https://",
            "description": "Direct HTTPS download URL of the .deb (e.g. a GitHub Release asset)."
          },
          "sha256": {
            "type": "string",
            "pattern": "^[a-f0-9]{64}$",
            "description": "Lowercase hex SHA-256 of the .deb; verified after download."
          }
        }
      }
```

- [ ] **Step 4: Ensure the test exercises invalid fixtures**

Confirm `tests/schema_test.sh` asserts every `tests/fixtures/valid/*.json` passes and every `tests/fixtures/invalid/*.json` fails. If it hardcodes filenames, add the four new fixtures; if it globs the directories, no change needed.

- [ ] **Step 5: Run test to verify it passes**

Run: `make test`
Expected: PASS — valid fixtures validate, invalid ones are rejected.

- [ ] **Step 6: Commit**

```bash
git add schema/package.schema.json tests/fixtures tests/schema_test.sh
git commit -m "feat: add required per-artifact release field to package schema"
```

---

### Task 3: hydrate — per-codename pool, release expansion, collision guard, manual `debs/<release>/`

**Files:**
- Modify: `scripts/hydrate.sh` (source lib; `place()` gains codename; per-artifact validate/expand/guard; manual debs subdirs)
- Create: `tests/helpers.sh` (shared `make_deb`, `make_test_key`, `need`)
- Create: `tests/hydrate_test.sh`

**Interfaces:**
- Consumes: `dists_load`, `release_targets`, `arch_valid` (Task 1); artifact `{release, arch, url, sha256}` (Task 2).
- Produces: pool layout `<site>/pool/<codename>/main/<letter>/<pkg>/<basename>` consumed by Task 4 (gen-index).

- [ ] **Step 1: Write shared test helpers**

```bash
# tests/helpers.sh — shared helpers for shell integration tests. Source, don't run.
# shellcheck shell=bash
need(){ for c in "$@"; do command -v "$c" >/dev/null 2>&1 || { echo "⚠️  skipping: missing '$c'"; exit 0; }; done; }

# make_deb <outdir> <name> <version> <arch> [tag] -> prints built .deb path
make_deb(){
  local outdir="$1" name="$2" ver="$3" arch="$4" tag="${5:-x}" root
  root="$(mktemp -d)"; mkdir -p "$root/DEBIAN" "$root/usr/bin"
  printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: t <t@e>\nDescription: test %s (%s)\n' \
    "$name" "$ver" "$arch" "$name" "$tag" > "$root/DEBIAN/control"
  printf '#!/bin/sh\necho %s %s\n' "$name" "$tag" > "$root/usr/bin/$name"; chmod +x "$root/usr/bin/$name"
  mkdir -p "$outdir"; local out="$outdir/${name}_${ver}_${arch}_${tag}.deb"
  dpkg-deb --build --root-owner-group "$root" "$out" >/dev/null; rm -rf "$root"; printf '%s\n' "$out"
}

# make_test_key <gnupghome> <email> — fast throwaway signing key
make_test_key(){
  install -d -m 700 "$1"
  GNUPGHOME="$1" gpg --batch --quick-generate-key "test <$2>" default sign never >/dev/null 2>&1 && return 0
  GNUPGHOME="$1" gpg --batch --gen-key >/dev/null 2>&1 <<EOF
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Name-Real: test
Name-Email: $2
Expire-Date: 0
%commit
EOF
}
```

- [ ] **Step 2: Write the failing hydrate test (manual-deb path, hermetic — no network)**

```bash
# tests/hydrate_test.sh
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

DISTS_CONF="$conf" ROOT_OVERRIDE="$tmp" "$ROOT/scripts/hydrate.sh" "$site" "$debs" || { echo "FAIL hydrate ran"; exit 1; }

fail=0
[ -f "$site/pool/bookworm/main/w/widget/"*.deb ] 2>/dev/null || { echo "❌ widget missing from bookworm"; fail=1; }
[ -f "$site/pool/trixie/main/w/widget/"*.deb ]   2>/dev/null || { echo "❌ widget missing from trixie (any should expand)"; fail=1; }
[ -f "$site/pool/bookworm/main/g/gadget/"*.deb ] 2>/dev/null || { echo "❌ gadget missing from bookworm"; fail=1; }
ls "$site/pool/trixie/main/g/gadget/" >/dev/null 2>&1 && { echo "❌ gadget must NOT be in trixie"; fail=1; }
[ "$fail" = 0 ] && echo "PASS hydrate_test" || { echo "FAIL hydrate_test"; exit 1; }
```

Note the test passes the config path and a debs dir into hydrate. Task step 3 adds those two hooks (`DISTS_CONF`, second positional debs arg) to keep the test hermetic; production callers use the defaults.

- [ ] **Step 3: Run test to verify it fails**

Run: `bash tests/hydrate_test.sh`
Expected: FAIL — hydrate still builds a single `pool/main`, so the per-codename paths don't exist.

- [ ] **Step 4: Rewrite `scripts/hydrate.sh`**

Replace the header/setup and both source loops. New content:

```bash
#!/usr/bin/env bash
# Assemble <site>/pool/<codename>/main from two sources:
#   1. packages/*.json  — download each referenced .deb, verify sha256, cross-check
#      control fields, and place it into the pool of every release it targets.
#   2. debs/<release>/*.deb (and bare debs/*.deb = "any") — committed binaries.
# Releases come from conf/dists.conf; "any" expands to every configured codename.
# Fails hard on any mismatch so a partial/incorrect set is never published.
set -euo pipefail

SITE="${1:-_site}"
ROOT="${ROOT_OVERRIDE:-$(cd "$(dirname "$0")/.." && pwd)}"
LOCAL_DIR="${2:-$ROOT/debs}"
PKG_DIR="$ROOT/packages"
. "$(dirname "$0")/dists-lib.sh"; dists_load "${DISTS_CONF:-$ROOT/conf/dists.conf}"

rm -rf "$SITE/pool"; for cn in $DISTS; do mkdir -p "$SITE/pool/$cn/main"; done
placed=""

place() { # <deb> <pkg> <dest-basename> <codename>
  local dest="$SITE/pool/$4/main/${2:0:1}/$2"; mkdir -p "$dest"; cp "$1" "$dest/$3"
}
guard() { # <pkg> <codename> <arch>  — fail on a repeated (pkg,codename,arch)
  case " $placed " in *" $1|$2|$3 "*) echo "❌ duplicate artifact: $1 for $2/$3" >&2; exit 1;; esac
  placed="$placed $1|$2|$3"
}

shopt -s nullglob
json_files=("$PKG_DIR"/*.json)
if [ ${#json_files[@]} -eq 0 ]; then echo "⚠️  no package files in packages/"; else
  for f in "${json_files[@]}"; do
    name=$(jq -r '.name' "$f"); version=$(jq -r '.version' "$f"); count=$(jq '.artifacts | length' "$f")
    echo ">> $name $version ($(basename "$f"))"
    for i in $(seq 0 $((count - 1))); do
      arch=$(jq -r ".artifacts[$i].arch" "$f"); release=$(jq -r ".artifacts[$i].release" "$f")
      url=$(jq -r ".artifacts[$i].url" "$f");   want=$(jq -r ".artifacts[$i].sha256" "$f")
      arch_valid "$arch" || { echo "❌ $f: arch '$arch' not in ARCHES" >&2; exit 1; }
      targets=$(release_targets "$release") || exit 1
      tmp=$(mktemp --suffix .deb); curl -fsSL "$url" -o "$tmp"
      got=$(sha256sum "$tmp" | cut -d' ' -f1)
      [ "$got" = "$want" ] || { echo "❌ $name/$arch: sha256 mismatch (want $want, got $got)" >&2; rm -f "$tmp"; exit 1; }
      p=$(dpkg-deb -f "$tmp" Package); v=$(dpkg-deb -f "$tmp" Version); a=$(dpkg-deb -f "$tmp" Architecture)
      [ "$p" = "$name" ]    || { echo "❌ $f: name '$name' != deb Package '$p'" >&2; rm -f "$tmp"; exit 1; }
      [ "$v" = "$version" ] || { echo "❌ $f: version '$version' != deb Version '$v'" >&2; rm -f "$tmp"; exit 1; }
      [ "$a" = "$arch" ]    || { echo "❌ $f: arch '$arch' != deb Architecture '$a'" >&2; rm -f "$tmp"; exit 1; }
      for cn in $targets; do guard "$name" "$cn" "$arch"; place "$tmp" "$name" "$(basename "$url")" "$cn"; done
      rm -f "$tmp"; echo "   ✅ $release/$arch  $(basename "$url")"
    done
  done
fi

handle_manual() { # <deb> <release>
  dpkg-deb --info "$1" >/dev/null 2>&1 || { echo "❌ invalid .deb: $1" >&2; exit 1; }
  local name arch cn; name=$(dpkg-deb -f "$1" Package); arch=$(dpkg-deb -f "$1" Architecture)
  arch_valid "$arch" || { echo "❌ $1: arch '$arch' not in ARCHES" >&2; exit 1; }
  for cn in $(release_targets "$2"); do guard "$name" "$cn" "$arch"; place "$1" "$name" "$(basename "$1")" "$cn"; done
  echo "   ✅ $2/$arch  $(basename "$1")"
}

if [ -d "$LOCAL_DIR" ]; then
  echo ">> including manually-added debs from $LOCAL_DIR"
  for d in "$LOCAL_DIR"/*.deb;   do [ -e "$d" ] && handle_manual "$d" any; done
  for sub in "$LOCAL_DIR"/*/;    do [ -d "$sub" ] || continue; rel=$(basename "$sub")
    for d in "$sub"*.deb; do [ -e "$d" ] && handle_manual "$d" "$rel"; done; done
fi

echo "✅ hydrated $SITE/pool"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/hydrate_test.sh` then `bash tests/dists_test.sh`
Expected: `PASS hydrate_test` and `PASS dists_test`.

- [ ] **Step 6: Commit**

```bash
git add scripts/hydrate.sh tests/helpers.sh tests/hydrate_test.sh
git commit -m "feat: per-release pool assembly with any-expansion and collision guard"
```

---

### Task 4: gen-index — per-suite indexes + alias trees + signing; slim conf; Makefile build/verify

**Files:**
- Modify: `conf/apt-ftparchive.conf:6-14` (remove Suite/Codename/Architectures)
- Modify: `scripts/gen-index.sh` (source lib; loop suites + aliases; `-o` overrides; `sign_dist`)
- Modify: `Makefile:23` (ARCHES from config), `:58-61` (`build`), `:80-87` (`verify`)
- Create: `tests/gen_index_test.sh`

**Interfaces:**
- Consumes: pool from Task 3; `dists_load`, `alias_pairs` (Task 1).
- Produces: `<site>/dists/<suite>/{Release,InRelease,Release.gpg, main/binary-<arch>/Packages[.gz]}` for every codename and alias; consumed by Task 5 (render).

- [ ] **Step 1: Write the failing gen-index test (local pool + throwaway key, hermetic)**

```bash
# tests/gen_index_test.sh
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/tests/helpers.sh"
need dpkg-deb apt-ftparchive gpg
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
conf="$tmp/dists.conf"; printf 'DISTS="bookworm trixie"\nALIASES="stable:bookworm"\nARCHES="amd64 arm64"\n' > "$conf"
site="$tmp/_site"; debs="$tmp/debs"
make_deb "$debs" widget 1.0 amd64 any >/dev/null
export GNUPGHOME="$tmp/gnupg"; make_test_key "$GNUPGHOME" contact@andresbott.com

DISTS_CONF="$conf" ROOT_OVERRIDE="$tmp" "$ROOT/scripts/hydrate.sh" "$site" "$debs"
DISTS_CONF="$conf" ROOT_OVERRIDE="$tmp" "$ROOT/scripts/gen-index.sh" "$site" "$ROOT/conf/apt-ftparchive.conf" contact@andresbott.com

fail=0
for s in bookworm trixie stable; do
  [ -f "$site/dists/$s/InRelease" ] || { echo "❌ $s/InRelease missing"; fail=1; continue; }
  GNUPGHOME="$GNUPGHOME" gpg --verify "$site/dists/$s/InRelease" >/dev/null 2>&1 || { echo "❌ $s signature bad"; fail=1; }
done
grep -q '^Suite: stable$'    "$site/dists/stable/Release" || { echo "❌ alias Suite wrong"; fail=1; }
grep -q '^Codename: bookworm$' "$site/dists/stable/Release" || { echo "❌ alias Codename wrong"; fail=1; }
[ "$fail" = 0 ] && echo "PASS gen_index_test" || { echo "FAIL gen_index_test"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/gen_index_test.sh`
Expected: FAIL — gen-index still writes only `dists/stable` with hardcoded Suite/Codename.

- [ ] **Step 3: Slim `conf/apt-ftparchive.conf`**

Replace lines 6-14 with static branding only:

```
APT::FTPArchive::Release {
    Origin       "autobott";
    Label        "autobott";
    Components   "main";
    Description  "autobott Debian repository";
};
```

Update the header comment (lines 1-4) to note Suite/Codename/Architectures are injected per suite by `scripts/gen-index.sh`.

- [ ] **Step 4: Rewrite the index/sign section of `scripts/gen-index.sh`**

Keep the arg parsing for `SITE CONF KEY_EMAIL`, drop the `ARCHES=("$@")` positional (arches now come from config). Source the lib after computing `ROOT`, then replace the build block (`gen-index.sh:22-40`):

```bash
ROOT="${ROOT_OVERRIDE:-$(cd "$(dirname "$0")/.." && pwd)}"
CONF_ABS="$ROOT/$CONF"; [ -f "$CONF_ABS" ] || CONF_ABS="$CONF"
. "$(dirname "$0")/dists-lib.sh"; dists_load "${DISTS_CONF:-$ROOT/conf/dists.conf}"

sign_dist() { # <dist-dir>
  gpg --batch --yes --local-user "$KEY_EMAIL" --clearsign -o "$1/InRelease" "$1/Release"
  gpg --batch --yes --local-user "$KEY_EMAIL" -abs        -o "$1/Release.gpg" "$1/Release"
}

mkdir -p "$SITE"; rm -rf "$SITE/dists"
(
  cd "$SITE"
  for cn in $DISTS; do
    mkdir -p "pool/$cn/main"
    for arch in $ARCHES; do
      mkdir -p "dists/$cn/main/binary-$arch"
      echo ">> indexing $cn/$arch"
      apt-ftparchive --arch "$arch" packages "pool/$cn/main" > "dists/$cn/main/binary-$arch/Packages"
      gzip -9 -kf "dists/$cn/main/binary-$arch/Packages"
    done
    echo ">> Release + sign: $cn"
    apt-ftparchive -c "$CONF_ABS" \
      -o APT::FTPArchive::Release::Suite="$cn" \
      -o APT::FTPArchive::Release::Codename="$cn" \
      -o APT::FTPArchive::Release::Architectures="$ARCHES" \
      release "dists/$cn" > "dists/$cn/Release"
    sign_dist "dists/$cn"
  done
  while read -r al target; do
    [ -n "$al" ] || continue
    echo ">> alias $al -> $target"
    rm -rf "dists/$al"; mkdir -p "dists/$al/main"
    cp -r "dists/$target/main/binary-"* "dists/$al/main/"
    apt-ftparchive -c "$CONF_ABS" \
      -o APT::FTPArchive::Release::Suite="$al" \
      -o APT::FTPArchive::Release::Codename="$target" \
      -o APT::FTPArchive::Release::Architectures="$ARCHES" \
      release "dists/$al" > "dists/$al/Release"
    sign_dist "dists/$al"
  done < <(alias_pairs)
)
```

Leave the static-file copy (keyring/sources/.nojekyll) as-is. Change the render call at `gen-index.sh:48` to drop the arch args: `"$ROOT/scripts/render-index.sh" "$SITE"` (render sources the lib itself in Task 5). Until Task 5 lands, render still runs; it just reads no suites yet — harmless for this task's test, which checks `dists/` directly.

- [ ] **Step 5: Update the Makefile**

- Line 23: `ARCHES := $(shell . ./conf/dists.conf 2>/dev/null && echo $$ARCHES)`
- `build` target (58-61): drop `$(ARCHES)` from the `gen-index.sh` call.
- `verify` target (80-87): source config and loop every suite/alias:

```make
.PHONY: verify
verify: require-key ## sanity-check a built site: every suite's signature valid + pooled debs parse
	@. ./conf/dists.conf; ok=1; \
	 for s in $$DISTS $$(for a in $$ALIASES; do echo $${a%%:*}; done); do \
	   if gpg --verify "$(SITE)/dists/$$s/InRelease" >/dev/null 2>&1; then echo "✅ $$s signature OK"; \
	   else echo "❌ $$s signature failed (run 'make publish'?)"; ok=0; fi; done; \
	 debs=$$(find "$(SITE)/pool" -name '*.deb' 2>/dev/null); \
	 [ -n "$$debs" ] || echo "⚠️  no .deb files in the pool"; \
	 for d in $$debs; do dpkg-deb --info "$$d" >/dev/null 2>&1 || { echo "❌ $$d"; ok=0; }; done; \
	 [ $$ok -eq 1 ]
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash tests/gen_index_test.sh`
Expected: `PASS gen_index_test`.

- [ ] **Step 7: Commit**

```bash
git add conf/apt-ftparchive.conf scripts/gen-index.sh Makefile tests/gen_index_test.sh
git commit -m "feat: generate + sign per-release suites and rolling-alias trees"
```

---

### Task 5: render-index — aggregate across suites, add release tags

**Files:**
- Modify: `scripts/render-index.sh:27-79` (read all codename indexes; add a `release` column; render release tags)
- Modify: `index.html` (add a styled `.rel` tag group in the package summary; update any suite-specific copy)
- Modify: `conf/site.conf` (tagline copy if it names a single suite)
- Create: `tests/render_test.sh`

**Interfaces:**
- Consumes: `dists_load`, `DISTS` (Task 1); `dists/<codename>/main/**/Packages` (Task 4).
- Produces: `<site>/index.html` with per-package release + arch tags.

- [ ] **Step 1: Write the failing render test**

```bash
# tests/render_test.sh
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/tests/helpers.sh"
need dpkg-deb apt-ftparchive gpg
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
conf="$tmp/dists.conf"; printf 'DISTS="bookworm trixie"\nALIASES=""\nARCHES="amd64"\n' > "$conf"
site="$tmp/_site"; debs="$tmp/debs"
make_deb "$debs" widget 1.0 amd64 any >/dev/null       # any -> both suites
make_deb "$debs/bookworm" gadget 2.0 amd64 bk >/dev/null
export GNUPGHOME="$tmp/gnupg"; make_test_key "$GNUPGHOME" contact@andresbott.com
DISTS_CONF="$conf" ROOT_OVERRIDE="$tmp" "$ROOT/scripts/hydrate.sh" "$site" "$debs"
DISTS_CONF="$conf" ROOT_OVERRIDE="$tmp" "$ROOT/scripts/gen-index.sh" "$site" "$ROOT/conf/apt-ftparchive.conf" contact@andresbott.com
DISTS_CONF="$conf" ROOT_OVERRIDE="$tmp" "$ROOT/scripts/render-index.sh" "$site"

fail=0
grep -q 'widget' "$site/index.html" || { echo "❌ widget not listed"; fail=1; }
grep -q 'gadget' "$site/index.html" || { echo "❌ gadget not listed"; fail=1; }
grep -q 'bookworm' "$site/index.html" || { echo "❌ release tag 'bookworm' missing"; fail=1; }
grep -q 'trixie'   "$site/index.html" || { echo "❌ release tag 'trixie' missing"; fail=1; }
# gadget is bookworm-only: it must not advertise trixie in its own row (spot check)
[ "$fail" = 0 ] && echo "PASS render_test" || { echo "FAIL render_test"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/render_test.sh`
Expected: FAIL — render reads only `dists/stable/main`, which no longer exists here; no release tags emitted.

- [ ] **Step 3: Rewrite the row-collection in `scripts/render-index.sh`**

After `ROOT=...`, add: `. "$(dirname "$0")/dists-lib.sh"; dists_load "${DISTS_CONF:-$ROOT/conf/dists.conf}"`. Replace the `mapfile ... dists/stable/main` discovery + first `awk` (lines 27-79) so each Packages line is tagged with its codename and rows carry a release set:

```bash
rows=""
tsv="$(
  for cn in $DISTS; do
    while IFS= read -r pf; do
      awk -v rel="$cn" '
        function emit(){ if(fn!="") print rel"\t"pkg"\t"ver"\t"arch"\t"size"\t"fn"\t"desc"\t"home;
                         pkg=ver=arch=size=fn=desc=home="" }
        /^Package:/{v=$0;sub(/^Package:[ \t]*/,"",v);pkg=v}
        /^Version:/{v=$0;sub(/^Version:[ \t]*/,"",v);ver=v}
        /^Architecture:/{v=$0;sub(/^Architecture:[ \t]*/,"",v);arch=v}
        /^Size:/{v=$0;sub(/^Size:[ \t]*/,"",v);size=v}
        /^Filename:/{v=$0;sub(/^Filename:[ \t]*/,"",v);fn=v}
        /^Description:/{v=$0;sub(/^Description:[ \t]*/,"",v);desc=v}
        /^Homepage:/{v=$0;sub(/^Homepage:[ \t]*/,"",v);home=v}
        /^[[:space:]]*$/{emit()} END{emit()}
      ' "$pf"
    done < <(find "$SITE/dists/$cn/main" -name Packages 2>/dev/null)
  done | sort -u
)"
if [ -n "$tsv" ]; then
  rows="$(printf '%s\n' "$tsv" | awk -F'\t' '
    function esc(s){ gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); gsub(/>/,"\\&gt;",s); return s }
    function hsize(b){ if(b+0>=1048576)return sprintf("%.1f MB",b/1048576);
                       else if(b+0>=1024)return sprintf("%.0f KB",b/1024); else return b" B" }
    {
      rel=$1; key=$2 SUBSEP $3
      if(!(key in seen)){ seen[key]=1; ord[++n]=key; kpkg[key]=$2; kver[key]=$3; kdesc[key]=$7; khome[key]=$8 }
      rk=key SUBSEP rel; if(!(rk in rseen)){ rseen[rk]=1; rels[key]=rels[key](rels[key]==""?"":" ")rel }
      ak=key SUBSEP $4; if(!(ak in aseen)){ aseen[ak]=1; arch[key]=arch[key](arch[key]==""?"":" ")$4 }
      asz[ak]=$5; afn[ak]=$6
    }
    END{
      for(i=1;i<=n;i++){ key=ord[i];
        m=split(arch[key],av," "); for(a=1;a<m;a++)for(b=a+1;b<=m;b++)if(av[b]<av[a]){t=av[a];av[a]=av[b];av[b]=t}
        r=split(rels[key],rv," "); for(a=1;a<r;a++)for(b=a+1;b<=r;b++)if(rv[b]<rv[a]){t=rv[a];rv[a]=rv[b];rv[b]=t}
        reltags=""; for(a=1;a<=r;a++) reltags=reltags "<span class=\"rel\">" esc(rv[a]) "</span>"
        tags=""; items=""
        for(a=1;a<=m;a++){ ak=key SUBSEP av[a]
          tags=tags "<span class=\"arch\">" esc(av[a]) "</span>"
          items=items "<a href=\"" esc(afn[ak]) "\" download><span class=\"a\">" esc(av[a]) "</span><span class=\"s\">" hsize(asz[ak]) "</span></a>" }
        home=""; if(khome[key]!=""){ lbl=khome[key]; sub(/^https?:\/\//,"",lbl); sub(/\/+$/,"",lbl);
          home="<a class=\"home\" href=\"" esc(khome[key]) "\">" esc(lbl) "</a>" }
        printf "            <details class=\"pkg\" name=\"packages\"><summary><span class=\"name\"><code>%s</code></span><span class=\"ver\">%s</span><span class=\"rels\">%s</span><span class=\"arches\">%s</span></summary><div class=\"pkg-body\"><p class=\"desc\">%s</p>%s<div class=\"downloads\">%s</div></div></details>\n", esc(kpkg[key]), esc(kver[key]), reltags, tags, esc(kdesc[key]), home, items
      }
    }')"
fi
```

Keep the `DEMO_WHEN_EMPTY` branch and everything below, but add a demo `.rel` tag to the two demo rows so the preview reflects the new layout.

- [ ] **Step 4: Add `.rel` styling to `index.html`**

Add a rule alongside the existing `.arch` style (reuse its look), e.g.:

```css
.rels{display:inline-flex;gap:.25rem;margin-right:.5rem}
.rel{font-size:.7rem;padding:.05rem .4rem;border-radius:.4rem;background:var(--accent-soft);color:var(--accent)}
```

Match the actual variable names already used by `.arch` in `index.html`.

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/render_test.sh`
Expected: `PASS render_test`.

- [ ] **Step 6: Commit**

```bash
git add scripts/render-index.sh index.html conf/site.conf tests/render_test.sh
git commit -m "feat: show per-release availability tags on the landing page"
```

---

### Task 6: register — `dist/<release>/` subdirs → release-tagged artifacts

**Files:**
- Modify: `scripts/register.sh:30-49` (walk `dist/<release>/` + bare `dist/*.deb`=any; emit `release`)
- Modify: `.github/actions/register/action.yml:1-13` (description + `dist-dir` doc)
- Create: `tests/register_test.sh`

**Interfaces:**
- Consumes: schema shape `{release, arch, url, sha256}` (Task 2); the built `.deb` layout convention.
- Produces: `packages/<name>.json` validated against the schema.

- [ ] **Step 1: Write the failing register test**

```bash
# tests/register_test.sh
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/register_test.sh`
Expected: FAIL — register scans only flat `dist/*.deb` and emits no `release`, so it finds 1 artifact with no release field.

- [ ] **Step 3: Rewrite the deb-collection + artifact build in `scripts/register.sh`**

Replace lines 30-49 (from `shopt -s nullglob` through the `jq -n ... > "$OUT"`) with:

```bash
shopt -s nullglob
rels=(); debs=()
for d in "$DIST_DIR"/*.deb;  do rels+=("any"); debs+=("$d"); done          # bare = any
for sub in "$DIST_DIR"/*/;   do [ -d "$sub" ] || continue; r=$(basename "$sub")
  for d in "$sub"*.deb; do rels+=("$r"); debs+=("$d"); done; done
[ ${#debs[@]} -gt 0 ] || { echo "❌ no .deb files in '$DIST_DIR' (flat or dist/<release>/)" >&2; exit 1; }

# every .deb must belong to this package
for d in "${debs[@]}"; do
  p=$(dpkg-deb -f "$d" Package)
  [ "$p" = "$NAME" ] || { echo "❌ $(basename "$d"): Package '$p' != --name '$NAME'" >&2; exit 1; }
done

artifacts=$(for idx in "${!debs[@]}"; do
  d="${debs[$idx]}"; r="${rels[$idx]}"
  jq -n --arg release "$r" --arg arch "$(dpkg-deb -f "$d" Architecture)" \
        --arg url "$base/$(basename "$d")" --arg sha "$(sha256sum "$d" | cut -d' ' -f1)" \
        '{release:$release, arch:$arch, url:$url, sha256:$sha}'
done | jq -s 'sort_by(.release, .arch)')

mkdir -p "$(dirname "$OUT")"
jq -n --arg name "$NAME" --arg version "$ver" --argjson artifacts "$artifacts" \
  '{name:$name, version:$version, artifacts:$artifacts}' > "$OUT"
echo "✅ wrote $OUT ($NAME $ver, $(echo "$artifacts" | jq length) artifact(s))"
```

(The schema-validation tail at `register.sh:52-66` stays unchanged.)

- [ ] **Step 4: Update the composite action docs**

In `.github/actions/register/action.yml`, extend `description` and the `dist-dir` input `description` to state: place per-release builds in `dist/<codename>/` (release-distinct filenames, since GitHub Release assets share one namespace); a flat `dist/*.deb` is registered as `release: any`.

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/register_test.sh`
Expected: `PASS register_test`.

- [ ] **Step 6: Commit**

```bash
git add scripts/register.sh .github/actions/register/action.yml tests/register_test.sh
git commit -m "feat: register per-release artifacts from dist/<release>/ layout"
```

---

### Task 7: Client install default + documentation + end-to-end gate

**Files:**
- Modify: `README.md` (suite line; match-host install; stable alternative)
- Modify: `DEVELOPMENT.md` (suite line; How it works; register example; schema example; Layout; new "Releases & suites" section)
- Modify: `Makefile:1-9` (header comment), `:74-78` (`register` help), `:50-52` (`test` runs all `tests/*_test.sh`)
- Verify: `autobott.sources` unchanged (`Suites: stable` — now a real signed alias)

**Interfaces:**
- Consumes: everything above.
- Produces: user-facing docs + a green end-to-end build.

- [ ] **Step 1: Make `make test` run the whole suite**

Replace the `test` target (`Makefile:50-52`):

```make
.PHONY: test
test: ## run all shell tests (schema fixtures + build integration)
	@fail=0; for t in tests/*_test.sh; do echo ">> $$t"; bash "$$t" || fail=1; done; [ $$fail -eq 0 ] && echo "✅ all tests passed"
```

- [ ] **Step 2: Rewrite the README install (lead with match-host)**

Replace the install block (`README.md:11-22`) so the recommended path writes the host codename, with the `stable` curl as the simple alternative:

````markdown
## Install

Trust the signing key, then add the source for **your** Debian release:

```bash
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL https://ansible-autobott.github.io/debian-repo/autobott-archive-keyring.gpg \
  -o /etc/apt/keyrings/autobott-archive-keyring.gpg
. /etc/os-release
sudo tee /etc/apt/sources.list.d/autobott.sources >/dev/null <<EOF
Types: deb
URIs: https://ansible-autobott.github.io/debian-repo
Suites: ${VERSION_CODENAME}
Components: main
Architectures: amd64 arm64
Signed-By: /etc/apt/keyrings/autobott-archive-keyring.gpg
EOF
sudo apt update
```

To simply track Debian **stable** instead, download the ready-made source
(its `Suites: stable` follows whatever the current stable release is):

```bash
sudo curl -fsSL https://ansible-autobott.github.io/debian-repo/autobott.sources \
  -o /etc/apt/sources.list.d/autobott.sources
```
````

Update the "Suite / component" line (`README.md:9`) to: `**Suites:** per Debian release — `bookworm`, `trixie`, `sid` (+ aliases `stable`/`testing`/`unstable`) · **Component:** `main` · **Architectures:** `amd64`, `arm64``.

- [ ] **Step 3: Update DEVELOPMENT.md**

Apply, verbatim where quoted:
- Line 7 suite line → same wording as README step 2.
- "How it works" (11-26): add that the pool and indexes are per-codename and that `conf/dists.conf` lists releases + aliases.
- Register example (87-93): show the `dist/<release>/` convention (a matrix build writing `dist/bookworm/…`, `dist/trixie/…`).
- Schema example (133-150): add `release` to each artifact and note `release` is required; `any` = every suite.
- Layout tree (213-222): `pool/<codename>/main/…`; add `conf/dists.conf`; `dists/<suite>/` incl. aliases; `scripts/dists-lib.sh`.
- Add a "Releases & suites" subsection explaining `DISTS`/`ALIASES`, how `any` expands, and how to move `stable` forward (one-line edit).

- [ ] **Step 4: Update Makefile comments**

- Header (1-9): mention the per-release pool and `conf/dists.conf`.
- `register` help (75): note `dist-dir` may contain `dist/<release>/` subdirs.

- [ ] **Step 5: Full end-to-end gate (hermetic)**

Run:

```bash
bash tests/dists_test.sh && bash tests/schema_test.sh && bash tests/hydrate_test.sh \
  && bash tests/gen_index_test.sh && bash tests/render_test.sh && bash tests/register_test.sh
make test
```

Expected: every script prints `PASS …` (or `⚠️ skipping` where a tool is absent) and `make test` ends `✅ all tests passed`.

Then a real local publish smoke test using a committed manual deb:

```bash
tmpdeb=$(mktemp -d); make add DEB=$(bash -c '. tests/helpers.sh; make_deb "'"$tmpdeb"'" demo 0.1 amd64 any')  # stages into debs/
# (or drop one into debs/bookworm/ to test a per-release manual deb)
make key || true          # only if no signing key exists locally
make publish && make verify
```

Expected: `make verify` reports `✅ <suite> signature OK` for every codename and alias. Remove the demo deb afterwards (`git checkout -- debs/ 2>/dev/null; rm -rf debs/*/`).

- [ ] **Step 6: Commit**

```bash
git add README.md DEVELOPMENT.md Makefile
git commit -m "docs: per-release install + suites/aliases developer docs"
```

---

## Self-Review

**Spec coverage:**
- §1 config → Task 1. §2 schema → Task 2. §3 pool/hydrate → Task 3. §4 gen-index + conf + verify → Task 4. §5 render → Task 5. §6 client install → Task 7 (match-host default). §7 docs → Task 7. Upstream contract (register) → Task 6. Testing → each task + Task 7 gate. All spec sections map to a task.

**Placeholder scan:** No TBD/TODO; every code and test step carries real content. The only intentional partial is CSS variable names in Task 5 Step 4 ("match the actual variable names in `index.html`") — the executor must read `index.html`'s existing `.arch` rule; this is a lookup, not a placeholder.

**Type/name consistency:** `dists_load`, `dists_has`, `arch_valid`, `release_targets`, `alias_pairs`, `place` (4-arg), `guard`, `handle_manual`, `sign_dist`, and the `DISTS_CONF`/`ROOT_OVERRIDE`/second-positional-debs test hooks are used consistently across Tasks 1, 3, 4, 5. Artifact keys `{release, arch, url, sha256}` match across schema (2), hydrate (3), register (6). Alias Release fields `Suite=<alias>`/`Codename=<target>` consistent between Task 4 code and its test.

**Note for executor:** hydrate/gen-index/render take two test-only hooks (`DISTS_CONF` env, `ROOT_OVERRIDE` env, and hydrate's optional 2nd positional debs dir) so the integration tests stay hermetic; production Makefile calls use the defaults and pass none of them.
