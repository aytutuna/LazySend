#!/bin/bash
# Fetches DocAligner's FastViT-T8 corner model (DocsaidLab/DocAligner release 1.1.1, Apache-2.0, see
# Sources/LazySendScanModel/Models/DocAligner-LICENSE.txt) into Sources/LazySendScanModel/Models, the
# page corner model of the iPhone and Android apps' scan mode. It is not checked in; without it the iPhone app's scan mode
# finds no page by itself (the corner editor still works) and the tests that need it skip, but the Android build fails. The file is checked against its SHA-256. Runs in macOS bash
# and in Git Bash on Windows.
set -euo pipefail

release="https://github.com/DocsaidLab/DocAligner/releases/download/1.1.1"
models="$(cd "$(dirname "$0")/.." && pwd)/Sources/LazySendScanModel/Models"

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  else
    sha256sum "$1" | cut -d ' ' -f 1
  fi
}

fetch() {
  local name="$1" expected="$2"
  local file="$models/$name"
  if [ -f "$file" ] && [ "$(sha256 "$file")" = "$expected" ]; then
    echo "$name: already fetched"
    return
  fi
  curl -fsSL -o "$file.part" "$release/$name"
  local hash
  hash=$(sha256 "$file.part")
  if [ "$hash" != "$expected" ]; then
    rm -f "$file.part"
    echo "$name: checksum mismatch: $hash" >&2
    exit 1
  fi
  mv "$file.part" "$file"
  echo "$name: fetched"
}

fetch fastvit_t8_h_e_bifpn_256_fp32.onnx 950070fd4a46e25d46db7c35d0ed77612d9063f70d4543c7c504f0da6a943a89
