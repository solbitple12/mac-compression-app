#!/usr/bin/env bash
# Builds the helper executables Tamp bundles as universal (arm64 + x86_64)
# binaries for macOS 14+, and collects each one's license.
#
#   scripts/build-helpers.sh            build everything missing
#   TAMP_HELPERS_OUT=dir scripts/...    build somewhere other than build/helpers
#
# Output: build/helpers/bin (executables), build/helpers/licenses (license texts).
# Sources are downloaded once into build/helpers/src and checked before use:
# tarballs against a pinned SHA-256, git checkouts against a pinned commit.
# Libraries the helpers link statically go to build/helpers/deps.
#
# Every component is under a permissive license (see README.md, "Bundled tools").
# GPL tools with the same job are deliberately not used: the lz4 and lzip
# command-line tools, lbzip2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TAMP_HELPERS_OUT:-$ROOT/build/helpers}"
SRC="$OUT/src"
BIN="$OUT/bin"
LICENSES="$OUT/licenses"
DEPS="$OUT/deps"
PATCHES="$ROOT/scripts/patches"
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
# Bumped when bsdtar's build changes without a new libarchive version.
BSDTAR_REVISION=2

# 5.6.0 and 5.6.1 carried the 2024 backdoor; anything from 5.6.2 on is clean.
XZ_VERSION=5.8.4
XZ_URL="https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.gz"
XZ_SHA256=0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9

LZ4_VERSION=1.10.0
LZ4_URL="https://github.com/lz4/lz4/releases/download/v${LZ4_VERSION}/lz4-${LZ4_VERSION}.tar.gz"
LZ4_SHA256=537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b

PIGZ_VERSION=2.8
PIGZ_GIT=https://github.com/madler/pigz
PIGZ_COMMIT=fe4894f57739e3039a2ffc2a2a360d35e19bacbe

PBZIP2_VERSION=1.1.13
PBZIP2_URL="https://launchpad.net/pbzip2/1.1/${PBZIP2_VERSION}/+download/pbzip2-${PBZIP2_VERSION}.tar.gz"
PBZIP2_SHA256=8fd13eaaa266f7ee91f85c1ea97c86d9c9cc985969db9059cdebcb1e1b7bdbe6

BROTLI_VERSION=1.2.0
BROTLI_GIT=https://github.com/google/brotli
BROTLI_COMMIT=028fb5a23661f123017c060daa546b55cf4bde29

ZPAQ_VERSION=7.15
ZPAQ_GIT=https://github.com/zpaq/zpaq
ZPAQ_COMMIT=9ab539f644e364f0d92e2918b90ce2534c75653f
# Bump when the zpaq patch changes, so cached builds are redone.
ZPAQ_REVISION=3

MINIZIP_VERSION=4.2.2
MINIZIP_GIT=https://github.com/zlib-ng/minizip-ng
MINIZIP_COMMIT=7b2387161c542fa9f427352dcdef76097d0d692b
# Bump when a minizip patch changes, so cached builds are redone.
MINIZIP_REVISION=3

# --- Phase 3: images and audio ---
# Pins only so far; build_ functions and TAMP_HELPERS arrive engine by engine.

MOZJPEG_VERSION=4.1.5
MOZJPEG_GIT=https://github.com/mozilla/mozjpeg
MOZJPEG_COMMIT=6c9f0897afa1c2738d7222a0a9ab49e8b536a267

OXIPNG_VERSION=10.2.1
OXIPNG_GIT=https://github.com/oxipng/oxipng
OXIPNG_COMMIT=36f3ef8aac65ecf1761739ea2f2e530281f1312b

LIBWEBP_VERSION=1.6.0
LIBWEBP_GIT=https://github.com/webmproject/libwebp
LIBWEBP_COMMIT=4fa21912338357f89e4fd51cf2368325b59e9bd9

LIBAVIF_VERSION=1.4.2
LIBAVIF_GIT=https://github.com/AOMediaCodec/libavif
LIBAVIF_COMMIT=c5240fc79fe5c2407e10afd35f5505ef6333ea49

# AVIF's AV1 encoder, shared with Phase 4's video; aom isn't reachable from here
# to compare, so this follows the plan's "SVT-AV1 or aom" alternative.
SVTAV1_VERSION=4.2.0
SVTAV1_GIT=https://github.com/AOMediaCodec/SVT-AV1
SVTAV1_COMMIT=9292ec8e32bce26f781f277ec8739b53426c4300

# AVIF decode, for the before/after preview.
DAV1D_VERSION=1.5.4
DAV1D_GIT=https://github.com/videolan/dav1d
DAV1D_COMMIT=af5b9fe0f9f44a7688263a850c24373b5b3fe9bd

# libjxl needs Google's Highway for its SIMD dispatch.
LIBJXL_VERSION=0.12.0
LIBJXL_GIT=https://github.com/libjxl/libjxl
LIBJXL_COMMIT=a7a9c787341cf703dede03c2009fa460cae5e5df

