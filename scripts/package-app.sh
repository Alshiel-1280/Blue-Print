#!/bin/sh
set -eu

configuration="${1:-debug}"
output_root="${2:-.build/app}"
build_origin="${3:-self}"
app_name="BluePrint"

case "$configuration" in
    debug)
        swift_configuration="debug"
        ;;
    release)
        swift_configuration="release"
        ;;
    *)
        echo "usage: $0 [debug|release] [output-directory]" >&2
        exit 2
        ;;
esac

case "$build_origin" in
    self|official) ;;
    *)
        echo "usage: $0 [debug|release] [output-directory] [self|official]" >&2
        exit 2
        ;;
esac

if [ "$build_origin" = "official" ]; then
    swift build -c "$swift_configuration" --product "$app_name" -Xswiftc -DBLUEPRINT_OFFICIAL_BUILD
else
    swift build -c "$swift_configuration" --product "$app_name"
fi
binary_path="$(swift build -c "$swift_configuration" --show-bin-path)/$app_name"
bundle_path="$output_root/$app_name.app"

mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
cp "$binary_path" "$bundle_path/Contents/MacOS/$app_name"
cp Resources/Info.plist "$bundle_path/Contents/Info.plist"
chmod 755 "$bundle_path/Contents/MacOS/$app_name"

echo "$bundle_path"
