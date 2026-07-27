#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repository_root"

identity="${BLUEPRINT_CODESIGN_IDENTITY:-}"
notary_profile="${BLUEPRINT_NOTARY_PROFILE:-}"

if [ -z "$identity" ] || [ -z "$notary_profile" ]; then
    echo "BLUEPRINT_CODESIGN_IDENTITY and BLUEPRINT_NOTARY_PROFILE are required" >&2
    exit 2
fi

for command in codesign git plutil security swift xcrun; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "required command is unavailable: $command" >&2
        exit 1
    fi
done

if [ -n "$(git status --porcelain)" ]; then
    echo "release must start from a clean Git worktree" >&2
    exit 1
fi

plist_version=$(
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
        Resources/Info.plist
)
source_version=$(
    sed -n 's/.*public static let app = "\([^"]*\)".*/\1/p' \
        Sources/BlueprintDomain/Versioning.swift
)

if [ -z "$source_version" ] || [ "$plist_version" != "$source_version" ]; then
    echo "app version mismatch: Info.plist=$plist_version source=$source_version" >&2
    exit 1
fi

expected_version="${BLUEPRINT_EXPECTED_VERSION:-$source_version}"
if [ "$source_version" != "$expected_version" ]; then
    echo "unexpected app version: expected=$expected_version actual=$source_version" >&2
    exit 1
fi

if ! plutil -lint Resources/Info.plist >/dev/null; then
    echo "Resources/Info.plist is invalid" >&2
    exit 1
fi

identities=$(security find-identity -v -p codesigning 2>&1)
if ! printf '%s\n' "$identities" | grep -F -- "$identity" >/dev/null; then
    echo "codesigning identity is not available: $identity" >&2
    printf '%s\n' "$identities" >&2
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null; then
    echo "notarytool profile validation failed: $notary_profile" >&2
    exit 1
fi

echo "release preflight passed"
echo "version: $source_version"
echo "codesigning identity: $identity"
echo "notary profile: $notary_profile"
