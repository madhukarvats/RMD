import SwiftUI

@main
struct RMDApp: App {
    @NSApplicationDelegateAdaptor private var app: AppDelegate

    init() {
        DevCommands.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(recorder: app.recorder)
        } label: {
            Image(systemName: app.recorder.isOn ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the recorder so links can switch it too: `open rmd://on`, `rmd://off` or `rmd://toggle`.
/// macOS hides menu bar icons that don't fit (behind the notch), so the icon isn't always there to click:
/// opening RMD again (Spotlight, Finder, `open RMD.app`) shows the same switch in a small window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = DayRecorder()
    private var window: NSWindow?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    private func showWindow() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: MenuView(recorder: recorder)))
            window.title = "RMD"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
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
