import AppKit
import SwiftUI

/// Just the switch, one status line and Quit. The transcript itself is read through Claude via the MCP server.
struct MenuView: View {
    let recorder: DayRecorder
    let shortcut: DoubleTapShortcut
    /// Starts a fresh copy of RMD (recording again if the argument is true) and quits this one.
    let restart: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Record My Day").font(.headline)
                Spacer()
                Toggle("Record My Day", isOn: Binding(
                    get: { recorder.isOn },
                    set: { on in Task { await recorder.setOn(on) } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(stuck != nil)  // only a restart helps
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(dot)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    if recorder.state == .micDenied {
                        Button("Open Settings…") { open("Privacy_Microphone") }
                            .controlSize(.small)
                            .padding(.top, 3)
                    }
                    if let stuck {
                        Button("Restart RMD") { restart(stuck) }
                            .controlSize(.small)
                            .padding(.top, 3)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)

            Divider()

            HStack {
                if shortcut.isListening {
                    Text("Double-tap Fn to switch").foregroundStyle(.tertiary)
                } else {
                    Button("Allow double-tap Fn…") { open("Privacy_ListenEvent") }
                        .buttonStyle(.link)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("q")
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 260)
    }

    /// The same colour as the menu bar icon.
    private var dot: Color {
        switch recorder.state {
        case .on: Color(nsColor: recorder.trouble == nil ? .systemGreen : .systemYellow)
        case .micDenied, .failed, .micStuck: Color(nsColor: .systemYellow)
        case .preparing: Color(nsColor: recorder.trouble == nil ? .tertiaryLabelColor : .systemYellow)
        case .off: Color(nsColor: .tertiaryLabelColor)
        }
    }

    private var title: String {
        switch recorder.state {
        case .off: recorder.inCall ? "Off for this call" : "Off"
        case .preparing(let message): message
        case .on(let since):
            recorder.startedForCall ? "Recording this call"
                : "Listening since \(since.formatted(date: .omitted, time: .shortened))"
        case .micDenied: "Microphone access is off"
        case .failed: "Couldn't start"
        case .micStuck: "Microphone stuck in macOS"
        }
    }

    private var detail: String? {
        switch recorder.state {
        case .off: recorder.inCall ? nil : "Calls are still recorded"
        case .preparing: recorder.trouble ?? (recorder.isListening ? "Already listening" : nil)
        case .on:
            if let trouble = recorder.trouble { trouble }
            else if recorder.startedForCall { "Stops by itself when the call ends" }
            else if recorder.inCall { "On a call: both sides are recorded" }
            else { nil }
        case .micDenied: nil
        case .failed(let message): message
        case .micStuck: "RMD has to restart to get it back"
        }
    }

    /// Whether to record again after the restart, when the microphone is stuck.
    private var stuck: Bool? {
        if case .micStuck(let resume) = recorder.state { resume } else { nil }
    }

    private func open(_ privacyPane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacyPane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