HIGHWAY_VERSION=1.4.0
HIGHWAY_GIT=https://github.com/google/highway
HIGHWAY_COMMIT=2607d3b5b0113992fe84d3848859eae13b3b52c1

# libjxl's color-management fallback (JPEGXL_ENABLE_SKCMS): a git submodule with no
# "use the system copy" option, compiled directly from source, not a library with
# its own releases or tags.
SKCMS_GIT=https://github.com/google/skcms
SKCMS_COMMIT=c1248c99cbd8cdc3ed8e8314c997600724e10c70

FLAC_VERSION=1.5.0
FLAC_GIT=https://github.com/xiph/flac
FLAC_COMMIT=1507800de4b70e21be71f38caa0d9079d0bc6e45

OPUS_VERSION=1.6.1
OPUS_GIT=https://github.com/xiph/opus
OPUS_COMMIT=22244de5a79bd1d6d623c32e72bf1954b56235be

WAVPACK_VERSION=5.9.0
WAVPACK_GIT=https://github.com/dbry/WavPack
WAVPACK_COMMIT=5803634a030e2a11dba602ba057b89cc34486c67

# LAME has no maintained git mirror with tagged releases, so it's pinned as a
# tarball like the earlier non-git sources. 4.0 is its current stable release.
LAME_VERSION=4.0
LAME_URL="https://downloads.sourceforge.net/project/lame/lame/4.0/lame-${LAME_VERSION}.tar.gz"
LAME_SHA256=3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb

ARCHS=(arm64 x86_64)
UNIVERSAL_CMAKE=(
  -DCMAKE_BUILD_TYPE=Release
  "-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64"
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"
  -DBUILD_SHARED_LIBS=OFF
)

mkdir -p "$SRC" "$BIN" "$LICENSES" "$DEPS/include" "$DEPS/lib"

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

# fetch_git URL TAG COMMIT DIR: a fresh checkout of TAG in DIR, which must be COMMIT.
fetch_git() {
  local url=$1 tag=$2 commit=$3 dir=$4
  rm -rf "$dir"
  echo "Cloning $url at $tag"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "$url" "$dir"
  local head
  head="$(git -C "$dir" rev-parse HEAD)"
  if [[ "$head" != "$commit" ]]; then
    echo "$url $tag is commit $head, expected $commit" >&2
    exit 1
  fi
}

host_for() {
  if [[ "$1" == arm64 ]]; then echo aarch64-apple-darwin; else echo x86_64-apple-darwin; fi
}

# built NAME VERSION: true if NAME is in bin with a stamp for VERSION.
built() {
  if [[ -x "$BIN/$1" && -f "$BIN/.$1-$2" ]]; then
    echo "$1 $2 is already built"
    return 0
  fi
  return 1
}

