# Tamp

A native macOS compression app: archive formats with a six-step speed slider,
media re-encoding, and a "Recommend for me" mode. macOS 14+, Swift and SwiftUI,
distributed as a notarized Developer ID app.

Work in progress: Phases 1 through 3 (all archive formats, advanced options, estimates
and safety checks, plus images and audio) are done. Phase 4 (video codecs through a
bundled FFmpeg, RAM estimates for every media kind, a per-item batch panel with the same
pre-flight memory/disk checks and paused-job restart archive jobs get, remembered
settings per kind, and video clip preview) is done too. Phase 5 ("Recommend for me":
scan, sample, trial runs against the real Estimator, rules, and a recommendation card)
is built as well. A target-bitrate control for the media batch panel's custom quality
slider, and Phase 6's Finder integration and polish, are what's left.
`CLAUDE.md` has notes for working on it.

## Layout

| Path | What it holds |
| --- | --- |
| `App/Tamp/` | The SwiftUI app: main window, drop zone, archive format picker and speed slider, the per-item media batch panel (Phase 4), the recommendation card (Phase 5), job list |
| `TampCore/Sources/TampCore/Recommender/` | Scan (file kind by magic bytes), Sample (entropy), Trial (real Estimator probes) and Rules (profile+goal to recommendation) - Phase 5 |
| `project.yml` | XcodeGen spec for the app; `xcodegen generate` writes `Tamp.xcodeproj` |
| `TampCore/` | Swift package with all app logic, unit-testable without the app |
| `TampCore/Sources/TampCore/Engines/` | Formats, the speed steps and each engine's step-to-settings mapping, for archives and (Phase 3/4) images, audio and video |
| `TampCore/Sources/TampCore/Archiving/` | Engine registry, archive detection by first bytes, what a drop does, output names |
| `TampCore/Sources/TampCore/Media/` | Image, audio and video engine registry (Phase 3/4) |
| `TampCore/Sources/TampCore/Estimation/` | Input scan, time/size/memory estimates from short probes, thread scaling, local history |
| `TampCore/Sources/TampCore/Safety/` | Memory, swap and disk sampling, the resource monitor that pauses and stops jobs, pre-flight checks |
| `TampCore/Sources/TampCore/Settings/` | Last format and speed step, recent output folders |
| `TampCore/Sources/TampCore/Jobs/` | Job queue, smoothed ETA, helper process runner and pipelines, safe temp-file output, error messages |
| `TampCore/Tests/TampCoreTests/Corpus/` | Sample files for the byte-for-byte round-trip tests (text, binary, JPEG, PNG, WAV, MP4) |
| `scripts/make-corpus.sh` | Regenerates the corpus; it's committed, so only needed when it changes |
| `scripts/build-helpers.sh` | Downloads, verifies and builds the bundled helper tools as universal binaries |
| `scripts/bundle-helpers.sh` | Xcode build phase that copies and signs the helpers into the app |
| `scripts/release.sh` | Release build, Developer ID signing, notarization and stapling; `--dry-run` checks without a certificate |
| `docs/signing-and-notarization.md` | One-time setup and release steps for a notarized Developer ID build |
| `.github/workflows/ci.yml` | On macOS runners: builds the helpers, tests `TampCore`, builds, checks and launches the app; the UI smoke test and release dry run run on `main` or with the `full-ci` label |

## Build and test

Requires Xcode 16 or later on macOS 14 or later.

```sh
scripts/build-helpers.sh
TAMP_HELPERS_DIR="$PWD/build/helpers/bin" swift test --package-path TampCore
```

The engine tests run the real helpers and are skipped when `TAMP_HELPERS_DIR` doesn't
point at them. CI sets `TAMP_REQUIRE_HELPERS=1`, which turns that skip into a failure.

To build and run the app:

```sh
brew install xcodegen
scripts/build-helpers.sh
xcodegen generate
open Tamp.xcodeproj
```

The build copies the helpers into `Tamp.app/Contents/Helpers` and signs the app for
this Mac only. To make a build others can download, see
[Signing and notarizing Tamp](docs/signing-and-notarization.md);
`scripts/release.sh --dry-run` runs its checks without a certificate.

