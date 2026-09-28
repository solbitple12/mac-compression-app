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

ZSTD_VERSION=1.5.7
ZSTD_URL="https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz"
ZSTD_SHA256=eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3

LIBARCHIVE_VERSION=3.8.9
LIBARCHIVE_URL="https://github.com/libarchive/libarchive/releases/download/v${LIBARCHIVE_VERSION}/libarchive-${LIBARCHIVE_VERSION}.tar.xz"
LIBARCHIVE_SHA256=888c934f9d95648ecb9163dc8e23ab80a476ecb81a8f1154704a227b5b676dde

ARCHS=(arm64 x86_64)

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

# zstd CLI without the optional zlib/xz/lz4 support; Tamp only uses it for .zst.
build_zstd() {
  local stamp="$BIN/.zstd-$ZSTD_VERSION"
  if [[ -x "$BIN/zstd" && -f "$stamp" ]]; then
    echo "zstd $ZSTD_VERSION is already built"
    return
  fi
  local tarball="$SRC/zstd-$ZSTD_VERSION.tar.gz"
  local dir="$SRC/zstd-$ZSTD_VERSION"
  fetch "$ZSTD_URL" "$ZSTD_SHA256" "$tarball"
  rm -rf "$dir"
  tar -xzf "$tarball" -C "$SRC"

  local slices=()
  for arch in "${ARCHS[@]}"; do
    echo "Building zstd $ZSTD_VERSION for $arch"
    make -C "$dir/programs" clean >/dev/null
    make -C "$dir/programs" -j"$JOBS" zstd CC="clang -arch $arch" HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0 >/dev/null
    cp "$dir/programs/zstd" "$SRC/zstd-$arch"
    slices+=("$SRC/zstd-$arch")
  done
  lipo -create -output "$BIN/zstd" "${slices[@]}"
  cp "$dir/LICENSE" "$LICENSES/zstd.txt"
  rm -f "$BIN"/.zstd-*
  touch "$stamp"
  echo "Built $BIN/zstd ($(lipo -archs "$BIN/zstd"))"
}

# bsdtar from libarchive, statically linked, with only what plain tar needs:
# compression happens in the separate zstd helper.
build_bsdtar() {
  local stamp="$BIN/.bsdtar-$LIBARCHIVE_VERSION"
  if [[ -x "$BIN/bsdtar" && -f "$stamp" ]]; then
    echo "bsdtar $LIBARCHIVE_VERSION is already built"
    return
  fi
  local tarball="$SRC/libarchive-$LIBARCHIVE_VERSION.tar.xz"
  local dir="$SRC/libarchive-$LIBARCHIVE_VERSION"
  fetch "$LIBARCHIVE_URL" "$LIBARCHIVE_SHA256" "$tarball"
  rm -rf "$dir"
  tar -xf "$tarball" -C "$SRC"

  local slices=()
  for arch in "${ARCHS[@]}"; do
    local host
    if [[ "$arch" == arm64 ]]; then host=aarch64-apple-darwin; else host=x86_64-apple-darwin; fi
    echo "Building bsdtar $LIBARCHIVE_VERSION for $arch"
    mkdir -p "$dir/build-$arch"
    (
      cd "$dir/build-$arch"
      CC="clang -arch $arch" ../configure --host="$host" \
        --disable-shared --enable-static --enable-bsdtar=static \
        --disable-bsdcpio --disable-bsdcat --disable-bsdunzip \
        --disable-acl --disable-xattr \
        --without-zlib --without-bz2lib --without-lzma --without-zstd --without-lz4 \
        --without-libb2 --without-openssl --without-mbedtls --without-nettle \
        --without-xml2 --without-expat --without-cng >/dev/null
      make -j"$JOBS" bsdtar >/dev/null
    )
    slices+=("$dir/build-$arch/bsdtar")
  done
  lipo -create -output "$BIN/bsdtar" "${slices[@]}"
  cp "$dir/COPYING" "$LICENSES/libarchive.txt"
  rm -f "$BIN"/.bsdtar-*
  touch "$stamp"
  echo "Built $BIN/bsdtar ($(lipo -archs "$BIN/bsdtar"))"
}

build_7zz
build_zstd
build_bsdtar
