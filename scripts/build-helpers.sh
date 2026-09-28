#!/usr/bin/env bash
# Builds the helper executables Tamp bundles as universal (arm64 + x86_64)
# binaries for macOS 14+, and collects each one's license.
#
#   scripts/build-helpers.sh            build everything missing
#   TAMP_HELPERS_OUT=dir scripts/...    build somewhere other than build/helpers
#
# Output: build/helpers/bin (executables), build/helpers/licenses (license texts).
# Sources are downloaded once into build/helpers/src and checked against the
# pinned SHA-256 before use.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TAMP_HELPERS_OUT:-$ROOT/build/helpers}"
SRC="$OUT/src"
BIN="$OUT/bin"
LICENSES="$OUT/licenses"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
export MACOSX_DEPLOYMENT_TARGET=14.0

SEVENZIP_VERSION=26.03
SEVENZIP_URL="https://github.com/ip7z/7zip/releases/download/${SEVENZIP_VERSION}/7z${SEVENZIP_VERSION/./}-src.tar.xz"
SEVENZIP_SHA256=9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4

mkdir -p "$SRC" "$BIN" "$LICENSES"

# fetch URL SHA256 FILE: downloads FILE unless it is already there with the right checksum.
fetch() {
  local url=$1 sha=$2 file=$3
  if [[ -f "$file" ]] && echo "$sha  $file" | shasum -a 256 -c - >/dev/null 2>&1; then
    return
  fi
  echo "Downloading $url"
  curl -fsSL --retry 3 -o "$file.part" "$url"
  echo "$sha  $file.part" | shasum -a 256 -c - >/dev/null || {
    echo "Checksum mismatch for $url" >&2
    rm -f "$file.part"
    exit 1
  }
  mv "$file.part" "$file"
}

build_7zz() {
  local stamp="$BIN/.7zz-$SEVENZIP_VERSION"
  if [[ -x "$BIN/7zz" && -f "$stamp" ]]; then
    echo "7zz $SEVENZIP_VERSION is already built"
    return
  fi
  local tarball="$SRC/7zip-$SEVENZIP_VERSION-src.tar.xz"
  local dir="$SRC/7zip-$SEVENZIP_VERSION"
  fetch "$SEVENZIP_URL" "$SEVENZIP_SHA256" "$tarball"
  rm -rf "$dir"
  mkdir -p "$dir"
  tar -xf "$tarball" -C "$dir"

  local bundle="$dir/CPP/7zip/Bundles/Alone2"
  echo "Building 7zz $SEVENZIP_VERSION for arm64"
  (cd "$bundle" && make -j"$JOBS" -f ../../cmpl_mac_arm64.mak >/dev/null)
  echo "Building 7zz $SEVENZIP_VERSION for x86_64"
  (cd "$bundle" && make -j"$JOBS" -f ../../cmpl_mac_x64.mak >/dev/null)

  lipo -create -output "$BIN/7zz" "$bundle/b/m_arm64/7zz" "$bundle/b/m_x64/7zz"
  cp "$dir/DOC/License.txt" "$LICENSES/7-Zip.txt"
  cp "$dir/DOC/unRarLicense.txt" "$LICENSES/7-Zip-unRAR.txt"
  rm -f "$BIN"/.7zz-*
  touch "$stamp"
  echo "Built $BIN/7zz ($(lipo -archs "$BIN/7zz"))"
}

build_7zz
