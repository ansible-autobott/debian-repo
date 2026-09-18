# debian-repo

A static, GPG-signed **APT repository** for [autobott](https://github.com/ansible-autobott),
served over HTTPS from **GitHub Pages** — the Debian/Ubuntu counterpart to the
[`homebrew-tap`](https://github.com/ansible-autobott/homebrew-tap). Add it once and
install the tools with `apt` like any other package.

- **URL:** https://ansible-autobott.github.io/debian-repo
- **Suites:** per Debian release — `bookworm`, `trixie`, `sid` (+ aliases `stable`/`testing`/`unstable`) · **Component:** `main` · **Architectures:** `amd64`, `arm64`

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
