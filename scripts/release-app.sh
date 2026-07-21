#!/bin/sh
set -eu

output_root="${1:-.build/release-artifacts}"
identity="${BLUEPRINT_CODESIGN_IDENTITY:-}"
notary_profile="${BLUEPRINT_NOTARY_PROFILE:-}"

if [ -z "$identity" ] || [ -z "$notary_profile" ]; then
    echo "BLUEPRINT_CODESIGN_IDENTITY and BLUEPRINT_NOTARY_PROFILE are required" >&2
    exit 2
fi

./scripts/package-app.sh release "$output_root" official
app_path="$output_root/BluePrint.app"
codesign --force --options runtime --timestamp --sign "$identity" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

submission_zip="$output_root/BluePrint-notary-submission.zip"
ditto -c -k --keepParent "$app_path" "$submission_zip"
xcrun notarytool submit "$submission_zip" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"

release_zip="$output_root/BluePrint-macOS-arm64.zip"
ditto -c -k --keepParent "$app_path" "$release_zip"
shasum -a 256 "$release_zip" > "$release_zip.sha256"
echo "$release_zip"
