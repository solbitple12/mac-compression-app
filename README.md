# Tamp

A native macOS compression app: archive formats with a six-step speed slider,
media re-encoding, and a "Recommend for me" mode. macOS 14+, Swift and SwiftUI,
distributed as a notarized Developer ID app.

Work in progress. Phase 1 is being built in small steps.

## Layout

| Path | What it holds |
| --- | --- |
| `TampCore/` | Swift package with all app logic, unit-testable without the app |
| `TampCore/Sources/TampCore/Engines/` | Formats, the speed steps and each engine's step-to-settings mapping |
| `TampCore/Sources/TampCore/Jobs/` | Job queue, smoothed ETA, helper process runner, safe temp-file output, error messages |
| `scripts/build-helpers.sh` | Downloads, verifies and builds the bundled helper tools as universal binaries |
| `.github/workflows/ci.yml` | Builds the helpers, then builds and tests `TampCore` on a macOS runner |

## Build and test

Requires Xcode 16 or later on macOS 14 or later.

```sh
scripts/build-helpers.sh
TAMP_HELPERS_DIR="$PWD/build/helpers/bin" swift test --package-path TampCore
```

The engine tests run the real helpers and are skipped when `TAMP_HELPERS_DIR` doesn't
point at them. CI sets `TAMP_REQUIRE_HELPERS=1`, which turns that skip into a failure.

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

## Bundled components and licenses

`scripts/build-helpers.sh` copies each component's license text into
`build/helpers/licenses`. The app bundles those files next to the helpers.

| Component | Version | Used for | License |
| --- | --- | --- | --- |
| [7-Zip](https://github.com/ip7z/7zip) (`7zz`) | 26.03 | ZIP now; 7Z and RAR extraction in Phase 2a | GNU LGPL 2.1, some code BSD 3-clause, unRAR code under the unRAR license restriction |

7-Zip is built from the unmodified source release above, which also satisfies the
LGPL's source-availability requirement. The unRAR restriction forbids using that code
to recreate the RAR compression algorithm; Tamp only extracts RAR.
