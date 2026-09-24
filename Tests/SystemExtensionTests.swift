import SystemExtensions
import XCTest

/// Activation without submitting anything to the system: the request is built
/// and its delegate driven by hand. Whether an extension actually installs is
/// a signed, /Applications-only check on a real Mac.
final class SystemExtensionTests: XCTestCase {
    /// Drives the delegate the way the system would and returns the error the
    /// activation reports, if any.
    private func activate(
        needsApproval: @escaping @Sendable () -> Void = {},
        driving: @escaping (OSSystemExtensionRequestDelegate, OSSystemExtensionRequest) -> Void
    ) async -> Error? {
        do {
            try await SystemExtension.activate(needsApproval: needsApproval) { request in
                driving(request.delegate!, request)
            }
            return nil
        } catch {
            return error
        }
    }

    func testApprovalIsReportedWhileTheActivationIsStillPending() async {
        let approvals = Counter()
        let error = await activate(needsApproval: { approvals.increment() }) { delegate, request in
            delegate.requestNeedsUserApproval(request)
            delegate.request(request, didFinishWithResult: .completed)
        }
        XCTAssertNil(error)
        XCTAssertEqual(approvals.count, 1)
    }

    /// The installed extension still serves tunnels until the reboot, so the
    /// start that asked for this one has to fail.
    func testActivationDeferredToRebootFails() async {
        let error = await activate { delegate, request in
            delegate.request(request, didFinishWithResult: .willCompleteAfterReboot)
        }
        XCTAssertEqual(
            error?.localizedDescription, "the Headwire system extension finishes activating after a reboot")
    }

    /// A result and a failure would resume one continuation twice, which traps.
    func testOnlyTheFirstOutcomeIsReported() async {
        let refused = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "refused"])
        let failedFirst = await activate { delegate, request in
            delegate.request(request, didFailWithError: refused)
            delegate.request(request, didFinishWithResult: .completed)
        }
        XCTAssertEqual(failedFirst?.localizedDescription, "refused")

        let finishedFirst = await activate { delegate, request in
            delegate.request(request, didFinishWithResult: .completed)
            delegate.request(request, didFailWithError: refused)
        }
        XCTAssertNil(finishedFirst)
    }
}
