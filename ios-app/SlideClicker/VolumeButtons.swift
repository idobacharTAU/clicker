import AVFoundation
import MediaPlayer
#if PERSONAL_BUILD
import notify
import LocalAuthentication
#endif
import SwiftUI
import UIKit

/// Optional: the user turns this on in the app. Off by default.
/// Detects hardware volume-button presses via KVO on AVAudioSession.outputVolume.
///
/// Presses are only intercepted while the observer is *armed* (connected to the Mac and
/// presenting). While armed, the volume is reset to 0.5 after every press through a
/// (practically invisible) MPVolumeView slider, so presses keep working at the extremes and
/// the system volume HUD stays hidden; the KVO event caused by that reset is ignored.
/// When disarmed, the user's own volume is restored and the buttons behave normally.
final class VolumeButtonObserver: ObservableObject {
    enum Direction { case up, down }

    var onPress: ((Direction) -> Void)?

    /// Experimental: keep running while the screen is locked by playing silent audio
    /// (UIBackgroundModes = audio). Uses the .playback category instead of .ambient.
    /// Only the personal (non-App Store) build can keep running while locked.
    var keepAliveWhenLocked = false {
        didSet { if oldValue != keepAliveWhenLocked { activate() } }
    }

    /// Current system volume (0...1), for the small diagnostic readout.
    @Published private(set) var systemVolume: Float = neutralVolume
    /// Whether the volume buttons currently control the slides.
    @Published private(set) var isArmed = false

    #if PERSONAL_BUILD
    private let silence = SilentAudioLoop()
    #endif

    static let neutralVolume: Float = 0.5

    /// The MPVolumeView must live in the visible view hierarchy (see VolumeViewHost).
    let volumeView: MPVolumeView = {
        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 120, height: 40))
        view.alpha = 0.0001
        view.isUserInteractionEnabled = false
        return view
    }()

    private let session = AVAudioSession.sharedInstance()
    private var observation: NSKeyValueObservation?
    private var lastVolume: Float = neutralVolume
    /// Volume we are programmatically moving to, and until when to expect its KVO echo.
    private var pendingTarget: Float?
    private var pendingUntil: Date?
    /// The user's own volume before we took over the buttons; restored on disarm.
    private var savedUserVolume: Float?
    private var interruptionToken: NSObjectProtocol?

    private var slider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    init() {
        interruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.ended.rawValue { self?.activate() }
        }
    }

    deinit {
        observation?.invalidate()
        if let interruptionToken { NotificationCenter.default.removeObserver(interruptionToken) }
    }

    /// (Re)activates the audio session and KVO. Call on launch and whenever the scene becomes active.
    func activate() {
        #if PERSONAL_BUILD
        let lockedMode = keepAliveWhenLocked
        #else
        let lockedMode = false
        #endif
        do {
            try session.setCategory(lockedMode ? .playback : .ambient, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("AVAudioSession error: \(error)")
        }
        #if PERSONAL_BUILD
        if lockedMode { silence.start() } else { silence.stop() }
        #endif

        observation?.invalidate()
        lastVolume = session.outputVolume
        systemVolume = lastVolume
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            DispatchQueue.main.async { self?.volumeChanged(to: value) }
        }

        if isArmed {
            // Give MPVolumeView a moment to attach to the audio route before resetting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.isArmed else { return }
                self.move(to: Self.neutralVolume)
            }
        }
    }

    /// Take over the volume buttons (true) or give them back and restore the user's volume (false).
    func setArmed(_ armed: Bool) {
        guard armed != isArmed else { return }
        isArmed = armed
        if armed {
            savedUserVolume = session.outputVolume
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.isArmed else { return }
                self.move(to: Self.neutralVolume)
            }
        } else if let saved = savedUserVolume {
            savedUserVolume = nil
            move(to: saved)
        }
    }

    private func volumeChanged(to value: Float) {
        systemVolume = value

        // Ignore the change produced by our own reset / restore.
        if let target = pendingTarget, let until = pendingUntil {
            if Date() > until {
                pendingTarget = nil
                pendingUntil = nil
            } else if abs(value - target) < 0.01 {
                pendingTarget = nil
                pendingUntil = nil
                lastVolume = value
                return
            }
        }

        let delta = value - lastVolume
        lastVolume = value
        guard isArmed else { return } // buttons behave normally

        // In the background, let the buttons control other audio (music, video) normally.
        if UIApplication.shared.applicationState != .active && session.isOtherAudioPlaying {
            savedUserVolume = value
            return
        }

        if delta > 0.001 {
            onPress?(.up)
        } else if delta < -0.001 {
            onPress?(.down)
        } else {
            return
        }
        move(to: Self.neutralVolume)
    }

    /// Sets the system volume through the MPVolumeView slider.
    private func move(to target: Float) {
        let current = session.outputVolume
        lastVolume = current
        guard abs(current - target) > 0.001 else { return }
        pendingTarget = target
        pendingUntil = Date().addingTimeInterval(1.0)
        // Setting the value immediately inside the KVO callback is sometimes ignored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            if let slider = self.slider {
                slider.setValue(target, animated: false)
            } else {
                self.pendingTarget = nil
                self.pendingUntil = nil
            }
        }
    }
}

