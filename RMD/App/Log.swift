import os

/// Problems RMD runs into, for `log show --predicate 'subsystem == "com.madhukarsharma.RMD"'`.
/// Never anything that was said.
enum Log {
    static let audio = Logger(subsystem: "com.madhukarsharma.RMD", category: "audio")
    static let app = Logger(subsystem: "com.madhukarsharma.RMD", category: "app")
}
