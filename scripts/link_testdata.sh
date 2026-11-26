#!/bin/bash
# testdata/link is a copy of testdata/link in aytutuna/LazyKit at the commit named in testdata/link.pin. The tests of
# all three code bases read it from here.
#   link_testdata.sh check          the files match SHA256SUMS and SHA256SUMS matches the pin
#   link_testdata.sh update <sha>   fetch that LazyKit commit, check it against its own SHA256SUMS and write the pin
#   link_testdata.sh commit         print the pinned LazyKit commit
#   link_testdata.sh kit <dir>      check that a LazyKit checkout carries the pinned data
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/testdata/link"
pin="$root/testdata/link.pin"
raw="https://raw.githubusercontent.com/aytutuna/LazyKit"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

check() {
  local wanted
  wanted=$(sed -n 's/^sums //p' "$pin" | tr -d '\r')
  if [ "$(sha256 "$dir/SHA256SUMS")" != "$wanted" ]; then
    echo "testdata/link/SHA256SUMS is not the one in testdata/link.pin" >&2
    exit 1
  fi
  (cd "$dir" && while read -r hash name; do
    name="${name#\*}"
    if [ "$(sha256 "$name")" != "$hash" ]; then
      echo "$name does not match SHA256SUMS" >&2
      exit 1
    fi
  done < SHA256SUMS)
  echo "testdata/link matches $(sed -n 's/^commit //p' "$pin")"
}

update() {
  local commit="$1" tmp
  tmp=$(mktemp -d)
  trap "rm -rf '$tmp'" EXIT
  curl -fsSL --retry 3 --retry-all-errors --retry-delay 10 -o "$tmp/SHA256SUMS" "$raw/$commit/testdata/link/SHA256SUMS"
  curl -fsSL --retry 3 --retry-all-errors --retry-delay 10 -o "$tmp/.gitattributes" "$raw/$commit/testdata/link/.gitattributes"
  while read -r hash name; do
    name="${name#\*}"
    curl -fsSL --retry 3 --retry-all-errors --retry-delay 10 -o "$tmp/$name" "$raw/$commit/testdata/link/$name"
    if [ "$(sha256 "$tmp/$name")" != "$hash" ]; then
      echo "$name: checksum mismatch" >&2
      exit 1
    fi
  done < "$tmp/SHA256SUMS"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp "$tmp/SHA256SUMS" "$tmp/.gitattributes" "$dir/"
  while read -r _ name; do cp "$tmp/${name#\*}" "$dir/"; done < "$tmp/SHA256SUMS"
  printf 'commit %s\nsums %s\n' "$commit" "$(sha256 "$dir/SHA256SUMS")" > "$pin"
  check
}

commit() {
  local sha
  sha=$(sed -n 's/^commit //p' "$pin" | tr -d '\r')
  if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "testdata/link.pin has no 40 character commit" >&2
    exit 1
  fi
  echo "$sha"
}

kit() {
  if [ "$(sha256 "$1/testdata/link/SHA256SUMS")" != "$(sed -n 's/^sums //p' "$pin" | tr -d '\r')" ]; then
    echo "the LazyKit checkout does not carry the data testdata/link.pin names" >&2
    exit 1
  fi
}

case "${1:-check}" in
  check) check ;;
  commit) commit ;;
  kit) kit "${2:?usage: link_testdata.sh kit <LazyKit checkout>}" ;;
  update) update "${2:?usage: link_testdata.sh update <LazyKit commit>}" ;;
  *) echo "usage: link_testdata.sh check | commit | kit <dir> | update <LazyKit commit>" >&2; exit 2 ;;
esac
