import AppKit
import SwiftUI

/// Just the switch. The transcript itself is read through Claude via the MCP server.
struct MenuView: View {
    let recorder: DayRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { recorder.isOn },
                set: { on in Task { await recorder.setOn(on) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record My Day").font(.headline)
                    status.font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Divider()

            Button("Quit RMD") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 260)
    }

    @ViewBuilder
    private var status: some View {
        switch recorder.state {
        case .off:
            Text("Off")
        case .preparing(let message):
            Text(message)
        case .on(let since):
            Text("Listening since \(since, style: .time)")
        case .micDenied:
            Button("Microphone access is off — open Settings") {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.link)
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        }
    }
}