Drop files or folders on the window, pick a format and a speed step, and press
Compress. Dropping only archives Tamp can open extracts them instead: everything it
writes, plus RAR, CAB, ISO and CPIO, and lone compressed files such as `dump.sql.gz`,
which become the file they hold. Any part of a split archive (`Photos.7z.002`,
`Film.part2.rar`) opens the whole archive from its first part, once. A protected
archive asks for its password. A file counts as an archive only when its name and
its first bytes agree, so a `.docx` (a ZIP inside) is compressed, not taken apart. Output goes next to the originals and never replaces an existing file.
Tamp remembers the last format, step and Advanced settings, but never a password.

The Advanced panel under the slider holds a password (7Z, ZIP, ZPAQ, Disk Image;
sent to each tool on stdin, never as an argument), splitting 7Z and ZIP into parts,
leaving out Mac-only files, checking the archive after compressing (it's opened again
into a hidden folder and compared with the originals byte for byte), and moving the
originals to the Trash afterwards, which asks first and happens only once the archive
is written and checked. It also shows the tuning settings the chosen format has:
7Z dictionary, word size, solid blocks, BCJ2 filter and file name encryption; ZIP
encryption (AES-256 or ZipCrypto); threads; the TAR.ZST long-range window (at most
128 MB); the TAR.XZ block size; the ZPAQ block size; and Brotli's 256 MB window.

Dropping only images, only audio, only video, or a mix of those three kinds shows each
file in its own row instead of the single archive-wide picker, with its own format,
quality (or Lossless, where the format allows it) and metadata (Keep, Remove Location,
Remove All) controls; starting the batch runs each item as its own independent job next
to its original. Anything else dropped — a folder, an archive, or a mix that includes a
non-media file — still bundles into one archive the usual way. The same pre-flight
memory and disk checks archive jobs get cover a media batch too; a paused video item can
restart one step down, though image and audio's memory estimate doesn't change with
step, so there's nothing lower to offer those.

"Recommend for Me", beside a plain archive batch's Compress button, asks what matters
most (Fastest, Smallest, Lossless only, Opens anywhere) the first time and remembers the
answer; it then scans the dropped files, samples their compressibility, runs the real
archivers on a trial slice of the input, and shows a card with a recommended format and
step, its estimate, a plain-language reason, and an alternative when there is one. Accept
sets the format picker and slider, which can still be nudged afterward. Any candidate
whose memory or disk estimate would trip the pre-flight checks is dropped before ranking,
so the recommendation never needs its own safety warning.

## Speed steps

Every format shows the same slider: Store, Fastest, Fast, Normal, Good, Best.

| Step | ZIP (Deflate) | 7Z (LZMA2) | TAR.GZ (pigz) | TAR.BZ2 (pbzip2) | TAR.XZ | TAR.ZST | TAR.LZ4 | TAR.LZ | TAR.BR | ZPAQ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Store | -mx0 | -mx0 | plain .tar | plain .tar | plain .tar | plain .tar | plain .tar | plain .tar | plain .tar | -m0 |
| Fastest | -mx1 | -mx1 | -1 | -1 | -0 | -1 | 1 | 0 | -q 1 | -m1 |
| Fast | -mx5 -mfb8 | -mx3 | -3 | -3 | -2 | -3 | 3 | 3 | -q 4 | -m2 |
| Normal | -mx5 | -mx5 | -6 | -6 | -6 | -9 | 6 | 6 | -q 6 | -m3 |
| Good | -mx7 | -mx7 | -9 | -8 | -8 | -15 --long=27 | 8 | 8 | -q 9 | -m4 |
| Best | -mx9 | -mx9 | -11 (Zopfli) | -9 | -9e | --ultra -22 --long=27 | 9 | 9 | -q 11 | -m5 |

| Step | Apple Archive | Disk Image (hdiutil) |
| --- | --- | --- |
| Store | no compression | UDRO |
| Fastest | LZ4, 4 MB blocks | UDZO, zlib level 1 |
| Fast | LZFSE, 4 MB blocks | ULFO (LZFSE) |
| Normal | zlib, 4 MB blocks | UDZO, zlib level 6 |
| Good | LZMA, 4 MB blocks | UDZO, zlib level 9 |
| Best | LZMA, 16 MB blocks | ULMO (LZMA) |

