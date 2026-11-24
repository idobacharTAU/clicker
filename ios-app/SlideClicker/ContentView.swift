import SwiftUI
import UIKit

enum AppLinks {
    /// Where people download the free Mac companion app.
    static let macDownload = URL(string: "https://github.com/idobacharTAU/clicker/releases/latest")!
    static let macDownloadLabel = "github.com/idobacharTAU/clicker"
}

struct ContentView: View {
    @StateObject private var client = ClickerClient()
    @StateObject private var volume = VolumeButtonObserver()
    #if PERSONAL_BUILD
    @StateObject private var lock = LockMonitor()
    @AppStorage("keepAliveWhenLocked") private var keepAliveWhenLocked = false
    #endif
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("volumeButtonsEnabled") private var volumeButtonsEnabled = false
    @State private var commandCount = 0
    @State private var flash = false
    @State private var pocketMode = false
    @State private var savedBrightness: CGFloat?
    @State private var showSettings = false

    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private let warningHaptic = UINotificationFeedbackGenerator()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch client.status {
            case .searching, .chooseMac, .noPermission:
                MacPickerView(client: client)
            case let .needsCode(name):
                CodeEntryView(client: client, macName: name)
            case .connecting, .connected:
                clicker
            }

            if pocketMode { pocketOverlay }

            // Must be in the hierarchy (not hidden) so iOS shows no volume HUD.
            VolumeViewHost(observer: volume)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            volume.onPress = { direction in fire(direction == .up ? "next" : "prev") }
            #if PERSONAL_BUILD
            volume.keepAliveWhenLocked = keepAliveWhenLocked
            lock.appBecameActive()
            #endif
            volume.activate()
            client.start()
            haptic.prepare()
            updateArming()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                UIApplication.shared.isIdleTimerDisabled = true
                #if PERSONAL_BUILD
                lock.appBecameActive()
                #endif
                volume.activate()
                client.refresh()
                if pocketMode { dimScreen() }
            case .background:
                restoreBrightness()
                #if PERSONAL_BUILD
                lock.appEnteredBackground()
                #endif
                // Make sure the user's volume is restored before iOS suspends us.
                let task = UIApplication.shared.beginBackgroundTask()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    UIApplication.shared.endBackgroundTask(task)
                }
            default:
                break
            }
            updateArming()
        }
        .onChange(of: volumeButtonsEnabled) { _, _ in updateArming() }
        .onChange(of: client.status) { _, _ in updateArming() }
        #if PERSONAL_BUILD
        .onChange(of: keepAliveWhenLocked) { _, newValue in
            volume.keepAliveWhenLocked = newValue
            updateArming()
        }
        .onChange(of: lock.mayBeLocked) { _, _ in updateArming() }
        #endif
        .statusBarHidden(pocketMode)
        .persistentSystemOverlays(pocketMode ? .hidden : .automatic)
    }

    // MARK: Main clicker screen

    private var clicker: some View {
        VStack(spacing: 16) {
            statusBar
            Spacer(minLength: 0)
            Text("\(commandCount)")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .scaleEffect(flash ? 1.12 : 1)
                .animation(.spring(duration: 0.2), value: flash)
                .accessibilityLabel("\(commandCount) פקודות נשלחו")
            bigButton(title: "הבא", icon: "chevron.right", color: .green, height: 220) { fire("next") }
            bigButton(title: "הקודם", icon: "chevron.left", color: .orange, height: 110) { fire("prev") }
            HStack {
                Button { enterPocketMode() } label: {
                    Label("מצב כיס", systemImage: "moon.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(.indigo)
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle().fill(isConnected ? Color.green : .yellow).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.headline).lineLimit(1)
                if volumeButtonsEnabled && isConnected {
                    Text(volume.isArmed ? "כפתורי הווליום מעבירים שקופיות" : "כפתורי הווליום רגילים")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isConnected { ProgressView().tint(.white) }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title2)
            }
            .accessibilityLabel("הגדרות")
        }
        .padding(14)
        .background((isConnected ? Color.green : .yellow).opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
    }

    private var hint: String {
        volumeButtonsEnabled
            ? "אפשר גם בכפתורי הווליום: למעלה = הבא, למטה = הקודם"
            : "פותחים את המצגת במק, נכנסים למסך מלא ולוחצים עליה פעם אחת"
    }

    private func bigButton(title: String, icon: String, color: Color, height: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 36, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: height)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 28))
        .tint(color)
        .disabled(!isConnected)
    }

    // MARK: Settings

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("שליטה בכפתורי הווליום", isOn: $volumeButtonsEnabled)
                } footer: {
                    Text("כשהאפשרות פועלת והאפליקציה פתוחה ומחוברת, עוצמה למעלה = הבא ועוצמה למטה = הקודם. כשיוצאים מהאפליקציה הכפתורים חוזרים לפעול כרגיל.")
                }
                #if PERSONAL_BUILD
                Section {
                    Toggle("גם כשהאייפון נעול (ניסיוני)", isOn: $keepAliveWhenLocked)
                        .disabled(!volumeButtonsEnabled)
                } footer: {
                    Text("גרסה אישית בלבד, לא קיים בגרסת האפסטור.")
                }
                #endif
                Section {
                    if case let .connected(name) = client.status {
                        LabeledContent("מחובר ל", value: name)
                    }
                    Button("החלפת מק") { showSettings = false; client.showMacList() }
                    Button("ביטול ההצמדה למק הזה", role: .destructive) { showSettings = false; client.unpairCurrent() }
                }
                Section("איך משתמשים") {
                    Text("1. מתקינים במק את \"קליקר למק\" (חינם) ומאשרים לו הרשאת נגישות.")
                    Text("2. האייפון והמק על אותה רשת Wi‑Fi, או ש-Wi‑Fi ו-Bluetooth דלוקים בשניהם.")
                    Text("3. במצגת: מסך מלא ולחיצה אחת בתוכה כדי שהחלון יהיה בפוקוס.")
                    Link("להורדת האפליקציה למק", destination: AppLinks.macDownload)
                }
            }
            .navigationTitle("הגדרות")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("סיום") { showSettings = false } }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .preferredColorScheme(.dark)
    }

    // MARK: Pocket mode

    /// Black overlay at minimum brightness.
    /// With volume control on: touches are ignored (buttons do the work).
    /// Without it: tap = next, swipe = previous. Long press exits in both cases.
    private var pocketOverlay: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                Text("\(commandCount)")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Circle().fill((isConnected ? Color.green : .yellow).opacity(0.35)).frame(width: 10, height: 10)
                Text(volumeButtonsEnabled
                     ? "לחיצה ארוכה ליציאה"
                     : "הקשה = הבא · החלקה = הקודם\nלחיצה ארוכה ליציאה")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.18))
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.8) { exitPocketMode() }
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                guard !volumeButtonsEnabled, abs(value.translation.width) > abs(value.translation.height) else { return }
                fire("prev")
            }
        )
        .onTapGesture { if !volumeButtonsEnabled { fire("next") } }
        .transition(.opacity)
    }

    private var screen: UIScreen? {
        (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?.screen
    }

    private func enterPocketMode() {
        withAnimation(.easeInOut(duration: 0.25)) { pocketMode = true }
        haptic.impactOccurred()
        dimScreen()
    }

    private func exitPocketMode() {
        withAnimation(.easeInOut(duration: 0.25)) { pocketMode = false }
        restoreBrightness()
        haptic.impactOccurred()
    }

    private func dimScreen() {
        guard let screen else { return }
        if savedBrightness == nil { savedBrightness = screen.brightness }
        screen.brightness = 0
    }

    private func restoreBrightness() {
        guard let screen, let saved = savedBrightness else { return }
        screen.brightness = saved
        savedBrightness = nil
    }

    // MARK: Arming

    /// The volume buttons control the slides only if the user turned that on, while connected,
    /// and while this app is on screen (personal build: also while locked).
    private func updateArming() {
        guard volumeButtonsEnabled else { return volume.setArmed(false) }
        let foreground = scenePhase == .active
        #if PERSONAL_BUILD
        let lockedMode = keepAliveWhenLocked && !foreground && lock.mayBeLocked
        #else
        let lockedMode = false
        #endif
        volume.setArmed(isConnected && (foreground || lockedMode))
    }

    // MARK: Logic

    private func fire(_ command: String) {
        if client.send(command) {
            commandCount += 1
            haptic.impactOccurred()
            haptic.prepare()
            flash.toggle()
        } else {
            warningHaptic.notificationOccurred(.error)
        }
    }

    private var isConnected: Bool {
        if case .connected = client.status { return true }
        return false
    }

    private var statusTitle: String {
        switch client.status {
        case let .connected(name): return "מחובר ל-\(name)"
        case let .connecting(name): return "מתחבר ל-\(name)..."
        default: return "מחפש..."
        }
    }
}

