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

/// RMD lives only in the menu bar: its icon opens the switch and Quit. Opening the app again (Spotlight,
/// Finder) opens the same menu. Links switch recording too: `open rmd://on`, `rmd://off` or `rmd://toggle`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = DayRecorder()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !DevCommands.isRunning else { return }
        addMenuBarIcon()
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
        let icon = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "RMD")
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.target = self
        item.button?.action = #selector(toggleMenu)
        popover.contentViewController = NSHostingController(rootView: MenuView(recorder: recorder))
        popover.behavior = .transient
        statusItem = item

        if ProcessInfo.processInfo.environment["RMD_DEBUG"] != nil {
            Task {
                try? await Task.sleep(for: .seconds(1))
                let window = item.button?.window
                let report = "menu bar icon at x \(Int(window?.frame.minX ?? -1)), \(window?.occlusionState.contains(.visible) == true ? "visible" : "hidden")\n"
                FileHandle.standardError.write(Data(report.utf8))
            }
        }
    }

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
