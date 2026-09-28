#!/usr/bin/env bash
# Builds a Release Tamp.app and checks it the way notarization will.
#
#   scripts/release.sh --dry-run   sign for this Mac only and run every check that
#                                  doesn't need a certificate (CI runs this)
#   scripts/release.sh             sign with Developer ID, notarize, staple, verify
#
# A real run reads these from the environment (see docs/signing-and-notarization.md):
#   TAMP_SIGN_IDENTITY    "Developer ID Application: Your Name (TEAMID)"
#   TAMP_TEAM_ID          your 10-character Team ID
#   TAMP_NOTARY_PROFILE   a keychain profile saved with `xcrun notarytool store-credentials`
#
# Output: build/release/Tamp.app and build/release/Tamp-<version>.zip
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
DERIVED="$OUT/DerivedData"
MIN_MACOS=14.0

dry_run=0
case "${1:-}" in
  --dry-run) dry_run=1 ;;
  "") ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

fail() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

signing_args=()
if [ "$dry_run" = 0 ]; then
  : "${TAMP_SIGN_IDENTITY:?set TAMP_SIGN_IDENTITY to your Developer ID Application identity}"
  : "${TAMP_TEAM_ID:?set TAMP_TEAM_ID to your Team ID}"
  : "${TAMP_NOTARY_PROFILE:?set TAMP_NOTARY_PROFILE to the notarytool keychain profile name}"
  # Output is captured before grepping throughout: with pipefail, `grep -q` quitting
  # early can make the writer fail and turn a match into a miss.
  identities="$(security find-identity -v -p codesigning)"
  grep -qF "$TAMP_SIGN_IDENTITY" <<<"$identities" \
    || fail "no valid signing identity named \"$TAMP_SIGN_IDENTITY\" in the keychain"
  signing_args=(
    CODE_SIGN_IDENTITY="$TAMP_SIGN_IDENTITY"
    DEVELOPMENT_TEAM="$TAMP_TEAM_ID"
    OTHER_CODE_SIGN_FLAGS=--timestamp
  )
fi

command -v xcodegen >/dev/null || fail "XcodeGen is missing. Install it with: brew install xcodegen"

step "Building the helpers"
"$ROOT/scripts/build-helpers.sh"

step "Building Tamp (Release)"
rm -rf "$OUT"
mkdir -p "$OUT"
(cd "$ROOT" && xcodegen generate --quiet)
xcodebuild -project "$ROOT/Tamp.xcodeproj" -scheme Tamp -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  ${signing_args[@]+"${signing_args[@]}"} build -quiet
ditto "$DERIVED/Build/Products/Release/Tamp.app" "$OUT/Tamp.app"
APP="$OUT/Tamp.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

step "Checking the bundle"
executables=("$APP/Contents/MacOS/Tamp" "$APP/Contents/Helpers/7zz" "$APP/Contents/Helpers/bsdtar" "$APP/Contents/Helpers/zstd")
for exe in "${executables[@]}"; do
  name="${exe#"$APP/"}"
  [ -x "$exe" ] || fail "$name is missing"

  archs="$(lipo -archs "$exe")"
  for arch in arm64 x86_64; do
    [[ " $archs " == *" $arch "* ]] || fail "$name lacks $arch (has: $archs)"
  done

  # Every architecture must run on the oldest macOS Tamp supports. Newer binaries
  # say so in LC_BUILD_VERSION ("minos"), older ones in LC_VERSION_MIN_MACOSX ("version").
  build_info="$(vtool -show-build "$exe")"
  minimums="$(awk '/LC_VERSION_MIN_MACOSX/ { old = 1 } $1 == "minos" { print $2 } old && $1 == "version" { print $2; old = 0 }' <<<"$build_info")"
  [ -n "$minimums" ] || fail "can't read the minimum macOS of $name"
  for minos in $minimums; do
    [ "$(printf '%s\n%s\n' "$minos" "$MIN_MACOS" | sort -V | tail -1)" = "$MIN_MACOS" ] \
      || fail "$name needs macOS $minos, newer than $MIN_MACOS"
  done

  details="$(codesign -d --verbose=2 "$exe" 2>&1)" || fail "$name isn't signed: $details"
  grep -q 'flags=.*runtime' <<<"$details" || fail "$name isn't signed with the hardened runtime"
  if [ "$dry_run" = 0 ]; then
    grep -q "^Authority=Developer ID Application" <<<"$details" || fail "$name isn't signed with Developer ID"
    grep -q "^TeamIdentifier=$TAMP_TEAM_ID$" <<<"$details" || fail "$name has the wrong Team ID"
    grep -q "^Timestamp=" <<<"$details" || fail "$name has no secure timestamp"
  fi
  echo "ok  $name ($archs)"
done

entitlements="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
if grep -q get-task-allow <<<"$entitlements"; then
  fail "the app carries the get-task-allow entitlement, which notarization rejects"
fi
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" = "$MIN_MACOS" ] \
  || fail "LSMinimumSystemVersion isn't $MIN_MACOS"
for license in 7-Zip.txt 7-Zip-unRAR.txt zstd.txt libarchive.txt; do
  [ -s "$APP/Contents/Resources/Licenses/$license" ] || fail "license $license is missing"
done
codesign --verify --deep --strict --verbose=2 "$APP"
echo "ok  signature, entitlements, minimum macOS and licenses"

ZIP="$OUT/Tamp-$version.zip"
if [ "$dry_run" = 1 ]; then
  ditto -c -k --keepParent "$APP" "$ZIP"
  step "Dry run passed"
  echo "Built $ZIP, signed for this Mac only. A real run would now:"
  echo "  xcrun notarytool submit \"$ZIP\" --keychain-profile \"\$TAMP_NOTARY_PROFILE\" --wait"
  echo "  xcrun stapler staple \"$APP\""
  echo "  spctl --assess --type execute -vv \"$APP\""
  exit 0
fi

step "Notarizing (this usually takes a few minutes)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$TAMP_NOTARY_PROFILE" --wait --output-format plist >"$OUT/notarization.plist"
id="$(/usr/libexec/PlistBuddy -c 'Print :id' "$OUT/notarization.plist")"
status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$OUT/notarization.plist")"
if [ "$status" != "Accepted" ]; then
  xcrun notarytool log "$id" --keychain-profile "$TAMP_NOTARY_PROFILE" || true
  fail "notarization finished with status \"$status\" (submission $id); the log above says why"
fi

step "Stapling and verifying"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
assessment="$(spctl --assess --type execute -vv "$APP" 2>&1 || true)"
echo "$assessment"
grep -q "source=Notarized Developer ID" <<<"$assessment" || fail "Gatekeeper doesn't accept the app as notarized"
# Zip again so the download carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

step "Done"
echo "$ZIP is signed, notarized and stapled."
