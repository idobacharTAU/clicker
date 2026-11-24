#!/bin/zsh
# בונה את "קליקר למק", חותם ב-Developer ID, שולח ל-notarization של אפל ויוצר DMG להפצה.
# פעם ראשונה (חד-פעמי):
#   1. Xcode ← Settings ← Accounts ← Manage Certificates ← + ← "Developer ID Application"
#   2. סיסמה ייעודית לאפליקציה: appleid.apple.com ← Sign-In and Security ← App-Specific Passwords
#   3. xcrun notarytool store-credentials clicker-notary --apple-id <המייל> --team-id 6R6WU3R8XA
# שימוש:  ./release/release-mac.sh
set -e -o pipefail
cd "$(dirname "$0")/../ios-app"
TEAM_ID="${TEAM_ID:-6R6WU3R8XA}"
PROFILE="${NOTARY_PROFILE:-clicker-notary}"
OUT="build/release-mac"
rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen generate >/dev/null

echo "🔨 Archive..."
xcodebuild -project SlideClicker.xcodeproj -scheme MacClicker -configuration Release \
  -archivePath "$OUT/Clicker.xcarchive" DEVELOPMENT_TEAM="$TEAM_ID" archive -quiet

cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST

echo "✍️  Developer ID export..."
xcodebuild -exportArchive -archivePath "$OUT/Clicker.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/export.plist" -allowProvisioningUpdates -quiet
APP="$OUT/export/Clicker.app"
codesign --verify --deep --strict "$APP"

echo "💿 DMG..."
mkdir -p "$OUT/dmg" && cp -R "$APP" "$OUT/dmg/" && ln -s /Applications "$OUT/dmg/Applications"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$OUT/Clicker-$VERSION.dmg"
hdiutil create -volname "Clicker" -srcfolder "$OUT/dmg" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"

echo "📨 Notarization (כמה דקות)..."
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo "✅ מוכן להפצה: $(pwd)/$DMG"
