/// The Go engine behind the C bridge, in Swift types: the seam that keeps the
/// provider's start sequence testable without a tunnel. Every call belongs to
/// the caller's lifecycle queue, and the Go side owns the handle until `stop`.
protocol Bridge {
    /// Loads a configuration and holds admission. macOS passes a profile name
    /// the bridge resolves under /etc/headwire, while iOS passes the text
    /// itself. The second element is the settings JSON the bridge returned.
    func prepare(_ source: String) throws -> (handle: Int32, settings: String)
    /// Runs the engine on an applied tunnel's utun.
    func start(_ handle: Int32, descriptor: Int32) throws
    /// Releases the handle, prepared or running.
    func stop(_ handle: Int32)
    /// One status field, `ip [-1|-4|-6]`, or `ping IP`.
    func status(_ handle: Int32, field: String) throws -> String
    /// The default interface, for the engine's socket binding.
    func networkChanged(_ handle: Int32, interface: String)
}
