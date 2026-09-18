# Multi-release APT suites — design

- **Date:** 2026-09-17
- **Status:** Draft for review (no code written yet)
- **Repo:** `ansible-autobott/debian-repo`

## Problem

The repository publishes a single suite, `stable`, and serves the same `.deb` to
every consumer. It cannot offer different builds per Debian release. We want
genuinely per-release artifacts, so that `apt` on each host installs the build
that matches its release.

Note: the suite label is independent of a host's Debian version — the current
`stable` repo already installs on testing/sid today. This work is about serving
*different content* per release, not merely making the repo usable there.

## Decisions (already agreed)

1. **Functional per-release** — different `.deb` per release, not relabeling one
   build.
2. **Codename suites + rolling aliases** — real suites `bookworm`, `trixie`,
   `sid`; aliases `stable→bookworm`, `testing→trixie`, `unstable→sid`.
3. **Configurable, not hardcoded** — the release set and alias map live in
   config; no release name is baked into a script or the schema.

## Overview

A single config file drives the whole build. Each real release gets its own pool
subtree and its own signed `dists/<codename>/` index. Each alias gets its own
signed `dists/<alias>/` index that mirrors its target. Every package download is
tagged with the release it targets, or `any`. Existing single-build apps migrate
for free by tagging their artifacts `any`.

Published tree (default config):

```
_site/
  pool/
    bookworm/main/…       trixie/main/…       sid/main/…
  dists/
    bookworm/  trixie/  sid/          # real suites: Suite=Codename=<codename>
    stable/    testing/  unstable/    # aliases: Suite=<alias>, Codename=<target>
```

---

## 1. Configuration — new `conf/dists.conf`

Single source of truth, shell-sourceable like `conf/site.conf`. Sourced by the
Makefile and by `scripts/{hydrate,gen-index,render-index}.sh`.

```sh
# Real codename suites — each gets a pool subtree and a signed dists/<codename>/.
DISTS="bookworm trixie sid"

# Rolling-suite aliases, "<alias>:<target>" — each is a signed dists/<alias>/
# mirroring the target's Packages, Release labelled Suite=<alias> Codename=<target>.
ALIASES="stable:bookworm testing:trixie unstable:sid"

# Architectures indexed in every suite (moved here from the Makefile).
ARCHES="amd64 arm64"
```

**Semantics:** moving `stable` to the next release is a one-line edit here.
**Validation** (in `gen-index`, fail hard): `DISTS` non-empty; every `ALIASES`
target ∈ `DISTS`; no alias name also in `DISTS`; suite names match
`^[a-z0-9][a-z0-9.-]*$`.

The Makefile drops its own `ARCHES :=` line and sources this file, so the whole
publish matrix lives in one place.

---

## 2. Package format — `schema/package.schema.json`

Each artifact gains a **`release`** field: `{release, arch, url, sha256}`.

```json
{
  "name": "go-deps-view",
  "version": "1.3.0",
  "homepage": "https://github.com/ansible-autobott/go-deps-view",
  "artifacts": [
    { "release": "bookworm", "arch": "amd64", "url": ".../…_amd64_bookworm.deb", "sha256": "…" },
    { "release": "bookworm", "arch": "arm64", "url": ".../…_arm64_bookworm.deb", "sha256": "…" },
    { "release": "trixie",   "arch": "amd64", "url": ".../…_amd64_trixie.deb",   "sha256": "…" },
    { "release": "trixie",   "arch": "arm64", "url": ".../…_arm64_trixie.deb",   "sha256": "…" }
  ]
}
```

A release-agnostic (static) package stays terse — one `any` entry per arch:

```json
"artifacts": [
  { "release": "any", "arch": "amd64", "url": ".../tool_0.9.0_amd64.deb", "sha256": "…" },
  { "release": "any", "arch": "arm64", "url": ".../tool_0.9.0_arm64.deb", "sha256": "…" }
]
```

**Rules:**
- `release` is **required** and validated by **pattern**, not an enum:
  `^(any|[a-z0-9][a-z0-9.-]*)$`. Actual codenames are never listed in the schema,
  so adding a release never touches this file.
- `arch` is likewise relaxed from its `["all","amd64","arm64"]` enum to a pattern
  (`^(all|[a-z0-9][a-z0-9-]*)$`). Membership checks (`release ∈ DISTS∪{any}`,
  `arch ∈ ARCHES∪{all}`) move to `hydrate`, where the config lives.
- Top-level `version` stays single — every release's `.deb` carries the same
  version (we partition by pool, not by version string).

---

## 3. Storage / pool — `scripts/hydrate.sh`

The pool stops being one shared `pool/main`. Only real codenames get a physical
subtree: `pool/<codename>/main/<letter>/<pkg>/<asset>.deb`. `place()` gains a
codename argument.

