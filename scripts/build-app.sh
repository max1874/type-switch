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

# build/ holds artifacts, and nothing is meant to be run from it — `make
# install` is what updates the copy you use. Replacing a bundle underneath a
# process running from it costs that process its identity: its code signature
# stops matching its own bundle, macOS can no longer recognise it, and its
# Accessibility and Input Monitoring grants stop applying without a word. That
# is worth a message rather than a silent overwrite.
running=$(pgrep -f "$output/Contents/MacOS/TypeSwitch" || true)
if [ -n "$running" ]; then
    echo "TypeSwitch is running from the path this build overwrites:" >&2
    echo "  $output" >&2
    echo "Quit it first, or use 'make install' to move it to /Applications." >&2
    exit 1
fi

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
