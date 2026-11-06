import Foundation

/// Notices calls: a call app (Zoom, Teams, Slack, WhatsApp, FaceTime, or a browser for Meet) using the
/// microphone. Checks every 2 s. A call counts as started after 2 checks in a row (the second one half a
/// second after the first, so less of the call's start is missed) and as over after 10 s without one, so
/// a quick mic test or a blip doesn't switch recording on and off.
@MainActor
final class CallWatcher {
    private var watching: Task<Void, Never>?

    /// `onChange` gets the call app when a call starts, and nil when it ends.
    func start(onChange: @escaping @MainActor (AudioDevices.CallApp?) -> Void) {
        watching = Task {
            var call: AudioDevices.CallApp?
            var seenInARow = 0
            var lastSeen = Date.distantPast
            while !Task.isCancelled {
                // Off the main thread: it is dozens of round trips to the audio system.
                let app = await Task.detached { AudioDevices.callAppUsingMicrophone() }.value
                if let app {
                    seenInARow += 1
                    lastSeen = .now
                    if call == nil, seenInARow >= 2 {
                        call = app
                        onChange(app)
                    }
                } else {
                    seenInARow = 0
                    if call != nil, Date.now.timeIntervalSince(lastSeen) >= 10 {
                        call = nil
                        onChange(nil)
                    }
                }
                try? await Task.sleep(for: call == nil && seenInARow == 1 ? .milliseconds(500) : .seconds(2))
            }
        }
    }
}
