# debian-repo — developer manual

How this APT repository works, how to set it up from scratch, and how to operate
it as a maintainer. For end-user install instructions see `README.md`.

- **URL:** https://ansible-autobott.github.io/debian-repo
- **Suite / component:** `stable` / `main` · **Architectures:** `amd64`, `arm64`

## How it works

The git tree **never stores binaries** — it stores *references*. The binaries are
downloaded, the index is built and GPG-signed **in CI**, and the result is
published to GitHub Pages. A package enters the repo in one of two ways:

1. **Automated (per-app JSON).** Each app owns one file, `packages/<app>.json`,
   holding its current version and a checksummed URL per architecture. The app's
   own release CI writes and commits that file (via the `register` action). Because
   every app owns a separate file, two releases never conflict.
2. **Manual (committed binary).** `make add DEB=foo.deb` stages a `.deb` into the
   git-tracked `debs/` folder; you commit it and it's hosted directly.

On every push to `main`, `.github/workflows/publish.yml` **rebuilds the whole repo**:
validate → download + verify every `packages/*.json` and merge `debs/` → sign →
deploy to Pages. The full set is reconstructed each run, so nothing clobbers
anything, and a failed download aborts the publish (the previous deployment stays
live) rather than shipping a partial index.

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
  (e.g. by goreleaser into `dist/`):

```yaml
      - uses: ansible-autobott/debian-repo/.github/actions/register@main
        with:
          name: go-deps-view          # must match the .deb's Package field
          dist-dir: dist              # where the .deb files were written
          token: ${{ secrets.DEBIAN_REPO_TOKEN }}
```

On the tool's next release that step writes `packages/<name>.json` here and pushes
it, which triggers a publish.

## Adding packages

### From a tool's release CI (the register action)

The [composite action](.github/actions/register/action.yml) runs this repo's own
[`scripts/register.sh`](scripts/register.sh): it builds `packages/<name>.json`
(per-arch URL + sha256 from the built debs), validates it against the schema, and
commits + pushes it (with rebase-retry). Keeping the logic here means a schema
change is made once, not in every app.

Inputs: `name` and `token` (required); `dist-dir` (default `dist`), `tag` (default
the release ref), `source-repo` (default the calling repo), `repo` (default
`ansible-autobott/debian-repo`). Pin `@v1` instead of `@main` to insulate apps from
format changes.

To generate a reference by hand (e.g. testing), `scripts/register.sh` is also wired
to `make register NAME=… REPO=owner/app TAG=vX.Y.Z [DIST=dist]`.

### Manually (a committed binary)

For a one-off or a tool without a suitable release, add the `.deb` directly:

```bash
make add DEB=path/to/foo_1.0.0_amd64.deb   # copies it into debs/
git add debs/ && git commit -m "add foo 1.0.0" && git push
```

The binary is committed to git and merged into the pool alongside the JSON-hydrated
ones on the next publish.

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
    { "arch": "amd64", "url": "https://github.com/ansible-autobott/go-deps-view/releases/download/v1.3.0/go-deps-view_1.3.0_amd64.deb", "sha256": "<64 hex>" },
    { "arch": "arm64", "url": "https://github.com/ansible-autobott/go-deps-view/releases/download/v1.3.0/go-deps-view_1.3.0_arm64.deb", "sha256": "<64 hex>" }
  ]
}
```

Required: `name`, `version`, and `artifacts[]` (each with `arch`, `url`, `sha256`);
`additionalProperties` is `false` and URLs must be HTTPS. At publish time each
download is checked against `sha256`, and the `.deb`'s own
`Package`/`Version`/`Architecture` must match `name`/`version`/`arch` — otherwise
the build fails and the previous deployment stays live.

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
packages/<app>.json        # per-app reference (machine-modifiable; app owns its file)
debs/                      # manually-added, committed .deb binaries
schema/                    # JSON Schema for packages/*.json
conf/                      # apt-ftparchive Release settings
scripts/                   # register (app -> JSON) + hydrate + index-generation
.github/actions/register/  # composite action apps call to register a release
.github/workflows/         # publish.yml — build + sign + deploy on push to main
_site/                     # built site (git-ignored) — what CI uploads to Pages
```
