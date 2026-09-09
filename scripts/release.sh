#!/bin/sh
# Builds a signed, notarized, stapled DMG that opens on someone else's Mac
# without a Gatekeeper detour.
#
# Runs locally, not in CI, so the Developer ID certificate never leaves this
# machine. Notarization credentials come from Config/notary.env, which is
# gitignored; see Config/notary.env.example.
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$project_dir/build"
app="$build_dir/TypeSwitch.app"

cd "$project_dir"

if [ -f Config/notary.env ]; then
    . ./Config/notary.env
fi

# --- Preflight -------------------------------------------------------------
# Everything that can be checked is checked before a build is spent:
# notarization takes minutes, and failing at the last step wastes all of it.

if [ "${RELEASE_IDENTITY+x}" = "x" ]; then
    identity=$RELEASE_IDENTITY
else
    identity=$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' \
        | sed -n '1p')
fi
if [ -z "$identity" ]; then
    echo "No Developer ID Application certificate found." >&2
    echo "A distributable build needs one; a paid Apple Developer Program" >&2
    echo "membership issues it. Set RELEASE_IDENTITY to choose explicitly." >&2
    exit 1
fi

for name in NOTARY_KEY NOTARY_KEY_ID NOTARY_ISSUER; do
    eval "value=\${$name:-}"
    if [ -z "$value" ]; then
        echo "$name is not set." >&2
        echo "Copy Config/notary.env.example to Config/notary.env and fill it in." >&2
        exit 1
    fi
done
if [ ! -f "$NOTARY_KEY" ]; then
    echo "App Store Connect key not found at: $NOTARY_KEY" >&2
    exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "create-dmg is not installed. Install it with: brew install create-dmg" >&2
    exit 1
fi

version=$(xcodebuild -project TypeSwitch.xcodeproj -target TypeSwitch \
    -configuration Release -showBuildSettings 2>/dev/null \
    | sed -n 's/^ *MARKETING_VERSION = \(.*\)$/\1/p' | sed -n '1p')
case "$version" in
    ''|*[!0-9A-Za-z.-]*) echo "Invalid MARKETING_VERSION: '$version'" >&2; exit 1 ;;
esac

dmg_name="TypeSwitch-$version.dmg"
dmg="$build_dir/$dmg_name"

# Submits one file and insists on an accepted verdict.
#
# `notarytool submit --wait` does exit non-zero on a rejected submission, but
# only when nothing swallows that code — a pipeline reports its last command's
# status, which is how a rejection gets read as success. The output goes to a
# file, and the verdict is confirmed in the text as well.
notarize() {
    submission=$1
    submission_log="$build_dir/notarization-$(basename "$submission").log"

    if xcrun notarytool submit "$submission" \
        --key "$NOTARY_KEY" \
        --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER" \
        --wait >"$submission_log" 2>&1
    then
        submitted=0
    else
        submitted=1
    fi
    cat "$submission_log"

    if [ "$submitted" -ne 0 ] || ! grep -q 'status: Accepted' "$submission_log"; then
        echo "Notarization did not come back Accepted for $submission." >&2

        # The verdict comes back from the submission, but never the reason —
        # that only exists at the log endpoint, and it is the only thing that
        # says which file Apple objected to. Fetching it here is the difference
        # between a failure that can be acted on and one that cannot.
        submission_id=$(sed -n 's/^ *id: \([0-9a-f-]*\)$/\1/p' "$submission_log" | sed -n '1p')
        if [ -n "$submission_id" ]; then
            echo "Log for submission $submission_id:" >&2
            xcrun notarytool log "$submission_id" \
                --key "$NOTARY_KEY" \
                --key-id "$NOTARY_KEY_ID" \
                --issuer "$NOTARY_ISSUER" >&2 || true
        fi
        exit 1
    fi
}

# --- Build and sign --------------------------------------------------------

"$project_dir/scripts/build-app.sh" >/dev/null

codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
echo "Signed with: $identity"

# --- Notarize the app ------------------------------------------------------
# The app is notarized and stapled before it goes into the image. Stapling only
# the image leaves the copy someone drags out of it with no ticket of its own,
# so that copy's first launch has to reach Apple over the network to confirm
# it was notarized. A stapled app carries the answer with it.

app_zip="$build_dir/TypeSwitch.zip"
rm -f "$app_zip"
ditto -c -k --keepParent "$app" "$app_zip"
notarize "$app_zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
rm -f "$app_zip"

# --- Package and notarize the image ----------------------------------------

# create-dmg lays the window out by driving Finder over AppleScript, and
# Finder is not reliably ready when it asks — the failure is a -10006 on
# setting a window property, and it is intermittent. Give Finder room, clear
# the half-built read-write image each time, and retry.
dmg_work="$build_dir/dmg"
rm -rf "$dmg_work"
mkdir -p "$dmg_work/source"
ditto "$app" "$dmg_work/source/TypeSwitch.app"

create_image() {
    rm -f "$dmg"
    find "$build_dir" -maxdepth 1 -type f -name "rw.*.$dmg_name" -delete
    create-dmg \
        --volname "TypeSwitch $version" \
        --volicon "$app/Contents/Resources/AppIcon.icns" \
        --window-size 520 340 \
        --icon-size 96 \
        --icon "TypeSwitch.app" 130 160 \
        --hide-extension "TypeSwitch.app" \
        --app-drop-link 390 160 \
        --no-internet-enable \
        --applescript-sleep-duration 8 \
        --overwrite \
        "$dmg" \
        "$dmg_work/source" >/dev/null
}

attempt=1
while ! create_image
do
    if [ "$attempt" -ge 3 ]; then
        echo "create-dmg failed after $attempt attempts." >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    echo "Retrying create-dmg after a Finder layout failure (attempt $attempt of 3)..." >&2
    sleep 2
done
rm -rf "$dmg_work"

# create-dmg produces an unsigned image. Notarization and stapling work on one
# regardless, but an unsigned image has nothing of its own for Gatekeeper to
# assess, so signing it is what makes the download itself verifiable.
codesign --force --timestamp --sign "$identity" "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"

# --- Verify ----------------------------------------------------------------
# What a first-time download goes through, checked here rather than discovered
# by whoever downloads it. The image and the app inside it are both checked,
# which is what stops the stapling above from quietly going away again.

"$project_dir/scripts/audit-release.sh" "$dmg" "$version"

# Written from inside the directory, so the file names the image rather than
# this machine's directory layout: `shasum -c` looks for the path it is given,
# and an absolute one exists on no other machine.
(cd "$build_dir" && shasum -a 256 "$dmg_name" >"$dmg_name.sha256")

echo
echo "$dmg"
cat "$dmg.sha256"
