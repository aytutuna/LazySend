#!/bin/bash
# Builds the Rust link core from a LazyKit checkout, generates its Swift bindings and runs scripts/rust_link/main.swift
# against them. Needs a Mac with cargo and swiftc.
#   rust_link_swift.sh <path to the LazyKit checkout>
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
kit="$(cd "$1" && pwd)"
out="$root/.scratch/rust-link-swift"
rm -rf "$out"
mkdir -p "$out"

cd "$kit/rust"
cargo build --release -p lazy-link-ffi
cargo run -q -p uniffi-bindgen -- generate --library target/release/liblazy_link_ffi.dylib --language swift --out-dir "$out/gen"

swiftc -swift-version 5 -O \
  "$out/gen/lazy_link_ffi.swift" "$root/scripts/rust_link/main.swift" \
  -Xcc -fmodule-map-file="$out/gen/lazy_link_ffiFFI.modulemap" -I "$out/gen" \
  -L target/release -llazy_link_ffi -Xlinker -rpath -Xlinker "$PWD/target/release" \
  -o "$out/check"
"$out/check" "$root/testdata/link"
