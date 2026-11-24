# פרסום קליקר: אפסטור לאייפון + הורדה למק

שני מוצרים:
- **קליקר לאייפון**: ב-App Store, חינם. Bundle ID `com.idobachar.slideclicker`.
- **קליקר למק**: אפליקציה בשורת התפריטים. מופצת כקובץ DMG חתום (Developer ID + notarization) להורדה מהאתר, **לא** דרך ה-Mac App Store, כי היא שולחת הקשות מקלדת לאפליקציה אחרת וזה לא מסתדר עם ה-sandbox שהחנות דורשת. Bundle ID `com.idobachar.slideclicker.mac`.

## לפני הכול (פעם אחת)

1. **מקום לאתר ולהורדה.** הכי פשוט: ריפו ב-GitHub עם GitHub Pages מתיקיית `docs/` (בשביל מדיניות הפרטיות) ו-Releases (בשביל ה-DMG).
   - לעדכן את `AppLinks.macDownload` ב-[ContentView.swift](ios-app/SlideClicker/ContentView.swift) לכתובת ההורדה האמיתית.
   - להחליף את `CONTACT_EMAIL` ב-[docs/privacy.html](docs/privacy.html) במייל לפניות.
2. **תעודת Developer ID** (בשביל המק): Xcode ← Settings ← Accounts ← Manage Certificates ← + ← *Developer ID Application*.
3. **פרופיל notarization**: ליצור סיסמה ייעודית ב-appleid.apple.com (App-Specific Passwords), ואז:
   ```bash
   xcrun notarytool store-credentials clicker-notary --apple-id <המייל של חשבון המפתחים> --team-id 6R6WU3R8XA
   ```

## המק

```bash
./release/release-mac.sh
```
התוצאה: `ios-app/build/release-mac/Clicker-1.0.dmg`, חתום ועבר notarization. מעלים אותו ל-GitHub Releases (או לכל אתר).

## האייפון

1. ב-[App Store Connect](https://appstoreconnect.apple.com) ← Apps ← + ← New App:
   - Platform: iOS · Name: למשל "קליקר – שלט למצגות" (חייב להיות פנוי) · Primary language: Hebrew
   - Bundle ID: `com.idobachar.slideclicker` · SKU: `clicker-ios`
2. מעלים בנייה:
   ```bash
   ./release/release-ios.sh
   ```
3. בודקים ב-TestFlight על האייפון שלך (מול DMG המק החתום).
4. ממלאים את דף האפליקציה (טקסטים מוכנים בהמשך), ואז Add for Review ← Submit.

### מה למלא ב-App Store Connect
- **Privacy Policy URL**: הכתובת של `docs/privacy.html` ב-GitHub Pages.
- **App Privacy**: Data Not Collected.
- **Category**: Productivity. **Price**: Free. **Age rating**: 4+.
- **Screenshots**: לפחות 3 צילומים של אייפון 6.9" (1320×2868). אפשר לצלם מהסימולטור iPhone 17 Pro Max.
- **App Review notes** (חשוב, כי הבודקים צריכים את המק):
  > This app is a remote for presentations and needs the free companion Mac app, downloadable at <URL>.
  > To test: install the Mac app, grant Accessibility, open any slideshow (e.g. Keynote/Google Slides in full screen). On the iPhone choose the Mac and type the 6‑digit code shown on the Mac. Next/Previous send Right/Left arrow keys.
  > Volume-button control is optional, off by default, enabled only by the user in Settings, and only active while the app is open and connected. Buttons return to normal volume control when the app leaves the foreground.
  > A demo video is attached.

  כדאי לצרף סרטון קצר (30 שניות) שמראה את כל התהליך, כי זה מקצר מאוד את הבדיקה.

### טקסט לדף בחנות (עברית)
**כותרת משנה:** העבירו שקופיות מהאייפון

**תיאור:**
> קליקר הופך את האייפון לשלט למצגות במק.
> • כפתורים גדולים להבא ולקודם, עם רטט על כל לחיצה
> • אפשר להפעיל גם שליטה בכפתורי הווליום
> • מצב כיס: מסך כהה, וממשיכים להעביר שקופיות בלי להסתכל
> • עובד עם Keynote, PowerPoint, Google Slides, PDF וכל מצגת שמגיבה לחיצים
> • מתחבר דרך הרשת המקומית, בלי חשבון ובלי אינטרנט
> • הצמדה מאובטחת עם קוד, כך שרק האייפון שלכם שולט במצגת
>
> צריך את אפליקציית "קליקר למק", חינם להורדה: <URL>

**מילות מפתח:** מצגת,שקופיות,שלט,קליקר,keynote,powerpoint,הרצאה,presenter,remote,slides

## עדכון גרסה
מעלים את `CURRENT_PROJECT_VERSION` ב-[project.yml](ios-app/project.yml) (ואת `MARKETING_VERSION` לגרסה חדשה), ומריצים שוב את שני הסקריפטים.

## הגרסה האישית שלך
`./install-iphone.sh` ממשיך להתקין אצלך גרסה עם מצב "גם כשנעול" (אודיו שקט ברקע). המצב הזה **לא** נכנס לבניית האפסטור, ו-`release-ios.sh` עוצר אם הוא מוצא אותו.
