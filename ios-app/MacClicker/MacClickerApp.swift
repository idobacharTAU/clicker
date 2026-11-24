import ServiceManagement
import SwiftUI

@main
struct MacClickerApp: App {
    @StateObject private var server = ClickerServer()

    var body: some Scene {
        // Shown at launch so first-time users see the code and the permission step.
        Window("קליקר", id: "main") {
            ServerPanel(server: server, showsQuit: false)
                .frame(width: 360)
                .environment(\.layoutDirection, .rightToLeft)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            ServerPanel(server: server, showsQuit: true)
                .frame(width: 340)
                .environment(\.layoutDirection, .rightToLeft)
        } label: {
            Image(systemName: menuIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuIcon: String {
        if !server.accessibilityGranted { return "exclamationmark.triangle" }
        return server.sessions.contains { $0.authenticated } ? "play.rectangle.fill" : "play.rectangle"
    }
}

struct ServerPanel: View {
    @ObservedObject var server: ClickerServer
    let showsQuit: Bool
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !server.accessibilityGranted { accessibilityCard }
            pairingCard
            devicesSection
            Divider()
            footer
        }
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("קליקר למצגות").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if server.commandCount > 0 {
                Text("\(server.commandCount)")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .help("שקופיות שהועברו מאז ההפעלה")
            }
        }
    }

    private var accessibilityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("צריך הרשאת נגישות", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)
            Text("בלי ההרשאה הזו אי אפשר להעביר שקופיות. בהגדרות המערכת ← פרטיות ואבטחה ← נגישות, להפעיל את \"קליקר\".")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("פתיחת ההגדרות") { server.requestAccessibility() }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var pairingCard: some View {
        VStack(spacing: 6) {
            Text("קוד חיבור לאייפון").font(.caption).foregroundStyle(.secondary)
            Text(spaced(server.pairingCode))
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .environment(\.layoutDirection, .leftToRight)
                .textSelection(.enabled)
            Text("פותחים את \"קליקר\" באייפון, בוחרים את המק הזה ומקלידים את הקוד.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("קוד חדש") { server.newPairingCode() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var devicesSection: some View {
        if !server.pairedDevices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("מכשירים מוצמדים").font(.caption).foregroundStyle(.secondary)
                ForEach(server.pairedDevices) { device in
                    HStack {
                        Image(systemName: "iphone")
                        Text(device.name).lineLimit(1)
                        if isOnline(device) {
                            Text("מחובר").font(.caption2).foregroundStyle(.green)
                        }
                        Spacer()
                        Button(role: .destructive) { server.forget(device) } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("ביטול ההצמדה")
                    }
                    .font(.callout)
                }
            }
        }
        if let event = server.lastEvent {
            Text(event).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var footer: some View {
        HStack {
            Toggle("הפעלה עם הכניסה למחשב", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
            if showsQuit {
                Button("חלון") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                    .font(.caption)
                Button("יציאה") { NSApp.terminate(nil) }
                    .font(.caption)
            }
        }
    }

    // MARK: Helpers

    private func isOnline(_ device: ClickerServer.PairedDevice) -> Bool {
        server.sessions.contains { $0.authenticated && $0.name == device.name }
    }

    private func spaced(_ code: String) -> String {
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        // Left-to-right isolate: in an RTL layout "123 456" would otherwise render as "456 123".
        return "\u{2066}\(code[..<mid])\u{2009}\(code[mid...])\u{2069}"
    }

    private var statusColor: Color {
        switch server.listenerState {
        case .ready: return server.accessibilityGranted ? .green : .orange
        case .starting: return .yellow
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch server.listenerState {
        case .starting: return "מתחיל..."
        case .failed: return "שגיאת רשת, מנסה שוב..."
        case .ready:
            let live = server.sessions.filter(\.authenticated).count
            return live > 0 ? "\(live) מכשיר מחובר" : "ממתין לאייפון · המק מופיע בשם \"\(server.serviceName)\""
        }
    }
}
