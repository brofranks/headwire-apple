import HeadwireBridge

/// The C ABI in bridge/apple/include/headwire_bridge.h, and the only place
/// that calls it: it owns every string the Go side hands out, errors included.
struct GoBridge: Bridge {
    func prepare(_ source: String) throws -> (handle: Int32, settings: String) {
        var handle: Int32 = 0
        var json: UnsafeMutablePointer<CChar>?
        #if os(macOS)
            let prepared = HeadwirePrepareProfile(source, &handle, &json)
        #else
            let prepared = HeadwirePrepareConfig(source, &handle, &json)
        #endif
        try check(prepared)
        defer { HeadwireFree(json) }
        return (handle, String(cString: json!))
    }

    func start(_ handle: Int32, descriptor: Int32) throws {
        try check(HeadwireStart(handle, descriptor))
    }

    func stop(_ handle: Int32) {
        HeadwireStop(handle)
    }

    func status(_ handle: Int32, field: String) throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        try check(HeadwireStatus(handle, field, &out))
        defer { HeadwireFree(out) }
        return String(cString: out!)
    }

    func networkChanged(_ handle: Int32, interface: String) {
        HeadwireNetworkChanged(handle, interface)
    }

    /// Takes ownership of a bridge error string. nil is success.
    private func check(_ message: UnsafeMutablePointer<CChar>?) throws {
        guard let message else { return }
        defer { HeadwireFree(message) }
        throw Diagnostics.failure(String(cString: message))
    }
}