Per artifact: check `arch`/`release` against `dists.conf` (fail hard on unknown);
download **once** + verify (sha256 and the `.deb`'s `Package`/`Version`/
`Architecture` must match — unchanged); expand target codenames (`any` → every
`DISTS`, else the one codename); `cp` into each target pool. A **collision guard**
tracks `(codename, arch)` per package and fails on a repeat (e.g. `any` plus an
explicit `bookworm` for the same arch).

**Manual debs** become release-aware: `debs/<release>/*.deb` (codename or `any`);
a bare `debs/*.deb` is treated as `any` (backward compatible). `make add` gains an
optional release argument.

**Documented caveat:** mixing `arch:"all"` with a specific arch for the same
package+codename is discouraged; the guard only catches exact `(codename,arch)`
repeats.

---

## 4. Index build — `scripts/gen-index.sh` + `conf/apt-ftparchive.conf`

`conf/apt-ftparchive.conf` slims to static branding only (`Origin`, `Label`,
`Components`, `Description`). `Suite`, `Codename`, and `Architectures` are injected
per suite by `gen-index` (via `-o` overrides), so nothing release-specific is
hardcoded in the conf.

**Real suites:** for each codename, generate `Packages` per architecture from
`pool/<codename>/main`, then a `Release` labelled `Suite=Codename=<codename>`, then
sign (`InRelease` clearsigned + detached `Release.gpg`). An empty suite still gets
an empty, signed `Release` — subscribers never 404.

**Aliases:** for each `alias:target`, copy the target's `Packages` tree verbatim
(its `Filename:` paths already point into `pool/<target>/…`, so the alias needs no
pool of its own), generate a `Release` labelled `Suite=<alias>, Codename=<target>`,
and sign. These are ordinary files, not symlinks — GitHub Pages serves them
reliably.

Signing is factored into a small `sign_dist <dir>` helper reused across all suites
and aliases.

**`make verify`** stops hardcoding `dists/stable`: it sources `dists.conf` and
checks that `InRelease` verifies for every suite and alias, plus the existing
"pooled debs parse" sweep.

---

## 5. Landing page — `scripts/render-index.sh`

Today it reads only `dists/stable/main`. It will instead aggregate across every
real codename index, group by package+version, and show each package's available
**releases as tags** alongside the existing architecture tags (deduping identical
artifacts). No suite selector, no redesign — a release dimension added to the
current accordion list. `index.html`/`conf/site.conf` copy (tagline, install
snippet) updated to match.

---

## 6. Client install — `autobott.sources` + README  ⚑ OPEN DECISION

**Decision to confirm:** what a freshly-installed machine subscribes to by default.

- **(Recommended) Match the host.** The install step writes the machine's own
  codename into `autobott.sources` (`Suites: $(. /etc/os-release; echo "$VERSION_CODENAME")`),
  so each host installs the build that matches it. This is the point of per-release.
  Install changes from "curl the file" to a short generate-it snippet.
- **Track `stable`.** Everyone follows the `stable` alias (bookworm today).
  One-line curl install stays, but a testing/sid machine gets stable's builds.

Spec is written recommending **match the host**, with the `stable` option
documented as the simple alternative. README's "Suite / component" line and
install/remove steps updated accordingly.

---

## 7. Documentation

- `README.md` — suite line; per-release install story.
- `DEVELOPMENT.md` — suite line; "How it works"; register wiring example
  (`dist/<release>/` subdirs); schema example (add `release`); Layout tree
  (`pool/<codename>/…`, `conf/dists.conf`, `dists/<suite>/` + aliases); a new
  "Releases & suites" subsection.
- `.github/actions/register/action.yml` — `description` + `dist-dir` doc: the
  `dist/<release>/` convention and release-distinct filenames.
- `conf/apt-ftparchive.conf`, `Makefile` — header/help comment updates.
- Inline comments in each changed script.

---

## Upstream contract / migration

Apps that want per-release builds must (a) produce `.deb`s with **release-distinct
filenames** (GitHub Release assets share one flat namespace), and (b) arrange them
as `dist/<release>/<asset>.deb` so the register action can tag each with its
release. Apps that don't care keep a flat `dist/*.deb` → tagged `any` → one build
in every suite (today's behavior). **Migration is therefore non-breaking:** the
repo keeps working with `any` until an app opts into per-release.

## Testing

- Schema fixtures updated: valid (`any`, a per-release matrix), invalid (missing
  `release`, bad pattern); `tests/schema_test.sh` updated.
- Build smoke test: a fixture package set that exercises `any` + per-release
  produces the expected `dists/<suite>/` set, each with a verifying signature.
- `make verify` loops all suites/aliases.
- Manual local check: `make serve` + `apt` against a chosen suite installs.

## Non-goals

- No version-suffix scheme (`1.2.3~deb12`) — we partition by pool instead.
- No backports pockets or `by-hash` beyond what `DISTS`/`ALIASES` express.
- No automatic host-codename detection *inside* the repo build — that's a client
  install concern (§6).
