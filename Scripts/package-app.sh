#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="EchoFlow"
APP_BUNDLE="dist/${APP_NAME}.app"
ZIP_PATH="dist/${APP_NAME}.zip"
VERIFY_DIR="dist/verify-extracted"
ICONSET_DIR="dist/AppIcon.iconset"

rm -rf "$APP_BUNDLE" "$ZIP_PATH" "$ZIP_PATH.sha256" "$VERIFY_DIR" "$ICONSET_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "dist"

swift build --configuration release --product EchoFlowApp
install -m 755 ".build/release/EchoFlowApp" "$APP_BUNDLE/Contents/MacOS/EchoFlow"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
test -x "$APP_BUNDLE/Contents/MacOS/EchoFlow"
/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_BUNDLE/Contents/Info.plist" | grep -Fx 'EchoFlow'
/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP_BUNDLE/Contents/Info.plist" | grep -Fx 'EchoFlow'
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_BUNDLE/Contents/Info.plist" | grep -Fx 'EchoFlow'

resource_bundles=()
EXPECTED_CORE_BUNDLE=".build/release/EchoFlow_EchoFlowCore.bundle"
if [[ ! -s "$EXPECTED_CORE_BUNDLE/model-manifest.json" ]]; then
    printf 'Required model catalog bundle is missing: %s\n' "$EXPECTED_CORE_BUNDLE" >&2
    find -L .build/release -maxdepth 2 -print >&2
    exit 1
fi
while IFS= read -r bundle_path; do
    resource_bundles+=("$bundle_path")
done < <(find -L .build/release -maxdepth 2 -type d -name '*.bundle' -print)
if ((${#resource_bundles[@]} == 0)); then
    printf 'No SwiftPM resource bundles found under .build/release. Contents:\n' >&2
    find -L .build/release -maxdepth 2 -print >&2
    exit 1
fi
for bundle_path in "${resource_bundles[@]}"; do
    cp -R "$bundle_path" "$APP_BUNDLE/Contents/Resources/"
done
test -s "$APP_BUNDLE/Contents/Resources/EchoFlow_EchoFlowCore.bundle/model-manifest.json"

swift Scripts/create-app-icon.swift "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_BUNDLE/Contents/Info.plist" | grep -Fx 'EchoFlow'
/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP_BUNDLE/Contents/Info.plist" | grep -Fx 'EchoFlow'
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_BUNDLE/Contents/Info.plist" | grep -Fx 'EchoFlow'
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist" | grep -Fx '0.1.16'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist" | grep -Fx '17'

mkdir -p "$VERIFY_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
EXTRACTED_APP="$VERIFY_DIR/${APP_NAME}.app"
test -x "$EXTRACTED_APP/Contents/MacOS/EchoFlow"
/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$EXTRACTED_APP/Contents/Info.plist" | grep -Fx 'EchoFlow'
/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$EXTRACTED_APP/Contents/Info.plist" | grep -Fx 'EchoFlow'
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$EXTRACTED_APP/Contents/Info.plist" | grep -Fx 'EchoFlow'
plutil -lint "$EXTRACTED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$EXTRACTED_APP/Contents/Info.plist" | grep -Fx '0.1.16'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$EXTRACTED_APP/Contents/Info.plist" | grep -Fx '17'
codesign --verify --deep --strict "$EXTRACTED_APP"
test -n "$(find "$EXTRACTED_APP/Contents/Resources" -maxdepth 1 -type d -name '*.bundle' -print -quit)"
(
    cd "$(dirname "$ZIP_PATH")"
    shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256"
    shasum -a 256 -c "$(basename "$ZIP_PATH").sha256"
)
printf 'Packaged and verified: %s\n' "$ZIP_PATH"
