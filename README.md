# Tamp

A native macOS compression app: archive formats with a six-step speed slider,
media re-encoding, and a "Recommend for me" mode. macOS 14+, Swift and SwiftUI,
distributed as a notarized Developer ID app.

Work in progress: Phases 1 and 2 (all archive formats, advanced options, estimates and
safety checks) are done; images and audio come next. `CLAUDE.md` has notes for working on it.

## Layout

| Path | What it holds |
| --- | --- |
| `App/Tamp/` | The SwiftUI app: main window, drop zone, format picker, speed slider, job list |
| `project.yml` | XcodeGen spec for the app; `xcodegen generate` writes `Tamp.xcodeproj` |
| `TampCore/` | Swift package with all app logic, unit-testable without the app |
| `TampCore/Sources/TampCore/Engines/` | Formats, the speed steps and each engine's step-to-settings mapping |
| `TampCore/Sources/TampCore/Archiving/` | Engine registry, archive detection by first bytes, what a drop does, output names |
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

Tamp patches three of them, with the patches in `scripts/patches`: minizip-ng (store link
targets the Info-ZIP way, skip Mac junk files, read the password from stdin, mark archives
as made on Unix), zpaq (never extract outside the target folder, read the password from stdin with `-key -`)
and pbzip2 (build fix
from Homebrew). None of the components is GPL-only.

7-Zip is built from the unmodified source release above, which also satisfies the
LGPL's source-availability requirement. The unRAR restriction forbids using that code
to recreate the RAR compression algorithm; Tamp only extracts RAR.

Phase 3 (images and audio) has its sources pinned in `scripts/build-helpers.sh` but no
`build_` function yet, so nothing below is built or bundled: mozjpeg 4.1.5 (JPEG, IJG
and BSD 3-clause licenses), oxipng 10.2.1 (PNG, MIT), libwebp 1.6.0 (WebP, BSD 3-clause),
libavif 1.4.2 (AVIF, BSD 2-clause) with SVT-AV1 4.2.0 (AV1 encode, BSD 3-clause Clear plus
the AOM patent license, shared with Phase 4's video) and dav1d 1.5.4 (AV1 decode for the
preview, BSD 2-clause), libjxl 0.12.0 with Highway 1.4.0 (JPEG XL, BSD 3-clause), FLAC
1.5.0 (BSD-style), Opus 1.6.1 (BSD 3-clause), WavPack 5.9.0 (BSD 3-clause), and LAME 4.0
(MP3, GNU LGPL 2.0). This list moves into the table above as each one is actually built.
