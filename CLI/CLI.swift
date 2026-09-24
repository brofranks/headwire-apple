import Foundation
import HeadwireBridge

/// The C callback borrows context and input for this call. strdup transfers
/// ownership of its response/error to Go, which frees both with free().
private func requestCLI(
    _ context: UnsafeMutableRawPointer?, _ input: UnsafePointer<CChar>?,
    _ output: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> UnsafeMutablePointer<CChar>? {
    let transport = Unmanaged<CLITransport>.fromOpaque(context!).takeUnretainedValue()
    switch transport.call(String(cString: input!)) {
    case .success(let reply):
        output!.pointee = strdup(reply)
        return nil
    case .failure(let error): return strdup(error.localizedDescription)
    }
}

func runCLI(_ args: [String], transport: CLITransport) async -> Int32 {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            var argv = args.map { strdup($0) }
            defer { argv.forEach { free($0) } }
            let code = withExtendedLifetime(transport) {
                HeadwireCLI(Int32(argv.count), &argv, requestCLI, Unmanaged.passUnretained(transport).toOpaque())
            }
            continuation.resume(returning: code)
        }
    }
}
