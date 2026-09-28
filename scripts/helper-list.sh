# The helper tools Tamp bundles and the license texts that ship with them.
# Sourced by build-helpers.sh, bundle-helpers.sh, release.sh and CI, so the
# list lives in one place.

# shellcheck disable=SC2034
TAMP_HELPERS=(7zz bsdtar bsdcat zstd xz pigz pbzip2 brotli zpaq minizip oxipng)

# shellcheck disable=SC2034
TAMP_LICENSES=(
  7-Zip.txt 7-Zip-unRAR.txt
  libarchive.txt
  zstd.txt
  xz.txt
  lz4.txt
  pigz.txt zopfli.txt
  pbzip2.txt
  brotli.txt
  zpaq.txt
  minizip-ng.txt
  oxipng.txt
)
