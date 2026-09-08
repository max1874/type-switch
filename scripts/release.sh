#!/bin/sh
# Builds a signed, notarized, stapled DMG that opens on someone else's Mac
# without a Gatekeeper detour.
#
# Runs locally, not in CI, so the Developer ID certificate never leaves this
# machine. Needs, once:
#
#     xcrun notarytool store-credentials TypeSwitch \
#         --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Override the defaults with RELEASE_IDENTITY and NOTARY_PROFILE.
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$project_dir/build"
app="$build_dir/TypeSwitch.app"
notary_profile=${NOTARY_PROFILE:-TypeSwitch}

cd "$project_dir"

# --- Preflight -------------------------------------------------------------
# Everything that can be checked before spending a build is checked here:
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

if ! xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
    echo "No notarytool credentials stored under the profile '$notary_profile'." >&2
    echo "Create them once with:" >&2
    echo "    xcrun notarytool store-credentials $notary_profile \\" >&2
    echo "        --apple-id <your-apple-id> --team-id <your-team-id> --password <app-specific-password>" >&2
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

dmg="$build_dir/TypeSwitch-$version.dmg"

# --- Build and sign --------------------------------------------------------

"$project_dir/scripts/build-app.sh" >/dev/null

# Re-signed here rather than left to the build: notarization requires the
# hardened runtime and a secure timestamp, and this is the one place both are
# guaranteed to be applied.
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
echo "Signed with: $identity"

# --- Package ---------------------------------------------------------------

rm -f "$dmg"
create-dmg \
    --volname "TypeSwitch $version" \
    --window-size 520 340 \
    --icon-size 96 \
    --icon "TypeSwitch.app" 130 160 \
    --app-drop-link 390 160 \
    --no-internet-enable \
    "$dmg" \
    "$app" >/dev/null

# --- Notarize --------------------------------------------------------------
# The DMG is what people download, so the DMG is what gets stapled. Notarizing
# it covers the app inside it.

xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg"

# --- Verify ----------------------------------------------------------------
# What a first-time download actually goes through, checked here rather than
# discovered by whoever downloads it.

xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature -v "$dmg"

shasum -a 256 "$dmg" > "$dmg.sha256"

echo
echo "$dmg"
cat "$dmg.sha256"
