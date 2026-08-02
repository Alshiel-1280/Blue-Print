#!/bin/sh
set -eu

output_root="${1:-.build/release-artifacts}"
identity="${BLUEPRINT_CODESIGN_IDENTITY:-}"
notary_profile="${BLUEPRINT_NOTARY_PROFILE:-}"
download_url="${BLUEPRINT_RELEASE_DOWNLOAD_URL:-}"

if [ -z "$identity" ] || [ -z "$notary_profile" ] || [ -z "$download_url" ]; then
    echo "BLUEPRINT_CODESIGN_IDENTITY, BLUEPRINT_NOTARY_PROFILE, and BLUEPRINT_RELEASE_DOWNLOAD_URL are required" >&2
    exit 2
fi

./scripts/release-preflight.sh
version=$(
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
        Resources/Info.plist
)

./scripts/package-app.sh release "$output_root" official
app_path="$output_root/BluePrint.app"
codesign --force --options runtime --timestamp \
    --entitlements Resources/BluePrint.entitlements \
    --sign "$identity" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
codesign -dvv "$app_path"

staging_directory="$output_root/dmg-root"
mkdir -p "$staging_directory"
ditto "$app_path" "$staging_directory/BluePrint.app"
ln -s /Applications "$staging_directory/Applications"

dmg_path="$output_root/BluePrint-v${version}-macOS-AppleSilicon.dmg"
hdiutil create \
    -volname "BluePrint v${version}" \
    -srcfolder "$staging_directory" \
    -format UDZO \
    -ov \
    "$dmg_path"

# The DMG container must have its own Developer ID signature before notarization.
codesign --force --timestamp --sign "$identity" "$dmg_path"
codesign --verify --verbose=2 "$dmg_path"
xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"
spctl --assess --type execute --verbose=2 "$app_path"

release_directory=$(dirname "$dmg_path")
release_name=$(basename "$dmg_path")
(
    cd "$release_directory"
    shasum -a 256 "$release_name" > "$release_name.sha256"
)
swift run blueprint-rule-tool sign-update-manifest \
    "$version" \
    "$dmg_path" \
    "$download_url" \
    "$output_root/update-manifest.json"
echo "$dmg_path"
