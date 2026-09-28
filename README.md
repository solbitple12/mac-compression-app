# Tamp

A native macOS compression app: archive formats with a six-step speed slider,
media re-encoding, and a "Recommend for me" mode. macOS 14+, Swift and SwiftUI,
distributed as a notarized Developer ID app.

Work in progress. Phase 1 is being built in small steps.

## Layout

| Path | What it holds |
| --- | --- |
| `App/Tamp/` | The SwiftUI app: main window, drop zone, format picker, speed slider, job list |
| `project.yml` | XcodeGen spec for the app; `xcodegen generate` writes `Tamp.xcodeproj` |
| `TampCore/` | Swift package with all app logic, unit-testable without the app |
| `TampCore/Sources/TampCore/Engines/` | Formats, the speed steps and each engine's step-to-settings mapping |
| `TampCore/Sources/TampCore/Archiving/` | Engine registry, archive detection by first bytes, what a drop does, output names |
| `TampCore/Sources/TampCore/Settings/` | Last format and speed step, recent output folders |
| `TampCore/Sources/TampCore/Jobs/` | Job queue, smoothed ETA, helper process runner and pipelines, safe temp-file output, error messages |
| `TampCore/Tests/TampCoreTests/Corpus/` | Sample files for the byte-for-byte round-trip tests (text, binary, JPEG, PNG, WAV, MP4) |
| `scripts/make-corpus.sh` | Regenerates the corpus; it's committed, so only needed when it changes |
| `scripts/build-helpers.sh` | Downloads, verifies and builds the bundled helper tools as universal binaries |
| `scripts/bundle-helpers.sh` | Xcode build phase that copies and signs the helpers into the app |
| `scripts/release.sh` | Release build, Developer ID signing, notarization and stapling; `--dry-run` checks without a certificate |
| `docs/signing-and-notarization.md` | One-time setup and release steps for a notarized Developer ID build |
| `.github/workflows/ci.yml` | Builds the helpers, tests `TampCore`, builds, checks and launches the app, and runs the release dry run on macOS runners |

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
Compress. Dropping only archives Tamp can open (ZIP, TAR.ZST, TAR) extracts them
instead. Output goes next to the originals and never replaces an existing file.
Tamp remembers the last format and step.

## Speed steps

Every format shows the same slider: Store, Fastest, Fast, Normal, Good, Best.

| Step | ZIP (7zz Deflate) | TAR.ZST |
| --- | --- | --- |
| Store | -mx0 | plain .tar |
| Fastest | -mx1 | -1 |
| Fast | -mx3 | -3 |
| Normal | -mx5 | -9 |
| Good | -mx7 | -15 --long=27 |
| Best | -mx9 | --ultra -22 --long=27 |

The zstd window is capped at 27 (128 MiB) so any stock zstd can decompress the output.
Memory figures in the slider hint are approximations until the Phase 2a benchmark measures them.

## Known issues

- ZIP extraction fails on a symlink whose target starts with `../`, even when it
  stays inside the archive: 7-Zip rejects such links as unsafe. TAR.ZST keeps them.
- If two copies of Tamp run at once, the one launched second can remove the other's
  unfinished output while cleaning up after crashes.

## Bundled components and licenses

`scripts/build-helpers.sh` copies each component's license text into
`build/helpers/licenses`. The app bundles those files in `Contents/Resources/Licenses`.

| Component | Version | Used for | License |
| --- | --- | --- | --- |
| [7-Zip](https://github.com/ip7z/7zip) (`7zz`) | 26.03 | ZIP now; 7Z and RAR extraction in Phase 2a | GNU LGPL 2.1, some code BSD 3-clause, unRAR code under the unRAR license restriction |
| [zstd](https://github.com/facebook/zstd) (`zstd`) | 1.5.7 | TAR.ZST compression and extraction | BSD 3-clause (dual-licensed with GPLv2; Tamp uses it under BSD) |
| [libarchive](https://github.com/libarchive/libarchive) (`bsdtar`) | 3.8.9 | Writing and reading the tar stream | BSD 2-clause |

7-Zip is built from the unmodified source release above, which also satisfies the
LGPL's source-availability requirement. The unRAR restriction forbids using that code
to recreate the RAR compression algorithm; Tamp only extracts RAR.
