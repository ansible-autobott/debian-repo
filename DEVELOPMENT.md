# debian-repo — developer manual

How this APT repository works, how to set it up from scratch, and how to operate
it as a maintainer. For end-user install instructions see `README.md`.

- **URL:** https://ansible-autobott.github.io/debian-repo
- **Suites:** per Debian release — `trixie`, `forky`, `sid` (+ aliases `stable`/`testing`/`unstable`) · **Component:** `main` · **Architectures:** `amd64`, `arm64`

## How it works

The git tree **never stores binaries** — it stores *references*. The binaries are
downloaded, the index is built and GPG-signed **in CI**, and the result is
published to GitHub Pages. The repo publishes several Debian releases at once —
a pool and a signed index per codename, plus rolling-suite aliases — all driven
from one config file, `conf/dists.conf` (see [Releases & suites](#releases--suites)
below). A package enters the repo in one of two ways:

1. **Automated (per-app JSON).** Each app owns one file, `packages/<app>.json`,
   holding its current version and a checksummed URL per architecture *and*
   target release. The app's own release CI writes and commits that file (via
   the `register` action). Because every app owns a separate file, two releases
   never conflict.
2. **Manual (committed binary).** `make add DEB=foo.deb` stages a `.deb` into the
   git-tracked `debs/` folder; you commit it and it's hosted directly.

On every push to `main`, `.github/workflows/publish.yml` **rebuilds the whole repo**:
validate → download + verify every `packages/*.json` and merge `debs/` into each
targeted release's pool → sign every codename's and alias's index → deploy to
Pages. The full set is reconstructed each run, so nothing clobbers anything, and
a failed download aborts the publish (the previous deployment stays live) rather
than shipping a partial index.

## Releases & suites

Which Debian codenames this repo publishes, and the rolling-suite aliases on top
of them, are configured in one place: [`conf/dists.conf`](conf/dists.conf).
`hydrate.sh`, `gen-index.sh`, `render-index.sh`, and the Makefile all load it
through `scripts/dists-lib.sh` — no release name is hardcoded anywhere else.

```bash
DISTS="trixie forky sid"                             # codenames: each gets pool/<cn>/main/ + signed dists/<cn>/
ALIASES="stable:trixie testing:forky unstable:sid"   # <alias>:<target>: signed dists/<alias>/ mirroring target's Packages
ARCHES="amd64 arm64"
```

- **`DISTS`** — the codenames that get a real `pool/<codename>/main/` and a
  signed `dists/<codename>/`. An artifact's `release` field in a
  `packages/<name>.json` (or a `debs/<codename>/` subfolder) must name one of
  these, or the special value **`any`**, which expands to *every* codename in
  `DISTS` — the artifact is placed into each one's pool. The *order* of `DISTS` is
  the order the landing page lists a package's releases in, so keep it most-stable
  first (`trixie forky sid`) — alphabetical order would read `forky, sid, trixie`,
  which says nothing about which suite to track.
- **`ALIASES`** — rolling suites (`stable`, `testing`, `unstable`) that point at
  one `DISTS` codename each. Every alias publishes its own signed
  `dists/<alias>/Release` (`Suite=<alias>`, `Codename=<target>`), built by
  copying the target codename's `Packages` files — there's no separate pool for
  an alias.
