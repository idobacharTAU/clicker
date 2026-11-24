#!/bin/zsh
# בונה, חותם ומתקין את הגרסה *האישית* של "קליקר" על האייפון שמחובר בכבל
# (כולל מצב "גם כשנעול", שלא קיים בגרסת האפסטור).
# צריך: Apple ID מחובר ב-Xcode (Settings ← Accounts) ואייפון מחובר עם Developer Mode פעיל.
# שימוש:  ./install-iphone.sh          (אפשר לכפות צוות: TEAM_ID=XXXXXXXXXX ./install-iphone.sh)
set -e -o pipefail
cd "$(dirname "$0")/ios-app"

BUNDLE_ID="${BUNDLE_ID:-com.idobachar.slideclicker}"

# --- Team ID (Personal Team) ---
if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(defaults export com.apple.dt.Xcode - 2>/dev/null | plutil -extract IDEProvisioningTeamByIdentifier json -o - - 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
teams = [t for v in data.values() for t in v]
teams.sort(key=lambda t: not t.get("isFreeProvisioningTeam", False))
print(teams[0]["teamID"] if teams else "")
' || true)"
fi
if [[ -z "$TEAM_ID" ]]; then
  echo "❌ לא נמצא Apple ID ב-Xcode. פתחו Xcode ← Settings ← Accounts ← + ← Apple ID, התחברו, ונסו שוב."
  exit 1
fi
echo "👤 צוות חתימה: $TEAM_ID"

# --- Connected iPhone ---
UDID="$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null | python3 -c '
import json, sys
text = sys.stdin.read()
data = json.loads(text[text.index("{"):])
for d in data.get("result", {}).get("devices", []):
    hw = d.get("hardwareProperties", {})
    conn = d.get("connectionProperties", {})
    if hw.get("reality") == "physical" and hw.get("platform") == "iOS" and conn.get("tunnelState") != "unavailable":
        print(hw.get("udid", "")); break
' || true)"
if [[ -z "$UDID" ]]; then
  echo "❌ לא נמצא אייפון מחובר. חברו בכבל, בטלו נעילה, ואשרו \"לסמוך על המחשב\"."
  exit 1
fi
echo "📱 אייפון: $UDID"

xcodegen generate >/dev/null

# Personal build: same app + background audio for the "also when locked" mode.
mkdir -p build
cp SlideClicker/Info.plist build/Personal-Info.plist
plutil -insert UIBackgroundModes -json '["audio"]' build/Personal-Info.plist

APP="build/device/Build/Products/Release-iphoneos/SlideClicker.app"
rm -rf "$APP"   # so a failed build can never install a stale app

echo "🔨 בונה וחותם..."
xcodebuild -project SlideClicker.xcodeproj -scheme SlideClicker -configuration Release \
  -destination "id=$UDID" -derivedDataPath build/device \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  INFOPLIST_FILE=build/Personal-Info.plist SWIFT_ACTIVE_COMPILATION_CONDITIONS=PERSONAL_BUILD \
  build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)|Signing|requires" || true

[[ -d "$APP" ]] && codesign -v --strict "$APP" 2>/dev/null || { echo "❌ הבנייה נכשלה"; exit 1; }
EXP="$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null || true)"
[[ -n "$EXP" ]] && echo "📅 החתימה תקפה עד: $EXP"

echo "📲 מתקין..."
xcrun devicectl device install app --device "$UDID" "$APP"

echo "🚀 מפעיל..."
if ! xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID"; then
  echo "⚠️  ההפעלה נחסמה — כנראה צריך לאשר את המפתח באייפון:"
  echo "   הגדרות ← כללי ← VPN וניהול מכשירים ← Apple Development ← לסמוך (Trust)"
fi
echo "✅ סיום."
