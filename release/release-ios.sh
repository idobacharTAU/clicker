#!/bin/zsh
# בונה את גרסת האפסטור של "קליקר" לאייפון ומעלה ל-App Store Connect (TestFlight ← Review).
# לפני הפעם הראשונה: ליצור את האפליקציה ב-appstoreconnect.apple.com עם ה-Bundle ID
# com.idobachar.slideclicker (ראו RELEASE.md).
# בכל גרסה חדשה: להעלות את CURRENT_PROJECT_VERSION ב-ios-app/project.yml (ואת MARKETING_VERSION כשצריך).
set -e -o pipefail
cd "$(dirname "$0")/../ios-app"
TEAM_ID="${TEAM_ID:-6R6WU3R8XA}"
OUT="build/release-ios"
rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen generate >/dev/null

echo "🔨 Archive (גרסת אפסטור, בלי מצב 'גם כשנעול')..."
xcodebuild -project SlideClicker.xcodeproj -scheme SlideClicker -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/SlideClicker.xcarchive" \
  DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates archive -quiet

# Safety: the store build must not contain the background-audio mode.
if /usr/libexec/PlistBuddy -c "Print UIBackgroundModes" \
   "$OUT/SlideClicker.xcarchive/Products/Applications/SlideClicker.app/Info.plist" >/dev/null 2>&1; then
  echo "❌ UIBackgroundModes נמצא בבנייה, עצירה."; exit 1
fi

cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST

echo "⬆️  מעלה ל-App Store Connect..."
xcodebuild -exportArchive -archivePath "$OUT/SlideClicker.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/export.plist" -allowProvisioningUpdates
echo "✅ הועלה. בעוד כמה דקות הבנייה תופיע ב-App Store Connect ← TestFlight."
