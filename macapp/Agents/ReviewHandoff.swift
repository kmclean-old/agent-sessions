import Foundation

/// The live agent that requested a review. Pane focus and persisted resume
/// metadata do not determine where feedback goes.
struct ReviewOrigin: Equatable {
    let session: String
    let pane: UUID
    let agent: String
    let agentSessionID: String
}

struct ReviewRequest: Equatable {
    let session: String
    let pane: UUID
    let command: String
    let arguments: [String]
    let workingDirectory: String
    let environment: [String: String]
}

/// Decides which review events produce input for the agent. Files, sockets,
/// and terminal delivery belong to ReviewController.
struct ReviewHandoff: Equatable {
    enum Event {
        case submitted(String)
        case exited(status: Int?, annotations: String, error: String)
        case cancelled
    }

    private(set) var lastSubmission: String?

    func message(for event: Event) -> String? {
        switch event {
        case .submitted(let annotations):
            let text = Self.clean(annotations)
            guard !text.isEmpty, text != lastSubmission else { return nil }
            return "RevDiff feedback submitted. Address these annotations. The review is still open; let it reload instead of opening another overlay.\n\n" + text
        case .exited(let status, let annotations, let error):
            guard let status else { return nil }
            switch status {
            case 0, 10:
                let text = Self.clean(annotations)
                if text.isEmpty {
                    return "The user finished the RevDiff review without annotations. This review is complete."
                }
                guard text != lastSubmission else {
                    return "The RevDiff overlay is now closed. Its annotations were already submitted; do not apply them again. Reopen the cumulative review after any pending feedback changes are verified."
                }
                return "The user finished the RevDiff review with these annotations. Address them and reopen the cumulative review after verification.\n\n" + text
            case 129, 130, 137, 143:
                return nil
            default:
                return "RevDiff exited with status \(status). The review was not completed.\n" + Self.clean(error)
            }
        case .cancelled:
            return nil
        }
    }

    /// Advance only after delivery succeeds, so a failed submit can be retried.
    mutating func didSubmit(_ annotations: String) {
        lastSubmission = Self.clean(annotations)
    }

    private static func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
