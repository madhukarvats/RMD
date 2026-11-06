import ServiceManagement
import SwiftUI

@main
struct RMDApp: App {
    @NSApplicationDelegateAdaptor private var app: AppDelegate

    init() {
        DevCommands.runIfRequested()
    }

    var body: some Scene {
        // The menu bar icon is made in AppDelegate (it needs a fixed name to keep its place); SwiftUI needs a scene.
        MenuBarExtra("RMD", systemImage: "waveform.circle", isInserted: .constant(false)) { EmptyView() }
    }
}

/// RMD lives only in the menu bar: its icon opens the switch and Quit. The icon is green while recording,
/// yellow when RMD needs you (the microphone is stuck, it couldn't start, or part of a call isn't being
/// heard) and plain the rest of the time. Opening the app again (Spotlight, Finder) opens the same menu.
/// Links switch recording too: `open rmd://on`, `rmd://off` or `rmd://toggle`, and so does double-tapping Fn.
/// RMD opens at login, so it's there to notice calls.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let recorder = DayRecorder()
    private let calls = CallWatcher()
    private let shortcut = DoubleTapShortcut()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var appBeforeMenu: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !DevCommands.isRunning else { return }
        guard isOnlyCopy() else {
            FileHandle.standardError.write(Data("RMD is already running.\n".utf8))
            exit(0)
        }
        addMenuBarIcon()
        openAtLogin()
        calls.start { [recorder] app in
            Task { await recorder.callChanged(to: app) }
        }
        shortcut.start { [recorder] in
            Task { await recorder.setOn(!recorder.isOn) }
        }
        if CommandLine.arguments.contains(Self.resumeRecording) {
            Task { await recorder.setOn(true) }
        }
    }

    /// Two copies would each save every line. A copy started by "Restart RMD" is let through: the old one
    /// is on its way out. Copies running a dev command (`--transcribe`) show no icon and don't count.
    private func isOnlyCopy() -> Bool {
        if CommandLine.arguments.contains(Self.restarted) { return true }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0 != .current && $0.activationPolicy != .prohibited }
    }

    /// Quit, log out or shut down: first save what was already heard. Never for long, so a logout isn't held up.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !DevCommands.isRunning else { return .terminateNow }
        Task {
            await finishSaving(within: .seconds(10))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Waits for the recorder to save what it heard, or for `limit`, whichever comes first. (A task group
    /// would wait for both: saving can't be cancelled, and can take minutes while the model still loads.)
    private func finishSaving(within limit: Duration) async {
        let (finished, signal) = AsyncStream.makeStream(of: Void.self)
        Task { await recorder.finish(); signal.yield() }
        let timer = Task { try? await Task.sleep(for: limit); signal.yield() }
        for await _ in finished { break }
        timer.cancel()
    }

    /// Adds RMD to Login Items the first time it runs. Only once: if the user removes it in
    /// System Settings → General → Login Items, it stays removed.
    private func openAtLogin() {
        let added = "addedToLoginItems"
        if !UserDefaults.standard.bool(forKey: added) {
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: added)
            } catch {
                Log.app.error("couldn't add RMD to Login Items: \(String(describing: error), privacy: .public)")
            }
        }
        if ProcessInfo.processInfo.environment["RMD_DEBUG"] != nil {
            FileHandle.standardError.write(Data("login item: \(SMAppService.mainApp.status)\n".utf8))
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenu()
        return false
    }

    /// New menu bar icons go on the far left of the others, which on a full menu bar is behind the notch.
    /// So RMD's icon starts near the right end instead, next to Control Center (positions count from the
    /// right edge). Once the user ⌘-drags it somewhere else, macOS remembers that spot instead.
    private func addMenuBarIcon() {
        UserDefaults.standard.register(defaults: ["NSStatusItem Preferred Position RMD": 320])
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "RMD"
        item.button?.target = self
        item.button?.action = #selector(toggleMenu)
        popover.contentViewController = NSHostingController(rootView: MenuView(recorder: recorder, shortcut: shortcut) { [weak self] resume in
            self?.restart(recording: resume, inBackground: false)
        })
        popover.behavior = .transient
        popover.delegate = self
        statusItem = item
        updateIcon()

        if ProcessInfo.processInfo.environment["RMD_DEBUG"] != nil {
            Task {
                try? await Task.sleep(for: .seconds(1))
                let window = item.button?.window
                let report = "menu bar icon at x \(Int(window?.frame.minX ?? -1)), \(window?.occlusionState.contains(.visible) == true ? "visible" : "hidden")\n"
                FileHandle.standardError.write(Data(report.utf8))
            }
        }
    }

    /// Redraws the icon now and again whenever the recorder's state changes.
    private func updateIcon() {
        withObservationTracking {
            let needsYou = recorder.isOn && recorder.trouble != nil  // .on or .preparing
            let words = Self.words(for: recorder.state, needsYou: needsYou)
            statusItem?.button?.image = Self.icon(for: recorder.state, needsYou: needsYou, saying: words)
            statusItem?.button?.toolTip = words
            if ProcessInfo.processInfo.environment["RMD_DEBUG"] != nil {
                FileHandle.standardError.write(Data("icon for \(recorder.state)\(needsYou ? ", trouble: \(recorder.trouble ?? "")" : "")\n".utf8))
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.updateIcon() }
        }
        if case .micStuck(let resume) = recorder.state { restartOnce(recording: resume) }
    }

    /// Green and yellow are filled discs: an outline in those colours all but disappears on a light menu bar.
    private static func icon(for state: DayRecorder.State, needsYou: Bool, saying words: String) -> NSImage? {
        let colors: [NSColor]? = switch state {
        case .micStuck, .failed, .micDenied: [.black, .systemYellow]
        case .on: needsYou ? [.black, .systemYellow] : [.white, .systemGreen]
        case .preparing: needsYou ? [.black, .systemYellow] : nil
        case .off: nil
        }
        guard let colors else {
            let icon = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: words)
            icon?.isTemplate = true  // drawn in the menu bar's own colour
            return icon
        }
        let icon = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: words)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: colors))
        icon?.isTemplate = false
        return icon
    }

    /// The tooltip, and what VoiceOver says for the icon.
    private static func words(for state: DayRecorder.State, needsYou: Bool) -> String {
        switch state {
        case .off: "RMD is off"
        case .preparing: needsYou ? "RMD needs you: click to see why" : "RMD is starting"
        case .on(let since):
            needsYou ? "RMD needs you: click to see why"
                : "RMD is recording since \(since.formatted(date: .omitted, time: .shortened))"
        case .micDenied, .failed, .micStuck: "RMD needs you: click to see why"
        }
    }

    /// A stuck microphone only comes back in a new process, so RMD starts one straight away rather than
    /// wait for the user to notice a yellow icon (in a full-screen call the menu bar is hidden). Not twice
    /// within 10 minutes: if the new copy sticks too, the yellow icon and "Restart RMD" in the menu remain.
    private func restartOnce(recording: Bool) {
        let last = UserDefaults.standard.double(forKey: "restartedAt")
        guard Date.now.timeIntervalSince1970 - last > 600 else { return }
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "restartedAt")
        restart(recording: recording, inBackground: true)
    }

    /// Starts a fresh copy of RMD and quits this one: after macOS's audio engine gets stuck in a process,
    /// only a new one gets the microphone back. `recording` switches the new copy on; `inBackground` keeps
    /// it from taking the keyboard away from the call app.
    private func restart(recording: Bool, inBackground: Bool) {
        guard !restarting else { return }  // a second click, or a click during the automatic restart
        restarting = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = !inBackground
        configuration.arguments = [Self.restarted] + (recording ? [Self.resumeRecording] : [])
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                Log.app.error("couldn't start a new copy of RMD: \(String(describing: error), privacy: .public)")
                Task { @MainActor in self.restarting = false }
                return
            }
            Task { @MainActor in
                await self.finishSaving(within: .seconds(5))
                exit(0)
            }
        }
    }

    private var restarting = false
    private static let resumeRecording = "--resume-recording"
    private static let restarted = "--restarted"

    @objc private func toggleMenu() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showMenu()
        }
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        recorder.recheckMicAccess()
        shortcut.recheckAccess()
        appBeforeMenu = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Esc or a second click on the icon closes the menu without choosing another app: hand the keyboard
    /// back to the app that had it, so typing carries on where it was.
    func popoverDidClose(_ notification: Notification) {
        guard NSApp.isActive, let app = appBeforeMenu, app != .current, !app.isTerminated else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "rmd" {
            let on: Bool? = switch url.host() {
            case "on": true
            case "off": false
            case "toggle": !recorder.isOn
            default: nil
            }
            if let on {
                Task { await recorder.setOn(on) }
            }
        }
    }
}
