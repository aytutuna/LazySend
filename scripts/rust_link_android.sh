#!/bin/bash
# Builds the Rust link core from a LazyKit checkout for Android, generates its Kotlin bindings and runs the
# rustlink module's tests on the connected device or emulator. Needs cargo-ndk, the NDK (ANDROID_NDK_HOME) and a device.
#   rust_link_android.sh <path to the LazyKit checkout>
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
kit="$(cd "$1" && pwd)"
out="$root/.scratch/rust-link-android"
rm -rf "$out"
mkdir -p "$out"

cd "$kit/rust"
cargo ndk -t arm64-v8a -t x86_64 -P 26 -o "$out/jniLibs" build --release -p lazy-link-ffi
cargo run -q -p uniffi-bindgen -- generate --library "$out/jniLibs/arm64-v8a/liblazy_link_ffi.so" --language kotlin --out-dir "$out/kotlin" --no-format

cd "$root/android"
./gradlew :rustlink:connectedDebugAndroidTest -Plazysend.rustLink="$out" --console=plain
