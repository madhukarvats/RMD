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
/// macOS hides menu bar icons that don't fit (behind the notch), so the icon isn't always there to click.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = DayRecorder()

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