7-Zip's Deflate writes the same file at levels 1 to 4, so ZIP's Fast is level 5 with
short matches (8 "fast bytes"): halfway between Fastest and Normal in size and time on
the benchmark set. TAR.BZ2's levels only change bzip2's block size, so Normal to Best
differ by under 1%. Apple Archive goes through Apple's AppleArchive framework and keeps
everything macOS stores about a file; it opens only on macOS 11 and later. Disk images
open only on a Mac; Tamp opens one by mounting it read-only out of sight and copying
its contents out.

Plain TAR only bundles, so its slider stays on Store. TAR.LZ4 and TAR.LZ go through
libarchive's own filters, whose levels stop at 9. The zstd window is capped at 27
(128 MiB) so any stock zstd can decompress the output.

ZIP and 7Z also offer other methods in the Method menu. ZIP has Deflate64, BZip2 and
LZMA through 7zz, and Zstandard (levels 1, 3, 9, 15, 19) through minizip, since official
7-Zip reads zstd in a ZIP but can't write it. 7Z has LZMA, PPMd, BZip2 and Deflate.
Anything but Deflate in a ZIP needs 7-Zip or similar on the other end, and the hint says so.

Memory figures in the slider hint are estimates. `tamp-bench` measures the real ones
(see Benchmark below).

## Benchmark

`scripts/make-bench-set.sh` writes a seeded 22 MB set (prose, CSV, JSON logs, binary
records and the test corpus). `tamp-bench` compresses and extracts it with every format,
step and method, and at several thread counts, in a child process per run, and reports
ratio, time, speed, the largest helper's peak memory next to the hint's estimate, and
adjacent steps that come out nearly identical. The Benchmark workflow runs it on a
GitHub macOS runner by hand, or when the pull request is labeled `benchmark`.

```sh
scripts/make-bench-set.sh build/bench-set
TAMP_HELPERS_DIR=$PWD/build/helpers/bin swift run --package-path TampCore -c release \
  tamp-bench --input build/bench-set --markdown build/bench.md
```

## Estimates and safety

- Next to the slider, Tamp shows time, size and memory for the current settings, such as
  "Best: ~4 min · ~350 MB · uses ~2.1 GB RAM". It gets them by running the real engine for
  at most 3 seconds on slices of the largest files (and on a few small files, for the cost
  of each file), then scaling up by size, file count and a per-format thread curve from
  the benchmark. Ranges appear when the samples disagree. Until the probe finishes, a
  figure from earlier jobs is shown, marked "rough".
- Each finished job is recorded in `~/Library/Application Support/Tamp/History.json`.
  Later estimates for the same format and step are multiplied by the median of actual
  over estimated time for the last 20 runs. Nothing leaves the Mac.
- Before starting, Tamp asks when the job may need more than 70% of free memory (offering
  a lower step or fewer threads), when the archive may not fit on the disk with 1 GB to
  spare, and when it will take more than 30 minutes (offering a faster step).
- While a job runs, Tamp samples its helpers' memory, the system's memory pressure, swap
  and free disk space every second. It warns with a yellow banner, and when things turn
  critical it pauses the job (SIGSTOP) and asks: Resume, Stop Safely, or Restart with a
  lower step and fewer threads. Unanswered and still critical after 60 seconds, it stops
  the job safely on its own. Pausing keeps the memory a job holds; only stopping frees it.
- Stopping one archive while extracting several stops the batch; the archives not yet
  extracted can be resumed from the Jobs list, even after quitting Tamp.

## Known issues

- ZIP and 7Z extraction fail on a symlink whose target starts with `../`, even when it
  stays inside the archive: 7-Zip rejects such links as unsafe. The TAR formats keep them.
