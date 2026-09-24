#if os(macOS)

    import Foundation
    import SystemExtensions

    /// Activates the embedded system extension, which every tunnel start does
    /// first, so replacing the app takes effect on the next start. The app must
    /// run from /Applications, and the first activation waits for the user in
    /// System Settings > General > Login Items & Extensions.
    final class SystemExtension: NSObject, OSSystemExtensionRequestDelegate {
        private var continuation: CheckedContinuation<Void, Error>?

        private var needsApproval: @Sendable () -> Void = {}

        /// What the user has to do the first time, reported by whichever of
        /// the app and the command line asked.
        static let approvalNeeded =
            "approve Headwire in System Settings > General > Login Items & Extensions > Network Extensions"

        /// Replaces an installed extension of another version, and returns at
        /// once with no prompt when this one is already approved and active.
        /// `submit` is the system's, except in tests, which drive the delegate
        /// themselves.
        static func activate(
            needsApproval: @escaping @Sendable () -> Void,
            submit: (OSSystemExtensionRequest) -> Void = OSSystemExtensionManager.shared.submitRequest
        ) async throws {
            let activation = SystemExtension()
            activation.needsApproval = needsApproval
            try await activation.submit(
                .activationRequest(forExtensionWithIdentifier: Identifiers.providerExtension, queue: .main),
                using: submit)
        }

        private func submit(
            _ request: OSSystemExtensionRequest, using submit: (OSSystemExtensionRequest) -> Void
        ) async throws {
            request.delegate = self
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                submit(request)
            }
        }

        /// The system reports a result or a failure, never both. Taking the
        /// continuation keeps a second delegate call from resuming it twice.
        private func finish(_ error: Error?) {
            guard let continuation else { return }
            self.continuation = nil
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }

        func request(
            _ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
            withExtension ext: OSSystemExtensionProperties
        ) -> OSSystemExtensionRequest.ReplacementAction {
            .replace
        }

        func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
            needsApproval()
        }

        func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
            switch result {
            case .completed:
                finish(nil)
            case .willCompleteAfterReboot:
                // The installed extension keeps serving tunnels until then, so
                // the start that asked for this one must not report success.
                finish(Diagnostics.failure("the Headwire system extension finishes activating after a reboot"))
            @unknown default:
                finish(Diagnostics.failure("system extension activation reported an unknown result"))
            }
        }

        func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
            finish(error)
        }
    }

#endif
