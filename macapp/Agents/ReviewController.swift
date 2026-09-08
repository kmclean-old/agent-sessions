import Foundation

/// Opens app-owned reviews and handles submit/exit events. There is no
/// waiting client, timer, or persisted review registry.
@MainActor
final class ReviewController {
    private struct Active {
        let id: UUID
        let origin: ReviewOrigin
        let directory: URL
        var handoff = ReviewHandoff()
    }

    private let overlays: OverlayCenter
    private let socketPath: String
    private let runnerURL: URL?
    private let temporaryDirectory: URL
    private let origin: (String, UUID) -> ReviewOrigin?
    private let deliver: (ReviewOrigin, String) -> String?
    private var active: [String: Active] = [:]

    init(
        overlays: OverlayCenter,
        socketPath: String,
        runnerURL: URL? = Bundle.main.url(forResource: "review-run", withExtension: "sh"),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        origin: @escaping (String, UUID) -> ReviewOrigin?,
        deliver: @escaping (ReviewOrigin, String) -> String?
    ) {
        self.overlays = overlays
        self.socketPath = socketPath
        self.runnerURL = runnerURL
        self.temporaryDirectory = temporaryDirectory
        self.origin = origin
        self.deliver = deliver
    }

    func open(_ request: ReviewRequest) -> String? {
        guard let origin = origin(request.session, request.pane) else {
            return "the requesting pane has no live agent; enable the Agents status hook"
        }
        guard let runnerURL else { return "this Agents build is missing review-run.sh" }
        guard active[request.session] == nil else { return "a review is already open in this session" }
        let id = UUID()
        let directory = temporaryDirectory.appendingPathComponent("agents-review-\(id.uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            var env = request.environment
            env["AGENTS_SESSION_ID"] = request.session
            env["AGENTS_REVIEW_ID"] = id.uuidString
            try overlays.present(
                command: runnerURL.path,
                arguments: [directory.path, socketPath, request.command] + request.arguments,
                workingDirectory: request.workingDirectory,
                sessionID: request.session, environment: env
            )
            active[request.session] = Active(id: id, origin: origin, directory: directory)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return String(describing: error)
        }
    }

    func submit(session: String, review: UUID) -> String? {
        guard var current = active[session], current.id == review else {
            return "this review is no longer open"
        }
        do {
            let annotations = try String(contentsOf: current.directory.appendingPathComponent("annotations.md"), encoding: .utf8)
            guard let message = current.handoff.message(for: .submitted(annotations)) else { return nil }
            if let error = deliver(current.origin, message) { return error }
            current.handoff.didSubmit(annotations)
            active[session] = current
            return nil
        } catch {
            return "could not read submitted annotations: \(error.localizedDescription)"
        }
    }

    func closed(session: String, outcome: OverlayCenter.ReviewOutcome) {
        guard let current = active.removeValue(forKey: session) else { return }
        defer { try? FileManager.default.removeItem(at: current.directory) }
        let event: ReviewHandoff.Event
        switch outcome {
        case .cancelled:
            event = .cancelled
        case .finished:
            let status = read("status", in: current.directory).trimmingCharacters(in: .whitespacesAndNewlines)
            event = .exited(
                status: Int(status), annotations: read("annotations.md", in: current.directory),
                error: read("stderr", in: current.directory)
            )
        }
        guard let message = current.handoff.message(for: event) else { return }
        if let error = deliver(current.origin, message) {
            NSLog("Agents: review feedback was not delivered: %@", error)
        }
    }

    func originEnded(_ origin: ReviewOrigin) {
        guard active[origin.session]?.origin == origin else { return }
        overlays.cancelReview(forSession: origin.session)
    }

    func shutdown() {
        for session in Array(active.keys) {
            overlays.cancelReview(forSession: session)
        }
    }

    private func read(_ name: String, in directory: URL) -> String {
        (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }
}
