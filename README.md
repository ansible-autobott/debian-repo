# debian-repo

A static, GPG-signed **APT repository** for [autobott](https://github.com/ansible-autobott),
served over HTTPS from **GitHub Pages** — the Debian/Ubuntu counterpart to the
[`homebrew-tap`](https://github.com/ansible-autobott/homebrew-tap). Add it once and
install the tools with `apt` like any other package.

- **URL:** https://ansible-autobott.github.io/debian-repo
- **Suite / component:** `stable` / `main` · **Architectures:** `amd64`, `arm64`

## Install

Trust the repository's signing key and add the source:

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