- ZPAQ doesn't store symbolic links.
- Disk images keep .DS_Store and other Mac-only files: hdiutil copies everything.
- Apple Archive can't take a password yet.
- Estimates cover compressing only; extracting shows a live ETA once it starts.
- Only one job runs at a time, so the memory checks hold.
- The thresholds (70%, 1 GB, 30 minutes, 60 seconds) are fixed until Preferences arrive in Phase 6.
- ZIP with Zstandard can't be split into parts (minizip writes it, not 7-Zip).
- If two copies of Tamp run at once, the one launched second can remove the other's
  unfinished output while cleaning up after crashes.
- AVIF has no true lossless mode: SVT-AV1 can only encode 4:2:0 chroma, which avifenc's
  own `--lossless` refuses to run at all, so "lossless" AVIF is really the best lossy
  quality instead.
- Nothing in Tamp can open or preview an AV1 or VP9 file it just wrote (no bundled
  decoder for either); AVFoundation may or may not decode them depending on the OS
  version, same as AVIF.
- VideoToolbox's constant-quality mode only works on Apple Silicon; on Intel, H.264 and
  HEVC fall back to a target bitrate instead, with no real per-step benchmark behind it yet.
- A media batch's pre-flight memory check uses `ImageMemoryHint`, `AudioMemoryHint` and
  `VideoMemoryHint`'s starting-point formulas, same as the slider hint's own estimates;
  a source Tamp can't read its dimensions from falls back to an HD-sized guess.
- Dropping a mix of media and non-media items (say, a photo alongside a folder) bundles
  everything into one archive rather than splitting it into a media batch plus an
  archive; only a drop that's entirely image, audio and video files gets the per-item panel.

## Bundled components and licenses

`scripts/build-helpers.sh` copies each component's license text into
`build/helpers/licenses`. The app bundles those files in `Contents/Resources/Licenses`.

