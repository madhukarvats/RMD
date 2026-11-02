import Foundation

/// Notices calls: a call app (Zoom, Teams, Slack, WhatsApp, FaceTime, or a browser for Meet) using the
/// microphone. Checks every 2 s. A call counts as started after 2 checks in a row and as over after 10 s
/// without one, so a quick mic test or a blip doesn't switch recording on and off.
@MainActor
final class CallWatcher {
    private var watching: Task<Void, Never>?

    /// `onChange` gets the call app's bundle ID when a call starts, and nil when it ends.
    func start(onChange: @escaping @MainActor (String?) -> Void) {
        watching = Task {
            var call: String?
            var seenInARow = 0
            var lastSeen = Date.distantPast
            while !Task.isCancelled {
                if let app = AudioDevices.callAppUsingMicrophone() {
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
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
