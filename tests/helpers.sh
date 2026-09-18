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
  # arch must be the trailing filename component: apt-ftparchive's --arch
  # (used by gen-index.sh) accepts only *_<arch>.deb / *_all.deb by filename,
  # not by the control file's Architecture: field (see apt-ftparchive(1), -a).
  mkdir -p "$outdir"; local out="$outdir/${name}_${ver}_${tag}_${arch}.deb"
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