| Component | Version | Used for | License |
| --- | --- | --- | --- |
| [7-Zip](https://github.com/ip7z/7zip) (`7zz`) | 26.03 | ZIP, 7Z; extracting RAR, and CAB and ISO that bsdtar can't read | GNU LGPL 2.1, some code BSD 3-clause, unRAR code under the unRAR license restriction |
| [libarchive](https://github.com/libarchive/libarchive) (`bsdtar`, `bsdcat`) | 3.8.9 | Writing and reading tar streams, the lz4 and lzip filters, CAB, ISO and CPIO, lone compressed files | BSD 2-clause |
| [zstd](https://github.com/facebook/zstd) (`zstd`, libzstd) | 1.5.7 | TAR.ZST; zstd in libarchive and minizip | BSD 3-clause (dual-licensed with GPLv2; Tamp uses it under BSD) |
| [XZ Utils](https://tukaani.org/xz/) (`xz`, liblzma) | 5.8.4 | TAR.XZ; lzip and xz in libarchive | 0BSD |
| [LZ4](https://github.com/lz4/lz4) (liblz4 only) | 1.10.0 | lz4 in libarchive | BSD 2-clause (the GPL command-line tool isn't used) |
| [pigz](https://zlib.net/pigz/) with [Zopfli](https://github.com/google/zopfli) | 2.8 | TAR.GZ | zlib license; Zopfli Apache 2.0 |
| [pbzip2](https://launchpad.net/pbzip2) | 1.1.13 | TAR.BZ2 | BSD-style (pbzip2 license); links macOS's libbz2 |
| [Brotli](https://github.com/google/brotli) (`brotli`) | 1.2.0 | TAR.BR | MIT |
| [zpaq](https://github.com/zpaq/zpaq) (`zpaq`) | 7.15 | ZPAQ | Public domain (Unlicense); its libdivsufsort part is MIT |
| [minizip-ng](https://github.com/zlib-ng/minizip-ng) (`minizip`) | 4.2.2 | Writing Zstandard inside ZIP | zlib license |
| [oxipng](https://github.com/oxipng/oxipng) (`oxipng`) | 10.2.1 | PNG | MIT |
| [mozjpeg](https://github.com/mozilla/mozjpeg) (`cjpeg`, `djpeg`, `jpegtran`) | 4.1.5 | JPEG | IJG license, BSD 3-clause, zlib license |
| [libwebp](https://github.com/webmproject/libwebp) (`cwebp`) | 1.6.0 | WebP | BSD 3-clause; statically links mozjpeg's own libjpeg (see above) and [libpng](https://github.com/pnggroup/libpng) 1.6.58 (libpng license) to read source images |
| Apple's ImageIO framework | — | HEIC | System framework; nothing bundled |
| [FLAC](https://github.com/xiph/flac) (`flac`) | 1.5.0 | FLAC | BSD-style (Xiph) |
| [WavPack](https://github.com/dbry/WavPack) (`wavpack`) | 5.9.0 | WavPack | BSD 3-clause |
| Apple's AVFoundation/AudioToolbox | — | AAC, ALAC | System frameworks; nothing bundled |
| [LAME](https://lame.sourceforge.io) (`lame`) | 4.0 | MP3 | GNU LGPL 2.0 |
| [libjxl](https://github.com/libjxl/libjxl) (`cjxl`, `djxl`) | 0.12.0 | JPEG XL | BSD 3-clause; pulls in [Highway](https://github.com/google/highway) (Apache-2.0/BSD 3-clause) and [skcms](https://github.com/google/skcms) (BSD 3-clause) |
| [SVT-AV1](https://github.com/AOMediaCodec/SVT-AV1) | 4.2.0 | AVIF's AV1 encoder (statically linked into `avifenc`); Phase 4's video too | BSD 3-clause Clear plus the AOM patent license |
| [libavif](https://github.com/AOMediaCodec/libavif) (`avifenc`) | 1.4.2 | AVIF, encode only (no bundled decoder yet) | BSD 2-clause; its own CMake fetches and statically links zlib, libpng and libjpeg-turbo to read source images, each zlib/BSD/IJG-licensed — their exact license texts still need capturing here before a real release |
| [opus-tools](https://github.com/xiph/opus-tools) (`opusenc`) | 0.2 | Opus | BSD 2-clause; statically links [libopus](https://github.com/xiph/opus) (BSD 3-clause), [libogg](https://github.com/xiph/ogg) (BSD-style) and [libopusenc](https://github.com/xiph/libopusenc) (BSD 3-clause) |
| Apple's VideoToolbox | — | H.264, HEVC video (through the FFmpeg helper below) | System framework; nothing bundled |
| [libvpx](https://github.com/webmproject/libvpx) | 1.17.0 | VP9 video (through the FFmpeg helper below); VP8 is built but disabled, nothing in Tamp writes it | BSD 3-clause plus a patent grant |
| [FFmpeg](https://ffmpeg.org) (`ffmpeg`) | n9.0.2 | Video re-encoding: opens the source, copies every stream Tamp isn't re-encoding, and drives VideoToolbox, SVT-AV1 or libvpx for the one it is | GNU LGPL 2.1+; built with `--disable-gpl --disable-nonfree`, so x264, x265 and fdk-aac are never linked in; statically links SVT-AV1, libvpx and (VP9's audio track only, see below) libopus, all already in this table |

Tamp patches three of them, with the patches in `scripts/patches`: minizip-ng (store link
targets the Info-ZIP way, skip Mac junk files, read the password from stdin, mark archives
as made on Unix), zpaq (never extract outside the target folder, read the password from stdin with `-key -`)
and pbzip2 (build fix
from Homebrew). None of the components is GPL-only.

7-Zip is built from the unmodified source release above, which also satisfies the
LGPL's source-availability requirement. The unRAR restriction forbids using that code
to recreate the RAR compression algorithm; Tamp only extracts RAR.

Phase 3 (images and audio) is now fully built and bundled: oxipng, mozjpeg,
libwebp, HEIC, FLAC, WavPack, AAC, ALAC, LAME, libjxl, SVT-AV1, libavif and
opus-tools, all in the table above (or, for AAC/ALAC/HEIC, need nothing to
bundle). JPEG XL's lossless JPEG rewrap verifies itself: after encoding, Tamp
decodes the JXL back to a JPEG with djxl and compares it byte for byte against
the original before calling the job done. AVIF is encode only for now: dav1d
(AV1 decode, for the before/after preview) isn't built, so nothing in Tamp can
open or preview an AVIF it just wrote. opusenc needed libogg, libopusenc and
opusfile besides libopus itself, with libopusenc and opus-tools needing a real
autotools bootstrap (no vendored `configure` in their git history, unlike every
other Phase 3 source) — the only components of the app that aren't built with
CMake, a vendored `configure`, or Cargo.

Phase 4 (video) is built too: H.264 and HEVC through VideoToolbox, AV1 through
SVT-AV1 (the same build AVIF uses) and VP9 through libvpx, all driven by the
FFmpeg helper above. Every format copies audio, subtitle and metadata streams
unchanged rather than re-encoding them, except VP9: its container, WebM, has
no support for AAC (the audio codec Tamp's own source videos use for testing),
so VP9Engine re-encodes just the audio track to Opus instead of copying it —
the one place a video job needs an audio encoder at all. AVIF's `--lossless`
turned out to be a similar dead end discovered along the way: SVT-AV1 only
encodes 4:2:0 chroma, but avifenc's own `--lossless` refuses anything but 4:4:4
or 4:0:0, so AVIF "lossless" now means the best lossy quality (`-q 100`)
instead, not a true pixel-for-pixel round trip the way JPEG XL's lossless JPEG
path is.

The per-item media batch panel followed: `MediaPlanner` classifies a drop by
extension into image, audio or video (independent of `ArchivePlanner`'s
archive/extract detection), `MediaJobs` puts each item on the same `JobQueue`
archives use but one at a time rather than bundled, and `ImageMemoryHint` and
`AudioMemoryHint` fill out the RAM-estimate formulas alongside `VideoMemoryHint`
so `AppModel`'s pre-flight memory and disk checks (previously archive-only)
cover a media batch too, with its own paused-job restart for video (the only
kind whose memory estimate changes with step).

A media item's format, quality and metadata are now remembered per kind
(`MediaChoice`, the same purpose `ArchiveChoice` serves for archives) and
reused as the default for the next dropped file of that kind, saved back on
every edit in the batch panel. Each row's quality picker also has a Custom
choice, a 0-100 constant-quality slider on the same scale the hint text and
engines already use.

A video item's row has a Preview button: it trims and re-encodes a short
middle clip with the row's current settings (`VideoPreview` in `TampCore`)
and opens it beside the original in two side-by-side players, so a quality
or size difference is visible before running the real job. Only video has
one; TampCore's `VideoPreview` has no image or audio counterpart yet.

Phase 5 (the recommender) is built on top of all this: `RecommenderScan`
classifies a dropped file by magic bytes (reusing `ArchiveDetector` for
archives, adding JPEG/PNG/MP4 signatures) and falls back to its extension,
so a renamed file is still recognized; its entropy sampler reads up to 16
evenly spaced 64 KB blocks per file to tell already-dense (compressed or
encrypted) content from text-like data worth compressing.
`RecommenderRules.recommend(profile:goal:)` is the pure (profile, goal) to
recommendation function the architecture plan calls for - "must open
anywhere" forces ZIP outright, dense content recommends Store instead of
recompressing, "smallest" picks ZPAQ's Best step (with zstd as a much-faster
alternative when the content is text-heavy), and "lossless only" and
"fastest" get their own picks. `Recommender.recommend(...)` ties it together
with a real Trial stage: it runs the actual `Estimator` on the rules' pick
(and its alternative), dropping either one whose RAM or disk estimate would
trip the same pre-flight checks archive and media jobs already get, and
promoting the alternative to primary if the top pick doesn't fit. Two things
the plan describes aren't built yet: a genuine media-re-encode suggestion
for a mostly-media batch (falls back to Store instead), and a true split
plan for a mixed batch of dense and compressible content (flagged by
`BatchProfile.isMixed` but still one blanket recommendation).

Still ahead: the media batch panel's Custom quality has no matching
target-bitrate control; and the benchmark pass that Phase 2a ran for archive
formats hasn't reached the speed-step and RAM-estimate mappings marked as
starting points throughout Phase 3 and 4, to replace them with real
measurements. Phase 6 (Finder integration and polish) hasn't started.
