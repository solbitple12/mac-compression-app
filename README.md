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
| `.github/workflows/ci.yml` | Builds and tests `TampCore` on a macOS runner |

## Build and test

Requires Xcode 16 or later on macOS 14 or later.

```sh
swift test --package-path TampCore
```

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

No third-party components are bundled yet. Each one will be listed here with its
license as it is added.
