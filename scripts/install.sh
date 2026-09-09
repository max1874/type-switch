#!/bin/sh
# Puts the built app in /Applications and starts it from there.
#
# This is the only thing that updates the copy you actually use, and the order
# is the whole point: quit first, then replace, then launch. Overwriting an app
# while a process is running from it leaves that process with a code signature
# that no longer matches its own bundle. macOS then stops recognising it —
# tccd logs `cdhash mismatch` and gives up identifying the process — and its
# Accessibility and Input Monitoring grants quietly stop applying. Nothing
# crashes; text just becomes unreadable in every app.
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
built="$project_dir/build/TypeSwitch.app"
installed="/Applications/TypeSwitch.app"
bundle_id="dev.typeswitch.app"

if [ ! -d "$built" ]; then
    echo "Nothing to install: $built does not exist." >&2
    echo "Build it first with 'make app', or 'make release' for a signed one." >&2
    exit 1
fi

# Any instance, wherever it was launched from — one left running out of build/
# is exactly the situation this is here to end.
pattern='TypeSwitch\.app/Contents/MacOS/TypeSwitch'

running=$(pgrep -f "$pattern" || true)
if [ -n "$running" ]; then
    echo "Quitting TypeSwitch ($(echo "$running" | tr '\n' ' '))"
    # shellcheck disable=SC2086
    kill $running 2>/dev/null || true

    waited=0
    while [ "$waited" -lt 50 ] && pgrep -f "$pattern" >/dev/null 2>&1; do
        sleep 0.1
        waited=$((waited + 1))
    done

    still=$(pgrep -f "$pattern" || true)
    if [ -n "$still" ]; then
        echo "It did not quit within 5 seconds; stopping it outright." >&2
        # shellcheck disable=SC2086
        kill -9 $still 2>/dev/null || true
        sleep 0.5
    fi
fi

# Look before removing. The path is a fixed one, but it is in /Applications, so
# it is worth being sure of what is there.
if [ -e "$installed" ]; then
    found=$(defaults read "$installed/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "")
    if [ "$found" != "$bundle_id" ]; then
        echo "$installed is not TypeSwitch (bundle id: ${found:-unreadable})." >&2
        echo "Refusing to replace it." >&2
        exit 1
    fi
    rm -rf "$installed"
fi

ditto "$built" "$installed"
open "$installed"

echo "$installed"
codesign -dvv "$installed" 2>&1 | sed -n 's/^Authority=/signed by: /p' | sed -n '1p'
echo
echo "macOS ties Accessibility and Input Monitoring to the signature, so a build"
echo "signed by someone new has to be approved again in System Settings."
