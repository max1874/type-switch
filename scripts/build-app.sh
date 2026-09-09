#!/bin/sh
# Builds TypeSwitch.app into build/ and leaves it there.
#
# Signing follows Config/TypeSwitch.xcconfig, so this produces the same
# development build Xcode does. For a distributable build, use release.sh.
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${CONFIGURATION:-Release}
derived_data="$project_dir/build/DerivedData"
output="$project_dir/build/TypeSwitch.app"

cd "$project_dir"

# `generic/platform=macOS` rather than letting xcodebuild pick a destination:
# left alone it takes the first match, which names this machine's own
# architecture and quietly builds for that one alone.
xcodebuild \
    -project TypeSwitch.xcodeproj \
    -scheme TypeSwitch \
    -configuration "$configuration" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    build

built="$derived_data/Build/Products/$configuration/TypeSwitch.app"
if [ ! -d "$built" ]; then
    echo "Build succeeded but $built is missing." >&2
    exit 1
fi

case "$output" in
    "$project_dir"/build/TypeSwitch.app) rm -rf "$output" ;;
    *) echo "Refusing to remove unexpected app directory: $output" >&2; exit 1 ;;
esac
ditto "$built" "$output"

echo "$output"
