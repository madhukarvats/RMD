import CoreAudio
import Foundation

/// Small helpers over Core Audio's C API: device changes, the current speaker, and which apps use the mic.
enum AudioDevices {
    struct CoreAudioError: LocalizedError, CustomStringConvertible {
        let status: OSStatus
        let what: String
        var description: String { "couldn't \(what) (Core Audio error \(status))" }
        var errorDescription: String? { "RMD \(description)." }
    }

    /// An app people make calls with. `name` is what the transcript shows ("call in Zoom").
    struct CallApp: Sendable, Equatable {
        let name: String
        let bundleID: String
    }

    static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw CoreAudioError(status: status, what: what) }
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        try check(status, "read audio property \(selector)")
    }

    /// Runs `action` on the main thread whenever the default microphone
    /// (`kAudioHardwarePropertyDefaultInputDevice`) or speaker (`…DefaultOutputDevice`) changes,
    /// for example when AirPods connect. Returns a function that stops watching.
    static func onDefaultDeviceChange(_ selector: AudioObjectPropertySelector, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { action() } }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        return {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, into: &device)
        var uid: Unmanaged<CFString>?
        try read(device, kAudioDevicePropertyDeviceUID, into: &uid)
        guard let uid else { throw CoreAudioError(status: kAudioHardwareBadDeviceError, what: "find the speaker") }
        return uid.takeRetainedValue() as String
    }

    /// Apps people make calls with. When one of them is using the microphone, a call is on.
    /// Browsers count too, for Google Meet and other calls in a web page. Helper processes share the prefix.
    static let callApps: [CallApp] = [
        CallApp(name: "Zoom", bundleID: "us.zoom.xos"),
        CallApp(name: "Teams", bundleID: "com.microsoft.teams"),
        CallApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
        CallApp(name: "WhatsApp", bundleID: "net.whatsapp.WhatsApp"),
        CallApp(name: "WhatsApp", bundleID: "desktop.WhatsApp"),
        CallApp(name: "FaceTime", bundleID: "com.apple.FaceTime"),
        CallApp(name: "Webex", bundleID: "com.cisco.webexmeetingsapp"),
        CallApp(name: "Webex", bundleID: "Cisco-Systems.Spark"),
        CallApp(name: "Discord", bundleID: "com.hnc.Discord"),
        CallApp(name: "Chrome", bundleID: "com.google.Chrome"),
        CallApp(name: "Safari", bundleID: "com.apple.Safari"),
        CallApp(name: "Safari", bundleID: "com.apple.WebKit"),
        CallApp(name: "Arc", bundleID: "company.thebrowser.Browser"),
        CallApp(name: "Edge", bundleID: "com.microsoft.edgemac"),
        CallApp(name: "Firefox", bundleID: "org.mozilla.firefox"),
        CallApp(name: "Brave", bundleID: "com.brave.Browser"),
    ]

    /// The call app that is using the microphone right now, if any. Asks Core Audio about every audio
    /// process (about 40 round trips), so it is called off the main thread.
    static func callAppUsingMicrophone() -> CallApp? {
        guard anyMicrophoneInUse() else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == noErr else { return nil }

        for process in processes {
            var usingMic = UInt32(0)
            var bundle: Unmanaged<CFString>?
            guard (try? read(process, kAudioProcessPropertyIsRunningInput, into: &usingMic)) != nil, usingMic != 0,
                  (try? read(process, kAudioProcessPropertyBundleID, into: &bundle)) != nil,
                  let id = bundle?.takeRetainedValue() as String?
            else { continue }
            if let app = callApps.first(where: { id.hasPrefix($0.bundleID) }) { return app }
        }
        return nil
    }

    /// False when no microphone on this Mac is in use by anyone: one cheap question that saves asking
    /// every process, all day, while nothing is recording. True whenever it can't tell.
    static func anyMicrophoneInUse() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return true }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return true }

        for device in devices {
            var inputs = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &inputs, 0, nil, &inputSize) == noErr else { return true }
            guard inputSize > 0 else { continue }  // a speaker
            var running = UInt32(0)
            guard (try? read(device, kAudioDevicePropertyDeviceIsRunningSomewhere, into: &running)) != nil else { return true }
            if running != 0 { return true }
        }
        return false
    }

    /// True while any app has the current speaker running (playing, even silence). False when it can't tell.
    static func speakerIsRunning() -> Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var running = UInt32(0)
        guard (try? read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, into: &device)) != nil,
              (try? read(device, kAudioDevicePropertyDeviceIsRunningSomewhere, into: &running)) != nil
        else { return false }
        return running != 0
    }

    /// False when the Mac plays through Bluetooth or wired headphones: the mic can't hear the call then,
    /// so nothing "Me" says is echo. True whenever it can't tell. A Bluetooth speaker counts as headphones
    /// too, and a call app set to its own speaker isn't seen: both only leave some echo in.
    static func microphoneCanHearSpeaker() -> Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var transport = UInt32(0)
        guard (try? read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, into: &device)) != nil,
              (try? read(device, kAudioDevicePropertyTransportType, into: &transport)) != nil
        else { return true }
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return false }
        return (try? defaultOutputUID()) != "BuiltInHeadphoneOutputDevice"
    }
}
