#!/usr/bin/env bash
# Xcode build phase for the Tamp app target: copies the helper tools into
# Tamp.app/Contents/Helpers and their licenses into Contents/Resources/Licenses,
# and signs each helper with the app's identity before Xcode signs the app.
#
# Reads build/helpers from scripts/build-helpers.sh, or TAMP_HELPERS_OUT if set.
# Debug builds without helpers only warn, so the UI can be worked on without them;
# Release builds fail.
set -euo pipefail

source "$SRCROOT/scripts/helper-list.sh"
source_dir="${TAMP_HELPERS_OUT:-$SRCROOT/build/helpers}"
helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
licenses="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Licenses"
tools=("${TAMP_HELPERS[@]}")

identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
# Notarization needs a secure timestamp; an ad-hoc signature can't have one.
if [ "$identity" = "-" ]; then timestamp=--timestamp=none; else timestamp=--timestamp; fi

mkdir -p "$helpers" "$licenses"
missing=()
for tool in "${tools[@]}"; do
  if [ ! -x "$source_dir/bin/$tool" ]; then
    missing+=("$tool")
    continue
  fi
  ditto "$source_dir/bin/$tool" "$helpers/$tool"
  if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ]; then
    codesign --force --options runtime "$timestamp" --sign "$identity" "$helpers/$tool"
  fi
done

# A tool still being built (say, oxipng waiting on a Rust toolchain) shouldn't
# stop every other already-built helper from being bundled and usable.
if [ "${#missing[@]}" -gt 0 ]; then
  if [ "$CONFIGURATION" = "Release" ]; then
    echo "error: missing helpers, run scripts/build-helpers.sh first: ${missing[*]}"
    exit 1
  fi
  echo "warning: missing helpers, jobs needing them will fail until you run scripts/build-helpers.sh: ${missing[*]}"
fi
ditto "$source_dir/licenses" "$licenses"
