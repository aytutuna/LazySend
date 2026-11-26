#!/bin/bash
# Builds the Rust link core from a LazyKit checkout, generates its C# bindings and runs windows/LazySend.RustLink.Tests.
# Needs cargo, uniffi-bindgen-cs (version in LazyKit's rust/Cargo.toml) and dotnet.
#   rust_link_cs.sh <path to the LazyKit checkout>
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
kit="$(cd "$1" && pwd)"
out="$root/.scratch/rust-link-cs"
rm -rf "$out"
mkdir -p "$out"

cd "$kit/rust"
cargo build --release -p lazy-link-ffi
cp target/release/lazy_link_ffi.dll "$out/"
uniffi-bindgen-cs --library "$out/lazy_link_ffi.dll" --out-dir "$out"

cd "$root/windows"
dotnet test LazySend.RustLink.Tests -p:RustLinkDir="$(cygpath -m "$out")"
