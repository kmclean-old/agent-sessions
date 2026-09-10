import Darwin
import Foundation

/// The kernel wakes this observer once when a registered harness exits.
/// A hook connection closing is unrelated: each hook uses a short connection.
final class HarnessProcessObservation {
    private let source: DispatchSourceProcess

    init(pid: Int32, onExit: @escaping @MainActor () -> Void) {
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { Task { @MainActor in onExit() } }
        source.resume()
        // Cover a process that exited between its report and registration.
        if kill(pid, 0) == -1, errno == ESRCH {
            Task { @MainActor in onExit() }
        }
    }

    deinit { source.cancel() }
}
