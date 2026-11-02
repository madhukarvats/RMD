import CoreAudio
import Foundation

/// Small helpers over Core Audio's C API: device changes, the current speaker, and which apps use the mic.
enum AudioDevices {
    struct CoreAudioError: Error, CustomStringConvertible {
        let status: OSStatus
        let what: String
        var description: String { "couldn't \(what) (Core Audio error \(status))" }
    }

    static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw CoreAudioError(status: status, what: what) }
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "read audio property \(selector)")
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
    /// Browsers count too, for Google Meet and other calls in a web page.
    static let callApps = [
        "us.zoom.xos", "com.microsoft.teams", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "com.apple.FaceTime", "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "com.hnc.Discord",
        "com.google.Chrome", "com.apple.Safari", "com.apple.WebKit", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser",
    ]

    /// The bundle ID of a call app that is using the microphone right now, if any.
    static func callAppUsingMicrophone() -> String? {
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
            if callApps.contains(where: id.hasPrefix) { return id }
        }
        return nil
    }
}
