# Tamp: notes for Claude Code

Tamp is a native macOS 14+ compression app in Swift and SwiftUI, similar to Keka. It has
archive formats behind a six-step speed slider (Store, Fastest, Fast, Normal, Good, Best),
media re-encoding, and a "Recommend for me" mode. It ships as a notarized Developer ID app
outside the App Store. README.md describes what works today; this file is how to work on it.

## Working with the owner

- The approved architecture and build plan is the Claude Doc "Tamp architecture plan"
  (https://claude.ai/code/artifact/700540f8-60c9-4ced-8998-53d7db173952). Follow it. If
  something in it turns out wrong, say so and propose a change; don't change course silently.
- Build phase by phase. At the end of each phase, stop with a short summary of what works
  and the known issues, and wait for review before starting the next one. Inside a phase,
  work in small chunks and commit and push each one, because the owner's usage is limited.
- Ask before reading websites. Prefer pinned sources (tags, checksums) already in
  `scripts/build-helpers.sh`.
- Never ask for credentials (Apple ID, certificates, tokens). Signing is the owner's step;
  see `docs/signing-and-notarization.md`.
- The owner wants plain, short updates: what changed, what's needed from them, nothing more.

## Licensing rules

- No GPL-only components, in the app or in its helpers. LGPL is fine as a separate dynamic
  library or helper process (FFmpeg in Phase 4 must be an LGPL build: no x264, x265 or
  other `--enable-gpl` parts). Check every new component's licence before adding it and
  list it in README's "Bundled components and licenses".
- For that reason Tamp uses libarchive's own lz4 and lzip filters rather than the GPL
  tools, VideoToolbox rather than x264 and x265, and has no pngquant.

## Layout

| Path | What it holds |
| --- | --- |
| `TampCore/` | Swift package with all logic, testable without the app |
| `TampCore/Sources/TampCore/Engines/` | Formats, speed steps, per-engine step-to-settings mappings, one engine per tool |
| `TampCore/Sources/TampCore/Archiving/` | Engine registry, detection, what a drop does, verify, compress/extract jobs |
| `TampCore/Sources/TampCore/Jobs/` | Job queue, ETA, process runner and pipelines, JobControl (pause), SafeOutput |
| `TampCore/Sources/TampCore/Estimation/` | Input scan, Estimator (probes), thread scaling, history |
| `TampCore/Sources/TampCore/Safety/` | System resource sampling, ResourceMonitor, pre-flight checks |
| `TampCore/Sources/TampCore/Settings/` | Saved choices, recent output folders, unfinished batch |
| `TampCore/Sources/TampBench/` | `tamp-bench`: time, size and peak RAM of every format and step |
| `App/Tamp/` | SwiftUI app; `AppModel` connects TampCore to the views |
| `App/TampUITests/` | XCUITest smoke test (compress and extract through the window) |
| `project.yml` | XcodeGen spec; `Tamp.xcodeproj` is generated, not committed |
| `scripts/` | Helper build, bundling, release, corpus and bench-set scripts; `patches/` for helper patches |

Engines that shell out run bundled helpers (7zz, bsdtar/bsdcat, zstd, xz, pigz, pbzip2,
brotli, zpaq, minizip) from `Contents/Helpers`, always with argument arrays, never a shell,
and passwords on stdin. Apple Archive runs in-process; disk images use the system's hdiutil.
Every job writes to a hidden temp file in the destination folder and renames into place
only when complete, with a rename that refuses to overwrite (`SafeOutput`).

## Build and test locally

Requires Xcode 16 or later on macOS 14 or later.

```sh
scripts/build-helpers.sh                      # once; output in build/helpers/bin
TAMP_HELPERS_DIR="$PWD/build/helpers/bin" swift test --package-path TampCore
brew install xcodegen && xcodegen generate    # then build the Tamp scheme in Xcode
```

- Engine tests need the helpers and are skipped without `TAMP_HELPERS_DIR`; CI sets
  `TAMP_REQUIRE_HELPERS=1`, which turns the skip into a failure. Run them locally before
  pushing.
- Run one test class with `swift test --package-path TampCore --filter EstimatorTests`.
- Benchmark: `scripts/make-bench-set.sh build/bench-set`, then
  `TAMP_HELPERS_DIR=$PWD/build/helpers/bin swift run --package-path TampCore -c release tamp-bench --input build/bench-set --markdown build/bench.md`.
- The package uses Swift 5 language mode (tools 5.10) and the app `SWIFT_VERSION` 5.0.

## CI and Mac minutes

The owner pays for GitHub Actions macOS minutes. Now that builds can run locally, test
locally first and use CI as the final check.

- `.github/workflows/ci.yml`: one "Build and test" job per pull request push (helpers from
  cache, TampCore tests, app build, bundle check, launch). A newer push cancels the older
  run. Jobs have timeouts.
- The UI smoke test and release dry run run on pushes to `main`, or on a pull request with
  the `full-ci` label. `benchmark.yml` runs only by hand or with the `benchmark` label.
- Nothing runs on a schedule; keep it that way. Batch fixes into one push.

## Conventions

- Code reads like the code around it: doc comments on types and non-obvious members,
  plain-language user-facing strings, errors as `TampError` with messages people understand.
- Every engine: argument arrays only; names checked unique; cancellation stops helpers with
  SIGTERM, then SIGKILL after 2 s; partial output removed; inputs never modified.
- New settings go through `SettingsStore` with tolerant decoding, so older saved settings still load.
- Tests: byte-for-byte round trips on the corpus, cancel mid-job, and simulated failures
  through protocols (see `SafetyTests` for the resource monitor).
- Commits: clear messages; push to the working branch; never force-push someone else's
  branch. Pull requests describe Before and After in plain language.

## Where things stand (end of Phase 2, 2026-09-28)

- All of Phase 1 and Phase 2 is on branch `claude/project-thread-mtcopg`, pull request #1.
  Phase 1: skeleton, ZIP and TAR.ZST, job queue, safe stop, window, CI, release dry run.
  Phase 2a: all archive formats and opening RAR/CAB/ISO/CPIO, benchmark. 2b: Apple Archive,
  disk images, advanced options, passwords, split archives, verify, move to Trash. 2c:
  estimates, pre-flight memory/disk/long-job checks, resource monitor with pause and safe
  stop, resumable batches.
- Known issues are listed in README's "Known issues". Also: only the owner's Mac can check
  Finder drag, the Choose panel, quitting while a job runs, and a real notarized release.
  The Phase 2c UI (hint, sheets, pause dialog, gauge) hasn't been through the UI smoke test
  yet; add the `full-ci` label once to check it.

## Next phases (stop for review after each)

3. Images and audio: mozjpeg, oxipng, WebP, AVIF, HEIC, JPEG XL (including lossless JPEG
   to JXL, verified by rebuilding the JPEG); FLAC, ALAC, WavPack, AAC, Opus, MP3; batch
   folders with per-file and batch ETA, savings per file, metadata toggles, before/after preview.
4. Video: FFmpeg LGPL helper, VideoToolbox H.264 and HEVC, SVT-AV1, VP9; presets and advanced
   controls; stream and metadata passthrough; clip preview; encoder RAM estimates.
5. Recommender: scan, sample, trial runs, rules, the recommendation card; it drops any
   candidate that would trip the memory or disk checks.
6. Finder integration and polish: Dock drop, Services and Quick Actions, Preferences
   (including the safety thresholds and long-job limit), presets, notifications, shortcuts,
   VoiceOver audit, full signing and notarization guide.
