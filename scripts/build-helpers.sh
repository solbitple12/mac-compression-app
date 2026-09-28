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

MINIZIP_VERSION=4.2.2
MINIZIP_GIT=https://github.com/zlib-ng/minizip-ng
MINIZIP_COMMIT=7b2387161c542fa9f427352dcdef76097d0d692b
# Bump when a minizip patch changes, so cached builds are redone.
MINIZIP_REVISION=2

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
  built brotli "$BROTLI_VERSION" && return
  local dir="$SRC/brotli-$BROTLI_VERSION"
  fetch_git "$BROTLI_GIT" "v$BROTLI_VERSION" "$BROTLI_COMMIT" "$dir"
  echo "Building brotli $BROTLI_VERSION"
  cmake -S "$dir" -B "$dir/out" "${UNIVERSAL_CMAKE[@]}" -DBROTLI_DISABLE_TESTS=ON >/dev/null
  cmake --build "$dir/out" -j"$JOBS" --target brotli >/dev/null
  cp "$dir/out/brotli" "$BIN/brotli"
  cp "$dir/LICENSE" "$LICENSES/brotli.txt"
  stamp brotli "$BROTLI_VERSION"
}

# zpaq for ZPAQ. NOJIT: its JIT writes x86 code at run time, which doesn't run on
# Apple silicon and would need an executable-memory entitlement on Intel.
build_zpaq() {
  built zpaq "$ZPAQ_VERSION" && return
  local dir="$SRC/zpaq-$ZPAQ_VERSION"
  fetch_git "$ZPAQ_GIT" "$ZPAQ_VERSION" "$ZPAQ_COMMIT" "$dir"
  echo "Building zpaq $ZPAQ_VERSION"
  clang++ -arch arm64 -arch x86_64 -O3 -Dunix -DNOJIT -pthread -w \
    -o "$BIN/zpaq" "$dir/zpaq.cpp" "$dir/libzpaq.cpp"
  cp "$dir/COPYING" "$LICENSES/zpaq.txt"
  stamp zpaq "$ZPAQ_VERSION"
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

build_7zz
build_zstd
build_libraries
build_bsdtar
build_pigz
build_pbzip2
build_brotli
build_zpaq
build_minizip
