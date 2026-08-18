#!/bin/bash
# Build, bundle, sign, notarize, staple, and DMG the app. Requires Developer ID cert
# + notarytool keychain profile "batesai-notary".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
VERSION="${1:-1.0.0}"
OUT="$ROOT/dist"; APP="$OUT/Photos AutoRotate.app"; DMG="$OUT/PhotosAutoRotate-$VERSION.dmg"
IDENT="7C0CCBA426A5480F0F29F006EC92E0E17173768D"
swift build -c release --product PhotosAutoRotateApp
rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PhotosAutoRotateApp "$APP/Contents/MacOS/PhotosAutoRotate"
cp -R models/OrientationClassifier.mlpackage models/OrientationClassifierB.mlpackage "$APP/Contents/Resources/"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.batesai.photos-autorotate</string>
<key>CFBundleName</key><string>Photos AutoRotate</string>
<key>CFBundleDisplayName</key><string>Photos AutoRotate</string>
<key>CFBundleExecutable</key><string>PhotosAutoRotate</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPhotoLibraryUsageDescription</key><string>Photos AutoRotate reads your library to find sideways or upside-down photos and, only when ≥99% certain, rotates them as a normal, revertible Photos edit.</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>© 2026 Bates LLC. Model: duartebarbosadev/deep-image-orientation-detection (MIT), ternaus/check_orientation (MIT).</string>
</dict></plist>
PLIST
cat > "$OUT/entitlements.plist" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.disable-library-validation</key><false/>
<key>com.apple.security.personal-information.photos-library</key><true/>
</dict></plist>
ENT
# sign inner mlpackages are data (no code); sign the bundle deep w/ hardened runtime + timestamp
codesign --force --deep --options runtime --timestamp --entitlements "$OUT/entitlements.plist" --sign "$IDENT" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
# DMG
STAGE="$OUT/stage"; mkdir -p "$STAGE"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Photos AutoRotate" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENT" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile batesai-notary --wait
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"
spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | tail -2
echo "OK: $DMG"