- **Moving `stable` forward** is a one-line edit: when Debian promotes, say,
  `forky` to stable, change `ALIASES` in `conf/dists.conf` from
  `stable:trixie` to `stable:forky` — no script or workflow changes needed.
  That flip changes `dists/stable/Release`'s `Codename`, so clients tracking
  `stable` may need `sudo apt update --allow-releaseinfo-change` on their next
  update (normal Debian behavior when a suite's codename changes).

## Setup

First-time setup, from a fresh clone to a live repository. Steps 1–4 are one-time
for this repo; step 5 is repeated per tool you want to publish.

**Prerequisites:** `gpg`, `make`, `apt-utils` (provides `apt-ftparchive`), `jq`,
`curl`, and the `gh` CLI authenticated to GitHub (`gh auth status`).
`check-jsonschema` is optional locally (CI installs it).

**1 — Generate the repository signing key** (one-time):

```bash
make key
```

Creates an RSA-4096 signing key in the git-ignored `.gnupg-repo/`, exports the
public key to `autobott-archive-keyring.gpg` (+ `.asc`) — committed and served to
users — and writes a private-key backup, `autobott-signing-key.secret.asc`, for
you to move into your vault (see [Backup and recovery](#backup-and-recovery)).

**2 — Store the private key as a CI secret.** Signing runs in CI, so it needs the
private key as `APT_SIGNING_KEY` (piped straight in, never printed):

```bash
GNUPGHOME=.gnupg-repo gpg --export-secret-keys --armor contact@andresbott.com \
  | gh secret set APT_SIGNING_KEY --repo ansible-autobott/debian-repo
```

**3 — Enable GitHub Pages.** Repo Settings → Pages → **Source = GitHub Actions**.
No branch is needed; the workflow uploads the built site directly.

**4 — First publish.** Commit the public keyring from step 1 and push to `main`, or
trigger the workflow by hand:

```bash
gh workflow run publish.yml
gh run watch
```

On success the repo is live at the URL above. With no packages yet it publishes a
valid, empty, signed index — users can already add the repo.

**5 — Wire a tool repo to publish itself** (per app). In the tool's repository:

- Create a token that can push to `debian-repo`, and store it as the
  `DEBIAN_REPO_TOKEN` secret in the tool repo. Either:
  - **Fine-grained PAT** (tightest scope). Fine-grained tokens are opt-in per
    org, so first enable them or `ansible-autobott` won't appear as a resource owner:
    `ansible-autobott` org → **Settings → Personal access tokens → Settings →** *Allow
    access via fine-grained personal access tokens*. Then create the token with
    **Resource owner = ansible-autobott**, *Only select repositories* → `debian-repo`,
    **Repository permissions → Contents: Read and write** (approve it under the
    org's *Personal access tokens → Pending requests* if approval is required).
  - **Classic PAT** (works without the org setting, but broader — reaches every
    repo you can access). Create one with the `repo` scope; if the org enforces
    SAML SSO, click *Configure SSO → Authorize* for `ansible-autobott`.
- Add one step to the tool's release workflow, after its `.deb` files are built
  (e.g. by goreleaser into `dist/`). A single, release-agnostic build is
  unchanged — a flat `dist/*.deb` registers as release `any` (placed into every
  configured codename). A tool that builds *per Debian release* (e.g. a matrix
  job compiling separately for `trixie`/`forky`/`sid`) instead writes each
  build into `dist/<codename>/`, and `register` reads the directory name as the
  target release:

```yaml
      - uses: ansible-autobott/debian-repo/.github/actions/register@main
        with:
          name: go-deps-view          # must match the .deb's Package field
          dist-dir: dist              # dist/*.deb = "any"; dist/<codename>/*.deb targets one release
          token: ${{ secrets.DEBIAN_REPO_TOKEN }}
```

A matrix build writing `dist/trixie/go-deps-view_1.3.0_trixie_amd64.deb`,
`dist/forky/go-deps-view_1.3.0_forky_amd64.deb`, … registers one artifact per
codename+arch, each targeting only that release. Because GitHub Release assets
share one flat namespace, per-release filenames must stay distinct — include the
codename (as above) and keep the arch last. The repo canonicalizes each pooled
filename to `<name>_<version>_<arch>.deb`, so apt indexing is correct regardless
of the asset name; the assets themselves just need to be distinct within the
release's flat namespace.

On the tool's next release that step writes `packages/<name>.json` here and pushes
it, which triggers a publish.

#### A different version per release

One package file holds **one** version — `version` is a single field, and hydrate
checks it against every `.deb` it downloads. That is fine when all suites get the
same build, but not when a tool must ship *different upstream versions* to
different suites: klassy, for example, builds v6.5.3 for `trixie` because its
KF6 6.13 cannot build v6.7+, while `forky`/`sid` get v6.7.2.

Register each version group into its own file with `file`:

```yaml
      - uses: ansible-autobott/debian-repo/.github/actions/register@main
        with:
          name: klassy                      # same package name in every file
          dist-dir: dist                    # holds only this group's dist/<codename>/
          file: packages/klassy.trixie.json # one file per version group
          token: ${{ secrets.DEBIAN_REPO_TOKEN }}
```

Several files may name the same package; all of `packages/*.json` are merged at
publish time and the only uniqueness rule is that no two artifacts claim the same
**(package, release, arch)** — a collision names both files and fails the build.
A file per release group also keeps releases independent: publishing `sid` never
rewrites `trixie`'s entry, so one suite's broken build cannot block another's fix.

The landing page still lists such a package **once**, showing the newest version
plus a `+N more` hint; expanding it names each release's own version next to that
release's downloads.

Note the versions must still differ *as strings*, since a GitHub release's assets
share one flat namespace and the pool is keyed by version — a suite suffix
(`6.7.2-1~sid`) gives you both, which is why `register` takes the version from the
`.deb` control field rather than from the tag.

## Adding packages

### From a tool's release CI (the register action)

The [composite action](.github/actions/register/action.yml) runs this repo's own
[`scripts/register.sh`](scripts/register.sh): it builds `packages/<name>.json`
(per-release+arch URL + sha256 from the built debs), validates it against the
schema, and commits + pushes it (with rebase-retry). Keeping the logic here means
a schema change is made once, not in every app.

Inputs: `name` and `token` (required); `dist-dir` (default `dist`), `file` (default
`packages/<name>.json`, must stay under `packages/`), `tag` (default the release
ref), `source-repo` (default the calling repo), `repo` (default
`ansible-autobott/debian-repo`). Pin `@v1` instead of `@main` to insulate apps from
format changes.

`version` is read from each `.deb`'s own `Version` control field, never derived
from `tag`: a tag need not be a bare version (klassy-deb tags
`debian_sid-v6.7.2`), and a packaging revision or suite suffix (`6.7.2-1~sid`)
exists only in the `.deb`. Since hydrate cross-checks the downloaded `.deb`,
anything inferred from the tag would simply fail there. Every `.deb` under one
`dist-dir` must agree on the version; a mix is rejected with a pointer to `file`.

To generate a reference by hand (e.g. testing), `scripts/register.sh` is also wired
to `make register NAME=… REPO=owner/app TAG=vX.Y.Z [DIST=dist] [FILE=packages/….json]`.

### Manually (a committed binary)

For a one-off or a tool without a suitable release, add the `.deb` directly:

```bash
make add DEB=path/to/foo_1.0.0_amd64.deb   # copies it into debs/
git add debs/ && git commit -m "add foo 1.0.0" && git push
```

The binary is committed to git and merged into the pool alongside the JSON-hydrated
ones on the next publish.

`make add` places the file in `debs/`, i.e. release `any` (hosted in every
configured codename). To pin a manual binary to a single release, commit it under
`debs/<codename>/` instead (e.g. `debs/trixie/foo_1.0.0_amd64.deb`) — `hydrate`
reads the subfolder name as the target release; a bare `debs/*.deb` stays `any`.

## Package reference schema

`packages/*.json` must validate against
[`schema/package.schema.json`](schema/package.schema.json):

```json
{
  "name": "go-deps-view",
  "version": "1.3.0",
  "homepage": "https://github.com/ansible-autobott/go-deps-view",
  "description": "Browser viewer for a Go module's dependency graph",
  "artifacts": [
    { "release": "any", "arch": "amd64", "url": "https://github.com/ansible-autobott/go-deps-view/releases/download/v1.3.0/go-deps-view_1.3.0_amd64.deb", "sha256": "<64 hex>" },
    { "release": "any", "arch": "arm64", "url": "https://github.com/ansible-autobott/go-deps-view/releases/download/v1.3.0/go-deps-view_1.3.0_arm64.deb", "sha256": "<64 hex>" }
  ]
}
```

Required: `name`, `version`, and `artifacts[]` (each with `release`, `arch`, `url`,
`sha256`). `release` is the target Debian codename (one of `conf/dists.conf`'s
`DISTS`) or `any` — every configured codename, as used above since this build
isn't release-specific. `additionalProperties` is `false` and URLs must be HTTPS.
At publish time each download is checked against `sha256`, and the `.deb`'s own
`Package`/`Version`/`Architecture` must match `name`/`version`/`arch` — otherwise
the build fails and the previous deployment stays live.

The filename is not part of the format: `packages/<name>.json` is only the
default. Because `version` is a single field, an app whose suites carry different
versions splits them across several files that all set the same `name` (see
[A different version per release](#a-different-version-per-release)). Uniqueness is
enforced per **(package, release, arch)** across every file and `debs/`, not per
file, so the split is safe but overlapping releases are a hard error.

## Local development

`make help` lists every target. To reproduce the exact CI publish locally:

```bash
make publish     # validate -> hydrate (download+verify) -> build + sign  ->  _site/
make serve       # serve _site/ at http://localhost:8000 to test with apt
make verify      # check the built signature + that pooled debs parse
```

| Target | Description |
| --- | --- |
| `make publish` | full local rebuild: `validate` + `hydrate` + `build` |
| `make validate` | check every `packages/*.json` against the schema |
| `make hydrate` | download + verify referenced debs and merge `debs/` into `_site/pool` |
| `make build` | generate + sign the index in `_site/` |
| `make add DEB=…` | stage a local `.deb` into `debs/` for manual hosting |
| `make register NAME=… REPO=… TAG=…` | generate a `packages/<name>.json` locally |
| `make serve` / `make verify` / `make clean` | test locally / sanity-check / clean |
| `make key` / `make export-key` / `make backup-key` / `make key-info` | signing-key management |

## Signing

The private signing key lives only in the git-ignored `.gnupg-repo/` locally and in
the `APT_SIGNING_KEY` CI secret — never in the tree. Only the public
`autobott-archive-keyring.gpg` is committed and published. It has no passphrase
(for unattended signing); its sole capability is signing this public repo's index.
If it is lost or compromised, regenerate with `make key` and republish the public
key.

### Backup and recovery

The private key is the only irreplaceable secret in this repo, so keep an offline
copy. `make key` writes one for you: **`autobott-signing-key.secret.asc`**, an
armored export of the passphrase-less private key (git-ignored via `*.secret.asc`).
Move that file into your password vault and shred the local copy — anyone holding
it can sign as this repo. Re-export it any time with `make backup-key`:

```bash
make backup-key      # (re)writes autobott-signing-key.secret.asc
```

`.gnupg-repo/` itself holds the key in GnuPG's database format under
`private-keys-v1.d/` — there is no `.asc` inside it, which is why the export exists.
There is no passphrase to store (the key has none). To restore onto a
fresh machine, recreate the home dir, import the key, and refresh the CI secret:

```bash
mkdir -p .gnupg-repo && chmod 700 .gnupg-repo
GNUPGHOME=.gnupg-repo gpg --import autobott-signing-key.secret.asc
GNUPGHOME=.gnupg-repo gpg --export-secret-keys --armor contact@andresbott.com \
  | gh secret set APT_SIGNING_KEY --repo ansible-autobott/debian-repo
```

Backing up the whole `.gnupg-repo/` directory works too and additionally preserves
the revocation certificate (`openpgp-revocs.d/`). Nothing else needs backing up:
`DEBIAN_REPO_TOKEN` is regenerable, and the `autobott-archive-keyring.gpg`/`.asc`
keyring is the public key, already committed to the tree.

## Layout

```
packages/<app>.json          # per-app reference (machine-modifiable; app owns its file)
debs/                        # manually-added, committed .deb binaries
schema/                      # JSON Schema for packages/*.json
conf/                        # apt-ftparchive Release settings
conf/dists.conf              # DISTS/ALIASES/ARCHES — the releases + suite aliases this repo publishes
scripts/                     # register (app -> JSON) + hydrate + index-generation
scripts/dists-lib.sh         # loads + validates conf/dists.conf for hydrate/gen-index/render-index
.github/actions/register/    # composite action apps call to register a release
.github/workflows/           # publish.yml — build + sign + deploy on push to main
_site/                       # built site (git-ignored) — what CI uploads to Pages
_site/pool/<codename>/main/  # per-codename pool of .deb files (hydrated from packages/ + debs/)
_site/dists/<suite>/         # signed index per codename AND per alias (stable/testing/unstable)
```
