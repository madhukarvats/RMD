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
/// yellow when RMD needs you (the microphone is stuck, or it couldn't start) and plain the rest of the time.
/// Opening the app again (Spotlight, Finder) opens the same menu. Links switch recording too:
/// `open rmd://on`, `rmd://off` or `rmd://toggle`, and so does double-tapping Fn. RMD opens at login,
/// so it's there to notice calls.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = DayRecorder()
    private let calls = CallWatcher()
    private let shortcut = DoubleTapShortcut()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !DevCommands.isRunning else { return }
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

    /// Adds RMD to Login Items the first time it runs. Only once: if the user removes it in
    /// System Settings → General → Login Items, it stays removed.
    private func openAtLogin() {
        let added = "addedToLoginItems"
        if !UserDefaults.standard.bool(forKey: added) {
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: added)
            } catch {
                print("RMD: couldn't add RMD to Login Items: \(error)")
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
        popover.contentViewController = NSHostingController(rootView: MenuView(recorder: recorder) { [weak self] resume in
            self?.restart(recording: resume)
        })
        popover.behavior = .transient
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
            statusItem?.button?.image = Self.icon(for: recorder.state)
            if ProcessInfo.processInfo.environment["RMD_DEBUG"] != nil {
                FileHandle.standardError.write(Data("icon for \(recorder.state)\n".utf8))
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.updateIcon() }
        }
    }

    private static func icon(for state: DayRecorder.State) -> NSImage? {
        let icon = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "RMD")
        let color: NSColor? = switch state {
        case .on: .systemGreen
        case .micStuck, .failed, .micDenied: .systemYellow
        case .off, .preparing: nil
        }
        guard let color else {
            icon?.isTemplate = true  // drawn in the menu bar's own colour
            return icon
        }
        let colored = icon?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
        colored?.isTemplate = false
        return colored
    }

    /// Starts a fresh copy of RMD and quits this one: after macOS's audio engine gets stuck in a process,
    /// only a new one gets the microphone back. `recording` switches the new copy on.
    private func restart(recording: Bool) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = recording ? [Self.resumeRecording] : []
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                print("RMD: couldn't start a new copy: \(error)")
            } else {
                exit(0)
            }
        }
    }

    private static let resumeRecording = "--resume-recording"

    @objc private func toggleMenu() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showMenu()
        }
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