# stamp NAME VERSION: records that NAME was built at VERSION.
stamp() {
  rm -f "$BIN/.$1-"*
  touch "$BIN/.$1-$2"
  echo "Built $BIN/$1 ($(lipo -archs "$BIN/$1"))"
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

# Static libraries for bsdtar and minizip: liblzma (xz), liblz4, libzstd.
# Universal archives in deps/lib, so each architecture's link picks its slice.
# zlib and libbz2 come with macOS.
build_libraries() {
  local stamp="$DEPS/.libraries-$XZ_VERSION-$LZ4_VERSION-$ZSTD_VERSION"
  if [[ -f "$stamp" ]]; then
    echo "Libraries are already built"
    return
  fi
  rm -rf "$DEPS"
  mkdir -p "$DEPS/include" "$DEPS/lib"

  # xz: liblzma plus the xz tool itself, one build per architecture.
  local tarball="$SRC/xz-$XZ_VERSION.tar.gz"
  local dir="$SRC/xz-$XZ_VERSION"
  fetch "$XZ_URL" "$XZ_SHA256" "$tarball"
  rm -rf "$dir"
  tar -xzf "$tarball" -C "$SRC"
  local lzma_slices=() xz_slices=()
  for arch in "${ARCHS[@]}"; do
    echo "Building xz $XZ_VERSION for $arch"
    local prefix="$dir/install-$arch"
    mkdir -p "$dir/build-$arch"
    (
      cd "$dir/build-$arch"
      CC="clang -arch $arch" ../configure --host="$(host_for "$arch")" --prefix="$prefix" \
        --disable-shared --enable-static --disable-doc --disable-nls --disable-scripts \
        --disable-lzmainfo --disable-lzmadec --disable-xzdec --disable-lzma-links >/dev/null
      make -j"$JOBS" >/dev/null
      make install >/dev/null
    )
    lzma_slices+=("$prefix/lib/liblzma.a")
    xz_slices+=("$prefix/bin/xz")
  done
  lipo -create -output "$DEPS/lib/liblzma.a" "${lzma_slices[@]}"
  cp -R "$dir/install-arm64/include/." "$DEPS/include/"
  lipo -create -output "$BIN/xz" "${xz_slices[@]}"
  cp "$dir/COPYING.0BSD" "$LICENSES/xz.txt"
  stamp xz "$XZ_VERSION"

  # liblz4 only: the lz4 command-line tool is GPL-2.
  tarball="$SRC/lz4-$LZ4_VERSION.tar.gz"
  dir="$SRC/lz4-$LZ4_VERSION"
  fetch "$LZ4_URL" "$LZ4_SHA256" "$tarball"
  rm -rf "$dir"
  tar -xzf "$tarball" -C "$SRC"
  # One build per architecture: ar can't archive universal object files.
  local lz4_slices=()
  for arch in "${ARCHS[@]}"; do
    echo "Building liblz4 $LZ4_VERSION for $arch"
    make -C "$dir/lib" clean >/dev/null
    make -C "$dir/lib" -j"$JOBS" liblz4.a CC="clang -arch $arch" CFLAGS=-O3 >/dev/null
    cp "$dir/lib/liblz4.a" "$dir/liblz4-$arch.a"
    lz4_slices+=("$dir/liblz4-$arch.a")
  done
  lipo -create -output "$DEPS/lib/liblz4.a" "${lz4_slices[@]}"
  cp "$dir/lib/lz4.h" "$dir/lib/lz4hc.h" "$dir/lib/lz4frame.h" "$DEPS/include/"
  cp "$dir/lib/LICENSE" "$LICENSES/lz4.txt"

  # libzstd through CMake, which also writes the package files minizip-ng looks for.
  tarball="$SRC/zstd-$ZSTD_VERSION.tar.gz"
  dir="$SRC/zstd-$ZSTD_VERSION"
  fetch "$ZSTD_URL" "$ZSTD_SHA256" "$tarball"
  rm -rf "$dir"
  tar -xzf "$tarball" -C "$SRC"
  echo "Building libzstd $ZSTD_VERSION"
  cmake -S "$dir/build/cmake" -B "$dir/build-lib" "${UNIVERSAL_CMAKE[@]}" -DCMAKE_INSTALL_PREFIX="$DEPS" \
    -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_TESTS=OFF >/dev/null
  cmake --build "$dir/build-lib" -j"$JOBS" >/dev/null
  cmake --install "$dir/build-lib" >/dev/null

  touch "$stamp"
}

# bsdtar and bsdcat from libarchive, statically linked with every filter Tamp reads
# or writes: gzip, bzip2, xz, lzma, lzip, lz4 and zstd, plus the readers for
# ZIP, 7Z, RAR, CAB, ISO and CPIO. bsdcat decompresses single files.
build_bsdtar() {
  local version="$LIBARCHIVE_VERSION-$BSDTAR_REVISION-xz$XZ_VERSION-lz4$LZ4_VERSION-zstd$ZSTD_VERSION"
  if built bsdtar "$version" && built bsdcat "$version"; then
    return
  fi
  local tarball="$SRC/libarchive-$LIBARCHIVE_VERSION.tar.xz"
  local dir="$SRC/libarchive-$LIBARCHIVE_VERSION"
  fetch "$LIBARCHIVE_URL" "$LIBARCHIVE_SHA256" "$tarball"
  rm -rf "$dir"
  tar -xf "$tarball" -C "$SRC"

  local tar_slices=() cat_slices=()
  for arch in "${ARCHS[@]}"; do
    echo "Building bsdtar and bsdcat $LIBARCHIVE_VERSION for $arch"
    mkdir -p "$dir/build-$arch"
    (
      cd "$dir/build-$arch"
      CC="clang -arch $arch" CPPFLAGS="-I$DEPS/include" LDFLAGS="-L$DEPS/lib" \
        ../configure --host="$(host_for "$arch")" \
        --disable-shared --enable-static --enable-bsdtar=static --enable-bsdcat=static \
        --disable-bsdcpio --disable-bsdunzip \
        --disable-acl --disable-xattr \
        --with-zlib --with-bz2lib --with-lzma --with-zstd --with-lz4 \
        --without-libb2 --without-openssl --without-mbedtls --without-nettle \
        --without-xml2 --without-expat --without-cng >/dev/null
      make -j"$JOBS" bsdtar bsdcat >/dev/null
    )
    tar_slices+=("$dir/build-$arch/bsdtar")
    cat_slices+=("$dir/build-$arch/bsdcat")
  done
  lipo -create -output "$BIN/bsdtar" "${tar_slices[@]}"
  lipo -create -output "$BIN/bsdcat" "${cat_slices[@]}"
  # Fails the build if a filter didn't make it in.
  local linked
  linked="$("$BIN/bsdtar" --version)"
  for library in zlib/ liblzma/ bz2lib/ liblz4/ libzstd/; do
    [[ "$linked" == *"$library"* ]] || { echo "bsdtar lacks $library: $linked" >&2; exit 1; }
  done
  cp "$dir/COPYING" "$LICENSES/libarchive.txt"
  stamp bsdtar "$version"
  stamp bsdcat "$version"
}

# pigz for TAR.GZ, with Zopfli for its -11 level. Links the system zlib.
build_pigz() {
  built pigz "$PIGZ_VERSION" && return
  local dir="$SRC/pigz-$PIGZ_VERSION"
  fetch_git "$PIGZ_GIT" "v$PIGZ_VERSION" "$PIGZ_COMMIT" "$dir"
  echo "Building pigz $PIGZ_VERSION"
  make -C "$dir" -j"$JOBS" pigz CC="clang -arch arm64 -arch x86_64" CFLAGS="-O3" >/dev/null
  cp "$dir/pigz" "$BIN/pigz"
  sed -n '1,26p' "$dir/pigz.c" >"$LICENSES/pigz.txt"
  cp "$dir/zopfli/COPYING" "$LICENSES/zopfli.txt"
  stamp pigz "$PIGZ_VERSION"
}

# pbzip2 for TAR.BZ2 on every core. Links the system libbz2.
build_pbzip2() {
  built pbzip2 "$PBZIP2_VERSION" && return
  local tarball="$SRC/pbzip2-$PBZIP2_VERSION.tar.gz"
  local dir="$SRC/pbzip2-$PBZIP2_VERSION"
  fetch "$PBZIP2_URL" "$PBZIP2_SHA256" "$tarball"
  rm -rf "$dir"
  tar -xzf "$tarball" -C "$SRC"
  patch -d "$dir" -p1 --quiet <"$PATCHES/pbzip2-char8.patch"
  echo "Building pbzip2 $PBZIP2_VERSION"
  make -C "$dir" pbzip2 CXX="clang++ -arch arm64 -arch x86_64" \
    CXXFLAGS="-O2 -std=c++20 -Wno-reserved-user-defined-literal -D_FILE_OFFSET_BITS=64 -DUSE_STACKSIZE_CUSTOMIZATION" >/dev/null
  cp "$dir/pbzip2" "$BIN/pbzip2"
  cp "$dir/COPYING" "$LICENSES/pbzip2.txt"
  stamp pbzip2 "$PBZIP2_VERSION"
}

# The brotli tool for TAR.BR.
build_brotli() {
  local version="$BROTLI_VERSION"
  if built brotli "$version" && [[ -f "$DEPS/.brotli-libs-$version" ]]; then
    return
  fi
  local dir="$SRC/brotli-$BROTLI_VERSION"
  fetch_git "$BROTLI_GIT" "v$BROTLI_VERSION" "$BROTLI_COMMIT" "$dir"
  echo "Building brotli $BROTLI_VERSION"
  cmake -S "$dir" -B "$dir/out" "${UNIVERSAL_CMAKE[@]}" -DCMAKE_INSTALL_PREFIX="$DEPS" -DBROTLI_DISABLE_TESTS=ON >/dev/null
  cmake --build "$dir/out" -j"$JOBS" --target brotli brotlicommon brotlienc brotlidec >/dev/null
  cp "$dir/out/brotli" "$BIN/brotli"
  # Also installed for libjxl (Phase 3) to link against: its own FindBrotli.cmake
  # looks for brotlicommon/brotlienc/brotlidec by plain find_library, which this
  # satisfies without needing a real Brotli CMake package.
  cmake --install "$dir/out" >/dev/null
  cp "$dir/LICENSE" "$LICENSES/brotli.txt"
  stamp brotli "$version"
  touch "$DEPS/.brotli-libs-$version"
}

# zpaq for ZPAQ. NOJIT: its JIT writes x86 code at run time, which doesn't run on
# Apple silicon and would need an executable-memory entitlement on Intel.
build_zpaq() {
  built zpaq "$ZPAQ_VERSION-$ZPAQ_REVISION" && return
  local dir="$SRC/zpaq-$ZPAQ_VERSION"
  fetch_git "$ZPAQ_GIT" "$ZPAQ_VERSION" "$ZPAQ_COMMIT" "$dir"
  patch -d "$dir" -p1 --quiet <"$PATCHES/zpaq-no-parent-dirs.patch"
  patch -d "$dir" -p1 --quiet <"$PATCHES/zpaq-key-from-stdin.patch"
  echo "Building zpaq $ZPAQ_VERSION"
  clang++ -arch arm64 -arch x86_64 -O3 -Dunix -DNOJIT -pthread -w \
    -o "$BIN/zpaq" "$dir/zpaq.cpp" "$dir/libzpaq.cpp"
  cp "$dir/COPYING" "$LICENSES/zpaq.txt"
  stamp zpaq "$ZPAQ_VERSION-$ZPAQ_REVISION"
}

# minizip from minizip-ng, only for writing zstd inside ZIP (official 7-Zip reads
# it but can't write it). AES through Apple's CommonCrypto.
build_minizip() {
  local version="$MINIZIP_VERSION-$MINIZIP_REVISION-zstd$ZSTD_VERSION"
  built minizip "$version" && return
  local dir="$SRC/minizip-ng-$MINIZIP_VERSION"
  fetch_git "$MINIZIP_GIT" "$MINIZIP_VERSION" "$MINIZIP_COMMIT" "$dir"
  patch -d "$dir" -p1 --quiet <"$PATCHES/minizip-ng-link-data.patch"
  patch -d "$dir" -p1 --quiet <"$PATCHES/minizip-ng-tamp-options.patch"
  echo "Building minizip $MINIZIP_VERSION"
  cmake -S "$dir" -B "$dir/out" "${UNIVERSAL_CMAKE[@]}" -DCMAKE_PREFIX_PATH="$DEPS" \
    -DMZ_COMPAT=OFF -DMZ_ZLIB=OFF -DMZ_BZIP2=OFF -DMZ_LZMA=OFF -DMZ_PPMD=OFF -DMZ_ZSTD=ON \
    -DMZ_LIBCOMP=OFF -DMZ_FETCH_LIBS=OFF -DMZ_PKCRYPT=OFF -DMZ_WZAES=ON -DMZ_OPENSSL=OFF \
    -DMZ_LIBBSD=OFF -DMZ_ICONV=OFF -DMZ_BUILD_TESTS=ON >/dev/null
  cmake --build "$dir/out" -j"$JOBS" --target minizip_cli >/dev/null
  cp "$dir/out/minizip" "$BIN/minizip"
  cp "$dir/LICENSE" "$LICENSES/minizip-ng.txt"
  stamp minizip "$version"
}

# oxipng for PNG. It's Rust, unlike every other helper here, so it needs a Rust
# toolchain with both Apple targets (macOS runners and Homebrew's rustup both have
# a recent stable Rust; `rustup target add` fetches the extra target if missing).
build_oxipng() {
  built oxipng "$OXIPNG_VERSION" && return
  command -v cargo >/dev/null || { echo "oxipng needs a Rust toolchain: install rustup" >&2; exit 1; }
  local dir="$SRC/oxipng-$OXIPNG_VERSION"
  fetch_git "$OXIPNG_GIT" "v$OXIPNG_VERSION" "$OXIPNG_COMMIT" "$dir"
  rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null 2>&1 || true
  local slices=()
  for target in aarch64-apple-darwin x86_64-apple-darwin; do
    echo "Building oxipng $OXIPNG_VERSION for $target"
    (cd "$dir" && MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" cargo build --release --target "$target" --bin oxipng >/dev/null)
    slices+=("$dir/target/$target/release/oxipng")
  done
  lipo -create -output "$BIN/oxipng" "${slices[@]}"
  cp "$dir/LICENSE" "$LICENSES/oxipng.txt"
  stamp oxipng "$OXIPNG_VERSION"
}

# mozjpeg for JPEG: cjpeg and djpeg for the lossy path (decode to pixels, re-encode
# at a chosen quality), jpegtran for the lossless path (Huffman tables only).
build_mozjpeg() {
  if built cjpeg "$MOZJPEG_VERSION" && built djpeg "$MOZJPEG_VERSION" && built jpegtran "$MOZJPEG_VERSION"; then
    return
  fi
  local dir="$SRC/mozjpeg-$MOZJPEG_VERSION"
  fetch_git "$MOZJPEG_GIT" "v$MOZJPEG_VERSION" "$MOZJPEG_COMMIT" "$dir"
  # Its SIMD is hand-written assembly, which CMake (rightly) refuses to build for
  # two architectures in one pass; one configure and build per architecture, lipo'd
  # together after, same as 7zz, xz and liblz4 above.
  local cjpeg_slices=() djpeg_slices=() jpegtran_slices=()
  for arch in "${ARCHS[@]}"; do
    echo "Building mozjpeg $MOZJPEG_VERSION for $arch"
    # mozjpeg's own cmake_minimum_required predates CMake 3.5, which current CMake
    # refuses to honor at all; this just accepts the old policies rather than the
    # (removed) old behavior itself, which is fine for a plain C build like this one.
    cmake -S "$dir" -B "$dir/out-$arch" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$arch" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_TESTING=OFF \
      -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_JPEG8=1 -DPNG_SUPPORTED=OFF -DWITH_TURBOJPEG=OFF >/dev/null
    # With ENABLE_SHARED off, its CMakeLists names the executable targets (and the
    # binaries themselves; there's no OUTPUT_NAME override) cjpeg-static and so on,
    # not the plain names --target cjpeg guessed at.
    cmake --build "$dir/out-$arch" -j"$JOBS" --target cjpeg-static djpeg-static jpegtran-static >/dev/null
    local cjpeg_binary djpeg_binary jpegtran_binary
    cjpeg_binary="$(find "$dir/out-$arch" -type f -name cjpeg-static -perm +111 | head -1)"
    djpeg_binary="$(find "$dir/out-$arch" -type f -name djpeg-static -perm +111 | head -1)"
    jpegtran_binary="$(find "$dir/out-$arch" -type f -name jpegtran-static -perm +111 | head -1)"
    if [[ -z "$cjpeg_binary" || -z "$djpeg_binary" || -z "$jpegtran_binary" ]]; then
      echo "mozjpeg built for $arch but cjpeg-static/djpeg-static/jpegtran-static weren't found under $dir/out-$arch" >&2
      exit 1
    fi
    cjpeg_slices+=("$cjpeg_binary")
    djpeg_slices+=("$djpeg_binary")
    jpegtran_slices+=("$jpegtran_binary")
  done
  lipo -create -output "$BIN/cjpeg" "${cjpeg_slices[@]}"
  lipo -create -output "$BIN/djpeg" "${djpeg_slices[@]}"
  lipo -create -output "$BIN/jpegtran" "${jpegtran_slices[@]}"
  cp "$dir/LICENSE.md" "$LICENSES/mozjpeg.txt"
  stamp cjpeg "$MOZJPEG_VERSION"
  stamp djpeg "$MOZJPEG_VERSION"
  stamp jpegtran "$MOZJPEG_VERSION"
}

# cwebp for WebP, lossy and lossless.
build_libwebp() {
  built cwebp "$LIBWEBP_VERSION" && return
  local dir="$SRC/libwebp-$LIBWEBP_VERSION"
  fetch_git "$LIBWEBP_GIT" "v$LIBWEBP_VERSION" "$LIBWEBP_COMMIT" "$dir"
  # Its x86 and NEON SIMD, like mozjpeg's, doesn't compile correctly in a single
  # multi-arch CMAKE_OSX_ARCHITECTURES pass (no explicit guard the way
  # libjpeg-turbo has one, but the arm64 host still mis-detects the x86_64 slice's
  # target features and breaks its SSE2 code): the same per-arch build and lipo.
  local slices=()
  for arch in "${ARCHS[@]}"; do
    echo "Building libwebp $LIBWEBP_VERSION for $arch"
    cmake -S "$dir" -B "$dir/out-$arch" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$arch" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DWEBP_BUILD_CWEBP=ON -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
      -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF \
      -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF -DWEBP_BUILD_ANIM_UTILS=OFF >/dev/null
    cmake --build "$dir/out-$arch" -j"$JOBS" --target cwebp >/dev/null
    local cwebp_binary
    cwebp_binary="$(find "$dir/out-$arch" -type f -name cwebp -perm +111 | head -1)"
    [[ -n "$cwebp_binary" ]] || { echo "libwebp built for $arch but cwebp wasn't found under $dir/out-$arch" >&2; exit 1; }
    slices+=("$cwebp_binary")
  done
  lipo -create -output "$BIN/cwebp" "${slices[@]}"
  cp "$dir/COPYING" "$LICENSES/libwebp.txt"
  stamp cwebp "$LIBWEBP_VERSION"
}

# The flac CLI, for FLAC.
build_flac() {
  built flac "$FLAC_VERSION" && return
  local dir="$SRC/flac-$FLAC_VERSION"
  fetch_git "$FLAC_GIT" "$FLAC_VERSION" "$FLAC_COMMIT" "$dir"
  echo "Building flac $FLAC_VERSION"
  cmake -S "$dir" -B "$dir/out" "${UNIVERSAL_CMAKE[@]}" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_CXXLIBS=OFF -DBUILD_PROGRAMS=ON -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF -DBUILD_DOCS=OFF -DINSTALL_MANPAGES=OFF -DWITH_OGG=OFF >/dev/null
  cmake --build "$dir/out" -j"$JOBS" --target flac >/dev/null
  # Its exact spot under out/ isn't pinned by the CMakeLists, so find it rather
  # than guess a nested path that could move between versions.
  local built_binary
  built_binary="$(find "$dir/out" -type f -name flac -perm +111 | head -1)"
  [[ -n "$built_binary" ]] || { echo "flac built but its binary wasn't found under $dir/out" >&2; exit 1; }
  cp "$built_binary" "$BIN/flac"
  cp "$dir/COPYING.Xiph" "$LICENSES/flac.txt"
  stamp flac "$FLAC_VERSION"
}

# wavpack (encoder) and wvunpack (decoder, used only by the test suite's
# independent round-trip check, not bundled into the app) for WavPack.
build_wavpack() {
  if built wavpack "$WAVPACK_VERSION" && built wvunpack "$WAVPACK_VERSION"; then
    return
  fi
  local dir="$SRC/WavPack-$WAVPACK_VERSION"
  fetch_git "$WAVPACK_GIT" "$WAVPACK_VERSION" "$WAVPACK_COMMIT" "$dir"
  echo "Building WavPack $WAVPACK_VERSION"
  cmake -S "$dir" -B "$dir/out" "${UNIVERSAL_CMAKE[@]}" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=OFF -DWAVPACK_BUILD_PROGRAMS=ON -DWAVPACK_BUILD_DOCS=OFF \
    -DWAVPACK_ENABLE_LEGACY_FORMAT=OFF -DWAVPACK_BUILD_WINAMP_PLUGIN=OFF \
    -DWAVPACK_BUILD_COOLEDIT_PLUGIN=OFF -DWAVPACK_INSTALL_DOCS=OFF -DWAVPACK_INSTALL_CMAKE_MODULE=OFF >/dev/null
  cmake --build "$dir/out" -j"$JOBS" --target wavpack wvunpack >/dev/null
  local wavpack_binary wvunpack_binary
  wavpack_binary="$(find "$dir/out" -type f -name wavpack -perm +111 | head -1)"
  wvunpack_binary="$(find "$dir/out" -type f -name wvunpack -perm +111 | head -1)"
  [[ -n "$wavpack_binary" && -n "$wvunpack_binary" ]] || { echo "WavPack built but its binaries weren't found under $dir/out" >&2; exit 1; }
  cp "$wavpack_binary" "$BIN/wavpack"
  cp "$wvunpack_binary" "$BIN/wvunpack"
  cp "$dir/COPYING" "$LICENSES/wavpack.txt"
  stamp wavpack "$WAVPACK_VERSION"
  stamp wvunpack "$WAVPACK_VERSION"
}

# The lame CLI, for MP3. Autotools like xz and bsdtar above, so the same
# configure-per-architecture-then-lipo shape, rather than mozjpeg's CMake dance.
build_lame() {
  built lame "$LAME_VERSION" && return
  local tarball="$SRC/lame-$LAME_VERSION.tar.gz"
  local dir="$SRC/lame-$LAME_VERSION"
  fetch "$LAME_URL" "$LAME_SHA256" "$tarball"
  rm -rf "$dir"
  tar -xzf "$tarball" -C "$SRC"
  local slices=()
  for arch in "${ARCHS[@]}"; do
    echo "Building lame $LAME_VERSION for $arch"
    local prefix="$dir/install-$arch"
    mkdir -p "$dir/build-$arch"
    (
      cd "$dir/build-$arch"
      # --disable-nasm: its x86 assembly won't build for arm64 anyway, and this
      # keeps both architectures on the same portable-C code path.
      CC="clang -arch $arch" CFLAGS="-O2" ../configure --host="$(host_for "$arch")" --prefix="$prefix" \
        --disable-shared --enable-static --disable-nasm >/dev/null
      make -j"$JOBS" >/dev/null
      make install >/dev/null
    )
    slices+=("$prefix/bin/lame")
  done
  lipo -create -output "$BIN/lame" "${slices[@]}"
  cp "$dir/COPYING" "$LICENSES/lame.txt"
  stamp lame "$LAME_VERSION"
}

# SvtAv1EncApp, and libSvtAv1Enc installed into deps/ for libavif's AVIF encode
# (Phase 3) and, later, Phase 4's AV1 video to link against. Heavily hand-optimized
# SIMD, like mozjpeg, so the same per-architecture build and lipo, not
# UNIVERSAL_CMAKE's single pass.
build_svtav1() {
  built SvtAv1EncApp "$SVTAV1_VERSION" && return
  local dir="$SRC/SVT-AV1-$SVTAV1_VERSION"
  fetch_git "$SVTAV1_GIT" "v$SVTAV1_VERSION" "$SVTAV1_COMMIT" "$dir"
  local app_slices=()
  for arch in "${ARCHS[@]}"; do
    echo "Building SVT-AV1 $SVTAV1_VERSION for $arch"
    local prefix="$dir/install-$arch"
    cmake -S "$dir" -B "$dir/out-$arch" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$arch" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_INSTALL_PREFIX="$prefix" -DBUILD_SHARED_LIBS=OFF -DBUILD_APPS=ON -DBUILD_TESTING=OFF >/dev/null
    cmake --build "$dir/out-$arch" -j"$JOBS" --target SvtAv1EncApp SvtAv1Enc >/dev/null
    cmake --install "$dir/out-$arch" --component Runtime >/dev/null
    cmake --install "$dir/out-$arch" --component Development >/dev/null
    local app_binary
    app_binary="$(find "$dir/out-$arch" -type f -name SvtAv1EncApp -perm +111 | head -1)"
    [[ -n "$app_binary" ]] || { echo "SVT-AV1 built for $arch but SvtAv1EncApp wasn't found under $dir/out-$arch" >&2; exit 1; }
    app_slices+=("$app_binary")
  done
  lipo -create -output "$BIN/SvtAv1EncApp" "${app_slices[@]}"
  # Headers, the pkg-config file and the CMake package config are plain text, so
  # one architecture's copy is enough; the static library itself needs lipo'ing
  # into a universal archive like every other DEPS library, so whichever
  # architecture links against it later (here, and again in Phase 4) gets its slice.
  mkdir -p "$DEPS/include" "$DEPS/lib"
  cp -R "$dir/install-arm64/include/." "$DEPS/include/"
  cp -R "$dir/install-arm64/lib/." "$DEPS/lib/"
  local static_library
  static_library="$(find "$dir/install-arm64/lib" -type f -name 'libSvtAv1Enc.a' | head -1)"
  [[ -n "$static_library" ]] || { echo "SVT-AV1 installed but its static library wasn't found" >&2; exit 1; }
  local relative="${static_library#"$dir/install-arm64/lib/"}"
  lipo -create -output "$DEPS/lib/$relative" "$dir/install-arm64/lib/$relative" "$dir/install-x86_64/lib/$relative"
  cp "$dir/LICENSE.md" "$LICENSES/SVT-AV1.txt"
  stamp SvtAv1EncApp "$SVTAV1_VERSION"
}

# Highway (libhwy) into deps/, for libjxl's SIMD dispatch. Its SIMD is
# target-specific C++ compiled per-architecture by clang itself, not separate
# assembly files, so (unlike mozjpeg and SVT-AV1) the ordinary single-pass
# universal build works.
build_highway() {
  local stamp="$DEPS/.highway-$HIGHWAY_VERSION"
  [[ -f "$stamp" ]] && { echo "Highway $HIGHWAY_VERSION is already built"; return; }
  local dir="$SRC/highway-$HIGHWAY_VERSION"
  fetch_git "$HIGHWAY_GIT" "$HIGHWAY_VERSION" "$HIGHWAY_COMMIT" "$dir"
  echo "Building Highway $HIGHWAY_VERSION"
  cmake -S "$dir" -B "$dir/out" "${UNIVERSAL_CMAKE[@]}" -DCMAKE_INSTALL_PREFIX="$DEPS" \
    -DHWY_ENABLE_CONTRIB=OFF -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_INSTALL=ON >/dev/null
  cmake --build "$dir/out" -j"$JOBS" --target hwy >/dev/null
  cmake --install "$dir/out" >/dev/null
  cp "$dir/LICENSE" "$LICENSES/highway.txt"
  touch "$stamp"
}

# cjxl and djxl, for JPEG XL. Highway and Brotli come from deps/, found the way
# libjxl's own third_party/CMakeLists.txt and cmake/FindBrotli.cmake look for
# them (JPEGXL_FORCE_SYSTEM_HWY, plain find_library). skcms has no such option
# and isn't a library with its own build, so its source goes straight into
# libjxl's own third_party/skcms, where its CMake expects to find it. sjpeg and
# OpenEXR support are off: Tamp doesn't need either.
build_libjxl() {
  if built cjxl "$LIBJXL_VERSION" && built djxl "$LIBJXL_VERSION"; then
    return
  fi
  local dir="$SRC/libjxl-$LIBJXL_VERSION"
  fetch_git "$LIBJXL_GIT" "v$LIBJXL_VERSION" "$LIBJXL_COMMIT" "$dir"
  fetch_git "$SKCMS_GIT" main "$SKCMS_COMMIT" "$dir/third_party/skcms"
  echo "Building libjxl $LIBJXL_VERSION"
  cmake -S "$dir" -B "$dir/out" "${UNIVERSAL_CMAKE[@]}" -DCMAKE_PREFIX_PATH="$DEPS" \
    -DJPEGXL_STATIC=ON -DJPEGXL_ENABLE_TOOLS=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON -DJPEGXL_FORCE_SYSTEM_BROTLI=ON \
    -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_PLUGINS=OFF \
    -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_DOXYGEN=OFF -DBUILD_TESTING=OFF >/dev/null
  cmake --build "$dir/out" -j"$JOBS" --target cjxl djxl >/dev/null
  local cjxl_binary djxl_binary
  cjxl_binary="$(find "$dir/out" -type f -name cjxl -perm +111 | head -1)"
  djxl_binary="$(find "$dir/out" -type f -name djxl -perm +111 | head -1)"
  if [[ -z "$cjxl_binary" || -z "$djxl_binary" ]]; then
    echo "libjxl built but cjxl/djxl weren't found under $dir/out" >&2
    exit 1
  fi
  cp "$cjxl_binary" "$BIN/cjxl"
  cp "$djxl_binary" "$BIN/djxl"
  cp "$dir/LICENSE" "$LICENSES/libjxl.txt"
  stamp cjxl "$LIBJXL_VERSION"
  stamp djxl "$LIBJXL_VERSION"
}

build_7zz
build_zstd
build_libraries
build_bsdtar
build_pigz
build_pbzip2
build_brotli
build_zpaq
build_minizip
build_oxipng
build_mozjpeg
build_libwebp
build_flac
build_wavpack
build_lame
build_svtav1
build_highway
build_libjxl
