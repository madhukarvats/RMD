import AppKit
import Carbon.HIToolbox
import Observation

/// Double-tapping Fn (🌐), from any app, switches recording on or off. A tap is a quick press and release
/// with no other modifier key, so holding Fn or Fn-Control doesn't count; two taps within 0.4 s make a
/// double tap. Known gap: RMD never sees ordinary keys, so two quick Fn-Delete or Fn-arrow presses in a
/// row look like a double tap too.
///
/// Seeing Fn in other apps needs Input Monitoring (System Settings → Privacy & Security). RMD only listens
/// for modifier keys going up and down (Fn, ⌘, ⌥, ⌃, ⇧), never for typed keys. Until access is given,
/// RMD checks again every few seconds, so the shortcut starts working as soon as it's switched on.
@MainActor
@Observable
final class DoubleTapShortcut {
    /// False until macOS lets RMD see the Fn key (Input Monitoring); the menu offers to open Settings.
    private(set) var isListening = false

    private static let key = Int64(kVK_Function)
    private static let modifiers: CGEventFlags = [.maskSecondaryFn, .maskCommand, .maskAlternate, .maskControl, .maskShift]
    private static let longestTap: TimeInterval = 0.3
    private static let longestGap: TimeInterval = 0.4

    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var waitingForAccess: Task<Void, Never>?
    @ObservationIgnored private var pressedAt: Date?
    @ObservationIgnored private var lastTap = Date.distantPast
    @ObservationIgnored private var onDoubleTap: (() -> Void)?

    func start(onDoubleTap: @escaping @MainActor () -> Void) {
        self.onDoubleTap = onDoubleTap
        if CGPreflightListenEventAccess() {
            listen()
            return
        }
        CGRequestListenEventAccess()  // macOS asks once; later the switch is in System Settings
        waitingForAccess = Task {
            while !CGPreflightListenEventAccess() {
                try? await Task.sleep(for: .seconds(3))
            }
            listen()
        }
    }

    private func listen() {
        let callback: CGEventTapCallBack = { _, type, event, shortcut in
            if let shortcut {
                let me = Unmanaged<DoubleTapShortcut>.fromOpaque(shortcut).takeUnretainedValue()
                MainActor.assumeIsolated { me.handle(type, event) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.app.error("couldn't watch the Fn key")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        isListening = true
    }

    /// Called when the menu opens: access taken away in System Settings shows up as the "Allow…" link again.
    func recheckAccess() {
        if tap != nil { isListening = CGPreflightListenEventAccess() }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let held = event.flags.intersection(Self.modifiers)
        guard event.getIntegerValueField(.keyboardEventKeycode) == Self.key else {
            pressedAt = nil  // another modifier joined in: a shortcut like Fn-Control, not a tap
            lastTap = .distantPast
            return
        }
        if held == .maskSecondaryFn {
            pressedAt = .now
        } else if let pressedAt, held.isEmpty {
            self.pressedAt = nil
            guard Date.now.timeIntervalSince(pressedAt) <= Self.longestTap else {
                lastTap = .distantPast  // held, not tapped
                return
            }
            if Date.now.timeIntervalSince(lastTap) <= Self.longestGap {
                lastTap = .distantPast
                onDoubleTap?()
            } else {
                lastTap = .now
            }
        } else {
            pressedAt = nil
        }
    }
}
