import Foundation
import XCTest
@testable import Agents

@MainActor
final class ReviewSocketTests: XCTestCase {
    func testDetachedReviewOpensReturnsSubmitsAndCleansUpOverRealSocket() async throws {
        let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        guard let jqDirectory = searchDirectories.first(where: {
            FileManager.default.isExecutableFile(atPath: "\($0)/jq")
        }) else {
            throw XCTSkip("jq is required by the bundled review client")
        }

        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let launcher = resources.appendingPathComponent("launch-revdiff.sh")
        let runner = resources.appendingPathComponent("review-run.sh")
        let root = URL(fileURLWithPath: "/tmp/ars-\(getpid())-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeDirectory = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: fakeDirectory, withIntermediateDirectories: false)
        let fakeRevDiff = fakeDirectory.appendingPathComponent("revdiff")
        try Self.fakeRevDiff.write(to: fakeRevDiff, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeRevDiff.path)

        let socketPath = root.appendingPathComponent("s").path
        let session = "row-1"
        let pane = UUID()
        let expectedOrigin = ReviewOrigin(
            session: session, pane: pane, agent: "codex", agentSessionID: "agent-1"
        )
        let overlays = OverlayCenter(wrapperURL: resources.appendingPathComponent("overlay-run.sh"))
        var deliveries: [(ReviewOrigin, String)] = []
        let reviews = ReviewController(
            overlays: overlays, socketPath: socketPath, runnerURL: runner,
            temporaryDirectory: root,
            origin: { requestedSession, requestedPane in
                requestedSession == session && requestedPane == pane ? expectedOrigin : nil
            },
            deliver: { origin, message in
                deliveries.append((origin, message))
                return nil
            }
        )
        let server = ControlServer(overlays: overlays, socketPath: socketPath, reviews: reviews)
        server.validateSession = { $0 == session }
        server.start()
        defer { server.stop() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socketPath) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "the server never bound its socket")

        let searchPath = ([fakeDirectory.path, jqDirectory] + searchDirectories).joined(separator: ":")
        let launch = try await Self.run(
            "/bin/sh", [launcher.path, "--untracked"],
            environment: [
                "PATH": searchPath,
                "AGENTS_CONTROL_SOCK": socketPath,
                "AGENTS_SESSION_ID": session,
                "AGENTS_PANE_ID": pane.uuidString,
            ],
            workingDirectory: root
        )
        XCTAssertEqual(launch.status, 0, "launcher exited \(launch.status): \(launch.output)")
        XCTAssertTrue(launch.output.contains("Review opened."))
        XCTAssertEqual(overlays.reviewSessionIDs, [session])
        XCTAssertTrue(deliveries.isEmpty, "opening a detached review must not send feedback")

        let view = try XCTUnwrap(overlays.view(forSession: session))
        let reviewString = try XCTUnwrap(view.configuration.envVars["AGENTS_REVIEW_ID"])
        let review = try XCTUnwrap(UUID(uuidString: reviewString))
        XCTAssertEqual(view.configuration.envVars["AGENTS_SESSION_ID"], session)
        XCTAssertEqual(view.configuration.envVars["PATH"], searchPath)
        XCTAssertTrue(
            try XCTUnwrap(view.configuration.command).contains(socketPath),
            "the runner command must carry the private server path explicitly"
        )

        let refusal = try await Self.run(
            "/usr/bin/nc", ["-U", "-w", "2", socketPath],
            environment: ["PATH": "/usr/bin:/bin"],
            stdin: #"{"cmd":"review-submit","session":"row-1","review":"\#(UUID().uuidString)"}"# + "\n"
        )
        XCTAssertTrue(
            refusal.output.contains(#""ok":false"#) && refusal.output.contains("no longer open"),
            "an unknown review id must be refused, got: \(refusal.output)"
        )
        XCTAssertTrue(deliveries.isEmpty)

        let surface = try await Self.run(
            "/bin/bash", ["-c", try XCTUnwrap(view.configuration.command)],
            environment: view.configuration.envVars,
            workingDirectory: root
        )
        XCTAssertEqual(surface.status, 10, "review surface exited \(surface.status): \(surface.output)")
        XCTAssertEqual(overlays.reviewSessionIDs, [session])
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries.first?.0, expectedOrigin)
        XCTAssertTrue(deliveries.first?.1.contains("socket annotation") == true)

        let reviewDirectory = root.appendingPathComponent("agents-review-\(review.uuidString)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: reviewDirectory.path))
        overlays.handleProcessExit(sessionID: session)

        XCTAssertTrue(overlays.reviewSessionIDs.isEmpty)
        XCTAssertEqual(deliveries.count, 2)
        XCTAssertEqual(
            deliveries.last?.1,
            "The RevDiff overlay is now closed. Its annotations were already submitted; do not apply them again. Reopen the cumulative review after any pending feedback changes are verified."
        )
        XCTAssertEqual(
            deliveries.filter { $0.1.contains("socket annotation") }.count, 1,
            "exit code 10 must not include annotations already flushed"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: reviewDirectory.path))
    }

    private static let fakeRevDiff = """
        #!/bin/sh
        output=
        post_flush=
        for argument in "$@"; do
            case "$argument" in
                --output=*) output=${argument#--output=} ;;
                --post-flush-command=*) post_flush=${argument#--post-flush-command=} ;;
            esac
        done
        [ -n "$output" ] && [ -n "$post_flush" ] || exit 2
        printf '%s\n' 'socket annotation' > "$output"
        eval "$post_flush" </dev/null || exit $?
        exit 10
        """

    private static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        workingDirectory: URL? = nil,
        stdin: String = ""
    ) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (
                    process.terminationStatus, String(decoding: data, as: UTF8.self)
                ))
            }
            do {
                try process.run()
                input.fileHandleForWriting.write(Data(stdin.utf8))
                try input.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