#if PERSONAL_BUILD
/// Decides whether, while the app is in the background, the phone may be locked
/// (→ keep controlling the slides) or is being used unlocked (→ give the volume back).
///
/// There is no public "screen locked" API. We use data protection instead: about 10 s after
/// the phone locks (with a passcode), protected data becomes unavailable. So after entering
/// the background we stay armed, and if protected data is *still* available 20 s later the
/// user is on the home screen / in another app, and the volume buttons are released.
final class LockMonitor: ObservableObject {
    @Published private(set) var mayBeLocked = true
    var onChange: ((String) -> Void)?

    private var check: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var darwinToken: Int32 = 0
    private let hasPasscode = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.markLocked("locked (protected data off)") })
        observers.append(center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onChange?("unlocked (protected data on)")
            // Still unlocked and away from the app for a minute → release the buttons.
            if UIApplication.shared.applicationState != .active { self.scheduleCheck(after: 60) }
        })
        // Faster signal on iOS versions that still deliver it (harmless otherwise).
        notify_register_dispatch("com.apple.springboard.lockcomplete", &darwinToken, .main) { [weak self] _ in
            self?.markLocked("locked (lockcomplete)")
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        notify_cancel(darwinToken)
    }

    func appBecameActive() {
        check?.cancel()
        mayBeLocked = true
    }

    func appEnteredBackground() {
        mayBeLocked = true
        if hasPasscode {
            scheduleCheck(after: 20)
        } else {
            onChange?("no passcode: cannot detect lock, staying armed")
        }
    }

    private func scheduleCheck(after seconds: Double) {
        check?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if UIApplication.shared.isProtectedDataAvailable && UIApplication.shared.applicationState != .active {
                self.mayBeLocked = false
                self.onChange?("not locked for \(Int(seconds))s: volume buttons released")
            }
        }
        check = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func markLocked(_ source: String) {
        check?.cancel()
        mayBeLocked = true
        onChange?(source)
    }
}

/// Plays an endless buffer of silence so iOS keeps the app running (and KVO firing)
/// while the screen is locked. Mixes with other audio, so nothing else is interrupted.
final class SilentAudioLoop {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var configured = false
    private var configToken: NSObjectProtocol?

    func start() {
        if !configured {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
            buffer.frameLength = buffer.frameCapacity // zero-filled = silence
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            configToken = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in self?.restart() }
            configured = true
        }
        restart()
    }

    func stop() {
        guard configured else { return }
        player.stop()
        engine.stop()
        configured = false
        engine.detach(player)
        if let configToken { NotificationCenter.default.removeObserver(configToken) }
        configToken = nil
    }

    private func restart() {
        guard configured else { return }
        do {
            if !engine.isRunning { try engine.start() }
            if !player.isPlaying { player.play() }
        } catch {
            print("silent audio error: \(error)")
        }
    }
}

#endif

/// Puts the observer's MPVolumeView into the SwiftUI hierarchy: not hidden, alpha ≈ 0, off-screen.
struct VolumeViewHost: UIViewRepresentable {
    let observer: VolumeButtonObserver

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        container.clipsToBounds = false
        container.isUserInteractionEnabled = false
        container.addSubview(observer.volumeView)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