// MARK: - Choose a Mac

struct MacPickerView: View {
    @ObservedObject var client: ClickerClient

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("בחירת מק").font(.largeTitle.bold())

            if client.status == .noPermission {
                VStack(spacing: 12) {
                    Text("לאפליקציה אין גישה לרשת המקומית, ולכן היא לא יכולה למצוא את המק.")
                        .multilineTextAlignment(.center)
                    Text("הגדרות ← פרטיות ואבטחה ← רשת מקומית ← להפעיל את \"קליקר\"")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("פתיחת ההגדרות") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if client.macs.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("מחפש מק עם אפליקציית קליקר...")
                    Text("צריך להתקין במק את \"קליקר למק\" (חינם) ולהפעיל אותו. האייפון והמק צריכים להיות על אותה רשת Wi‑Fi.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Link("להורדה: \(AppLinks.macDownloadLabel)", destination: AppLinks.macDownload)
                        .font(.callout)
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(client.macs) { mac in
                        Button { client.choose(mac) } label: {
                            HStack {
                                Image(systemName: "laptopcomputer")
                                Text(mac.name).lineLimit(1)
                                Spacer()
                                if mac.isPaired { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                                Image(systemName: "chevron.left").foregroundStyle(.secondary)
                            }
                            .font(.title3)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer()
            Spacer()
        }
        .padding(24)
    }
}

// MARK: - Enter the Mac's code

struct CodeEntryView: View {
    @ObservedObject var client: ClickerClient
    let macName: String
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.shield").font(.system(size: 56)).foregroundStyle(.tint)
            Text("חיבור ל-\(macName)").font(.title.bold()).multilineTextAlignment(.center)
            Text("הקלידו את הקוד בן \(ClickerProtocol.codeLength) הספרות שמופיע במק, בחלון של קליקר או בתפריט העליון.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .environment(\.layoutDirection, .leftToRight)
                .focused($focused)
                .padding()
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .onChange(of: code) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(ClickerProtocol.codeLength))
                    if digits != newValue { code = digits }
                    if digits.count == ClickerProtocol.codeLength { client.submitCode(digits) }
                }
            if let error = client.pairingError {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Button("מק אחר") { client.showMacList() }
            Spacer()
            Spacer()
        }
        .padding(24)
        .onAppear { focused = true }
        .onChange(of: client.pairingError) { _, error in if error != nil { code = "" } }
    }
}

#Preview {
    ContentView()
        .environment(\.layoutDirection, .rightToLeft)
}
