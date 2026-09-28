# The helper tools Tamp bundles and the license texts that ship with them.
# Sourced by build-helpers.sh, bundle-helpers.sh, release.sh and CI, so the
# list lives in one place.

# The app's own helpers. build-helpers.sh also builds wvunpack (for the test
# suite's independent WavPack round-trip check) and SvtAv1EncApp (a side effect
# of SVT-AV1's own CMake; Tamp links its library into a future avifenc instead
# of shelling out to this CLI). Neither is bundled into the app.
# shellcheck disable=SC2034
TAMP_HELPERS=(7zz bsdtar bsdcat zstd xz pigz pbzip2 brotli zpaq minizip oxipng cjpeg djpeg jpegtran cwebp flac wavpack lame cjxl djxl)

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
  mozjpeg.txt
  libwebp.txt
  flac.txt
  wavpack.txt
  lame.txt
  highway.txt
  libjxl.txt
)
