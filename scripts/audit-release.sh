#!/bin/sh
# Checks a built disk image the way a first-time download is checked, and
# fails on anything a downloader would hit.
#
# release.sh runs this at the end, but it takes a path, so it also works on a
# downloaded image:
#
#     ./scripts/audit-release.sh ~/Downloads/TypeSwitch-1.0.0.dmg 1.0.0
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 <dmg-path> [expected-version]" >&2
    exit 2
fi

dmg=$1
expected_version=${2-}
work_dir=$(mktemp -d -t typeswitch-audit)
work_dir=$(CDPATH='' cd -- "$work_dir" && pwd -P)
mount_dir="$work_dir/mount"
mkdir "$mount_dir"
mounted=0

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM

    if [ "$mounted" -eq 1 ] && ! hdiutil detach "$mount_dir" >/dev/null; then
        echo "Audit cleanup failed: could not detach $mount_dir." >&2
        status=1
    fi

    if mount | grep -Fq " on $mount_dir "; then
        echo "Audit cleanup warning: $mount_dir is still mounted." >&2
        status=1
    else
        case "$(basename "$work_dir")" in
            typeswitch-audit.*) rm -rf "$work_dir" || status=1 ;;
            *) echo "Refusing to remove unexpected audit directory: $work_dir" >&2; status=1 ;;
        esac
    fi

    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
    echo "Release audit failed: $1" >&2
    exit 1
}

if [ ! -f "$dmg" ]; then
    fail "no disk image at $dmg"
fi

hdiutil verify "$dmg" >/dev/null

xcrun stapler validate "$dmg" >/dev/null 2>&1 \
    || fail "the disk image carries no stapled notarization ticket."

spctl --assess --type open --context context:primary-signature "$dmg" >/dev/null 2>&1 \
    || fail "Gatekeeper rejects the disk image."

hdiutil attach -nobrowse -readonly -mountpoint "$mount_dir" "$dmg" >/dev/null
mounted=1

app="$mount_dir/TypeSwitch.app"
executable="$app/Contents/MacOS/TypeSwitch"

[ -d "$app" ] || fail "the disk image holds no TypeSwitch.app."

codesign --verify --deep --strict "$app"
signature=$(codesign -d --verbose=4 "$app" 2>&1)

printf '%s\n' "$signature" | grep -q '^Authority=Developer ID Application: ' \
    || fail "the app is not signed with a Developer ID Application certificate."
printf '%s\n' "$signature" | grep -q '^TeamIdentifier=[A-Z0-9]' \
    || fail "no team identifier is embedded."
printf '%s\n' "$signature" | grep -q '^Timestamp=' \
    || fail "the signature carries no secure timestamp."
printf '%s\n' "$signature" | grep -q 'flags=.*runtime' \
    || fail "the hardened runtime is not enabled."

# The reason this script exists. Stapling only the image leaves the copy
# someone drags out of it depending on a network round trip to Apple on first
# launch, and nothing else here would notice that coming back.
xcrun stapler validate "$app" >/dev/null 2>&1 \
    || fail "the app inside the image carries no stapled ticket of its own."

assessment=$(spctl --assess --type exec --verbose=4 "$app" 2>&1 || true)
printf '%s\n' "$assessment" | grep -Fq "source=Notarized Developer ID" \
    || fail "Gatekeeper does not report the app as notarized:
$assessment"

if [ -n "$expected_version" ]; then
    actual=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
    [ "$actual" = "$expected_version" ] \
        || fail "expected version $expected_version, found $actual."
fi

architectures=$(lipo -archs "$executable")
case " $architectures " in
    *" arm64 "*) ;;
    *) fail "Apple silicon architecture is missing (found: $architectures)." ;;
esac

echo "Release audit passed: Developer ID signature, hardened runtime, secure timestamp,"
echo "tickets stapled to both the image and the app, Gatekeeper accepts, arm64 present."
