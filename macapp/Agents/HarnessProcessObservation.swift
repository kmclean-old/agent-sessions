import Darwin
import Foundation

/// The kernel wakes this observer once when a registered harness exits.
/// A hook connection closing is unrelated: each hook uses a short connection.
@MainActor
final class HarnessProcessObservation {
    private let source: DispatchSourceProcess
    private let onExit: @MainActor () -> Void
    private var didExit = false

    init(pid: Int32, onExit: @escaping @MainActor () -> Void) {
        self.onExit = onExit
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in Task { @MainActor in self?.notifyExit() } }
        source.resume()
        // Cover a process that exited between its report and registration.
        if kill(pid, 0) == -1, errno == ESRCH {
            Task { @MainActor [weak self] in self?.notifyExit() }
        }
    }

    private func notifyExit() {
        guard !didExit else { return }
        didExit = true
        source.cancel()
        onExit()
    }

    deinit { source.cancel() }
}
