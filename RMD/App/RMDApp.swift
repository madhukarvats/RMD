import SwiftUI

@main
struct RMDApp: App {
    @State private var recorder = DayRecorder()

    init() {
        DevCommands.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(recorder: recorder)
        } label: {
            Image(systemName: recorder.isOn ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
