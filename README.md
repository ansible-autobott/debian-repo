# debian-repo

A static, GPG-signed **APT repository** for [autobott](https://github.com/ansible-autobott),
served over HTTPS from **GitHub Pages** — the Debian/Ubuntu counterpart to the
[`homebrew-tap`](https://github.com/ansible-autobott/homebrew-tap). Add it once and
install the tools with `apt` like any other package.

- **URL:** https://ansible-autobott.github.io/debian-repo
- **Suites:** per release — Debian `trixie`, `forky`, `sid` and Ubuntu `resolute` (+ aliases `stable`/`testing`/`unstable`) · **Component:** `main` · **Architectures:** `amd64`, `arm64`

## Install

Trust the signing key, then add a source. Pick **one** of the two:

- **Match your release** — recommended on the releases this repo publishes:
  Debian **trixie**, **forky**, **sid**, or Ubuntu **resolute** (26.04 LTS).
  Installs the build made for your exact release.
- **Track `stable`** — for any other release: older Ubuntu (jammy, noble, …) or
  an unlisted Debian (e.g. bookworm, bullseye). A suite label need not match the
  host release, so `stable` works on every host.

### Match your release (trixie / forky / sid / resolute)

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

This writes your host's own codename as the suite, so it only works when that
codename is one this repo publishes (`trixie`, `forky`, `sid`, `resolute`). On
any other host — an older Ubuntu, or an unlisted Debian release — that
`apt update` would 404; use the `stable` source below instead.

### Track `stable` (any unlisted release)

Download the ready-made source; its `Suites: stable` follows whatever the current
stable release is:

```bash
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL https://ansible-autobott.github.io/debian-repo/autobott-archive-keyring.gpg \
  -o /etc/apt/keyrings/autobott-archive-keyring.gpg
sudo curl -fsSL https://ansible-autobott.github.io/debian-repo/autobott.sources \
  -o /etc/apt/sources.list.d/autobott.sources
sudo apt update
```

Then install any tool by name, for example:

```bash
sudo apt install go-deps-view
```

## Update

The tools update through `apt` along with the rest of your system:

```bash
sudo apt update && sudo apt upgrade
```

## Remove the repository

```bash
sudo rm -f /etc/apt/sources.list.d/autobott.sources \
           /etc/apt/keyrings/autobott-archive-keyring.gpg
sudo apt update
```
