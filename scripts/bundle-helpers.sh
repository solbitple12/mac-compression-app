#!/usr/bin/env bash
# Xcode build phase for the Tamp app target: copies the helper tools into
# Tamp.app/Contents/Helpers and their licenses into Contents/Resources/Licenses,
# and signs each helper with the app's identity before Xcode signs the app.
#
# Reads build/helpers from scripts/build-helpers.sh, or TAMP_HELPERS_OUT if set.
# Debug builds without helpers only warn, so the UI can be worked on without them;
# Release builds fail.
set -euo pipefail

source_dir="${TAMP_HELPERS_OUT:-$SRCROOT/build/helpers}"
helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
licenses="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Licenses"
tools=(7zz bsdtar zstd)

for tool in "${tools[@]}"; do
  if [ ! -x "$source_dir/bin/$tool" ]; then
    if [ "$CONFIGURATION" = "Release" ]; then
      echo "error: $source_dir/bin/$tool is missing. Run scripts/build-helpers.sh first."
      exit 1
    fi
    echo "warning: $source_dir/bin/$tool is missing, so jobs will fail. Run scripts/build-helpers.sh."
    exit 0
  fi
done

mkdir -p "$helpers" "$licenses"
for tool in "${tools[@]}"; do
  ditto "$source_dir/bin/$tool" "$helpers/$tool"
  if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ]; then
    codesign --force --options runtime --timestamp=none \
      --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$helpers/$tool"
  fi
done
ditto "$source_dir/licenses" "$licenses"
