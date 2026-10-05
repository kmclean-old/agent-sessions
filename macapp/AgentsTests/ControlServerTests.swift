import Darwin
import Foundation
import XCTest
@testable import Agents

/// `ControlServer.decide` is the hook's wire contract: one JSON line in,
/// either a refusal string or the session event to apply.
final class ControlServerTests: XCTestCase {
    func testMalformedJSONIsRefused() {
        XCTAssertEqual(
            ControlServer.decide(line: "not json"),
            .refuse("malformed request")
        )
    }

    func testUnknownCmdIsRefused() {
        XCTAssertEqual(
            ControlServer.decide(line: #"{"cmd":"self-destruct"}"#),
            .refuse("unknown cmd: self-destruct")
        )
    }

    func testRemovedReviewCommandsAreUnknown() {
        for command in ["overlay-run", "review-open", "review-submit"] {
            XCTAssertEqual(
                ControlServer.decide(line: #"{"cmd":"\#(command)"}"#),
                .refuse("unknown cmd: \(command)")
            )
        }
    }

    // MARK: - session-event

    @MainActor
    func testTheAppAnswersAnAppliedEventWithSuccessNotTheShutdownFallback() {
        let center = TerminalCenter()
        _ = center.terminalView(for: "row-1", workingDirectory: "/tmp", restoredResume: nil)
        let pane = center.layouts["row-1"]!.initialPane
        let event = ControlSessionEvent(session: "row-1", pane: pane, status: .clear, event: nil)

        XCTAssertNil(
            AgentsApp.applySessionEvent(event, to: center),
            "an applied event must be answered ok — the one-liner this replaced turned the center's nil-for-success into the shutdown refusal, so the hook's log called every good report a failure"
        )
        XCTAssertEqual(
            AgentsApp.applySessionEvent(event, to: nil), "app is shutting down"
        )
        XCTAssertNotNil(
            AgentsApp.applySessionEvent(
                ControlSessionEvent(session: "row-1", pane: UUID(), status: .clear, event: nil), to: center
            ),
            "a genuine refusal must still come through"
        )
    }

    /// The hook's wire form (see hooks/agents-status.sh). Every field the
    /// hook can send, in the exact spelling it sends it.
    private let pane = "7F4B1B6E-9E1E-4B7D-9C1A-1F2E3D4C5B6A"

    func testSessionEventDecodesAndNormalizesLikeTheOSCForm() {
        let decision = ControlServer.decide(
            line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"UserPromptSubmit","status":"clear","agent":" Claude ","agent_session_id":" abc-123 ","prompt":"Fix\n\tthe   parser"}"#
        )

        XCTAssertEqual(
            decision,
            .sessionEvent(ControlSessionEvent(
                session: "row-1",
                pane: UUID(uuidString: pane)!,
                status: .clear,
                event: AgentSessionEvent(
                    agent: "claude", name: "UserPromptSubmit", sessionID: "abc-123", query: "Fix the parser"
                )
            )),
            "the socket form must normalize exactly like the OSC form — lowercase agent, trimmed id, one-line prompt — so a session looks the same downstream whichever transport announced it"
        )
    }

    func testSessionEventMayCarryStatusAlone() {
        let decision = ControlServer.decide(
            line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"Stop","status":"your-turn"}"#
        )

        XCTAssertEqual(
            decision,
            .sessionEvent(ControlSessionEvent(
                session: "row-1", pane: UUID(uuidString: pane)!, status: .set(.yourTurn), event: nil
            )),
            "a hook that could not identify its harness still reports attention state — the sidebar dot must not depend on the process-tree walk succeeding"
        )
    }

    func testSessionEventMayCarryTheAnnouncementAlone() {
        let decision = ControlServer.decide(
            line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"SubagentStop","agent":"codex","agent_session_id":"x-1"}"#
        )

        XCTAssertEqual(
            decision,
            .sessionEvent(ControlSessionEvent(
                session: "row-1",
                pane: UUID(uuidString: pane)!,
                status: nil,
                event: AgentSessionEvent(agent: "codex", name: "SubagentStop", sessionID: "x-1", query: nil)
            )),
            "an event with no attention meaning still announces the session — every event re-announces, so a hook registered on an unmapped event alone keeps resume working"
        )
    }

    func testSessionEventCarriesTheHarnessHome() {
        let decision = ControlServer.decide(
            line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"SessionStart","agent":"codex","agent_session_id":"x-1","agent_home":" /Users/kira/.codex-kira "}"#
        )

        XCTAssertEqual(
            decision,
            .sessionEvent(ControlSessionEvent(
                session: "row-1",
                pane: UUID(uuidString: pane)!,
                status: nil,
                event: AgentSessionEvent(
                    agent: "codex", name: "SessionStart", sessionID: "x-1", query: nil, home: "/Users/kira/.codex-kira"
                )
            )),
            "the home the harness ran under rides along with its announcement, trimmed, so the restore banner can prefix the resume command with it"
        )
    }

    func testSessionEventWithNothingToApplyIsRefused() {
        XCTAssertEqual(
            ControlServer.decide(
                line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"PreCompact"}"#
            ),
            .refuse("nothing to apply: no status and no agent session"),
            "a line that would change nothing is a sender bug, and accepting it as ok would hide that from anyone debugging with nc by hand"
        )
    }

    func testSessionEventUnknownStatusTokenIsRefused() {
        XCTAssertEqual(
            ControlServer.decide(
                line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"Stop","status":"done"}"#
            ),
            .refuse("unknown status: done"),
            "the status vocabulary is shared with the OSC form and must not grow silently — an unknown token is refused, never mapped to some default state"
        )
    }

    func testSessionEventMissingOrMalformedPaneIsRefused() {
        for line in [
            #"{"cmd":"session-event","session":"row-1","event":"Stop","status":"clear"}"#,
            #"{"cmd":"session-event","session":"row-1","pane":"","event":"Stop","status":"clear"}"#,
        ] {
            guard case .refuse(let message) = ControlServer.decide(line: line) else {
                return XCTFail("a session event without a pane must be refused: \(line)")
            }
            XCTAssertTrue(
                message.contains("AGENTS_PANE_ID"),
                "the missing-pane refusal must name the variable the hook forwards — an app/hook version skew is the only way to get here, and this message is the only clue"
            )
        }
        XCTAssertEqual(
            ControlServer.decide(
                line: #"{"cmd":"session-event","session":"row-1","pane":"nope","event":"Stop","status":"clear"}"#
            ),
            .refuse("malformed pane: nope")
        )
    }

    func testSessionEventMissingSessionIsRefusedWithUpgradeGuidance() {
        guard case .refuse(let message) = ControlServer.decide(
            line: #"{"cmd":"session-event","pane":"\#(pane)","event":"Stop","status":"clear"}"#
        ) else {
            return XCTFail("a session event without a session must be refused")
        }
        XCTAssertTrue(message.contains("AGENTS_SESSION_ID"))
    }

    func testSessionEventMissingEventNameIsRefused() {
        for line in [
            #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","status":"clear"}"#,
            #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"  ","status":"clear"}"#,
        ] {
            XCTAssertEqual(ControlServer.decide(line: line), .refuse("missing event"))
        }
    }

    func testSessionEventHalfAnAgentIdentityIsRefused() {
        XCTAssertEqual(
            ControlServer.decide(
                line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"Stop","agent":"claude"}"#
            ),
            .refuse("missing agent_session_id")
        )
        XCTAssertEqual(
            ControlServer.decide(
                line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"Stop","agent_session_id":"abc"}"#
            ),
            .refuse("missing agent"),
            "an announcement needs both halves — a session id with no harness could never be turned into a resume command, and recording it would freeze the row's record on a lie"
        )
        XCTAssertEqual(
            ControlServer.decide(
                line: #"{"cmd":"session-event","session":"row-1","pane":"\#(pane)","event":"Stop","agent":"  ","agent_session_id":"abc"}"#
            ),
            .refuse("blank agent or agent_session_id")
        )
    }

    // MARK: - open-session

    /// The directories these tests treat as existing. `decide` is handed
    /// this instead of the file system, so each refusal is about the field
    /// under test and nothing else.
    private static let existing: Set<String> = ["/Users/kira/code/agents", "/tmp"]
    private func decideOpen(_ line: String) -> ControlServer.RequestDecision {
        ControlServer.decide(line: line, isDirectory: { Self.existing.contains($0) })
    }

    func testOpenSessionIsAcceptedWithEveryFieldNormalized() {
        XCTAssertEqual(
            decideOpen(
                #"{"cmd":"open-session","version":1,"cwd":"/Users/kira/code/agents/./","command":"  claude-seeq attach 7ea9eb92 ","title":"Fix the\nparser"}"#
            ),
            .openSession(ControlOpenSession(
                workingDirectory: "/Users/kira/code/agents",
                command: "claude-seeq attach 7ea9eb92",
                title: "Fix the parser"
            )),
            "cwd is standardized, the command trimmed, and the title collapsed to the one line a sidebar label can show"
        )
    }

    func testOpenSessionTitleIsOptionalAndABlankOneIsNone() {
        let expected = ControlServer.RequestDecision.openSession(
            ControlOpenSession(workingDirectory: "/tmp", command: "ls", title: nil)
        )
        XCTAssertEqual(decideOpen(#"{"cmd":"open-session","version":1,"cwd":"/tmp","command":"ls"}"#), expected)
        XCTAssertEqual(decideOpen(#"{"cmd":"open-session","version":1,"cwd":"/tmp","command":"ls","title":null}"#), expected)
        XCTAssertEqual(
            decideOpen(#"{"cmd":"open-session","version":1,"cwd":"/tmp","command":"ls","title":" \t "}"#), expected,
            "a blank title would name the row nothing; the row keeps its numbered name instead"
        )
    }

    func testOpenSessionTitleIsCappedRatherThanRefused() {
        let long = String(repeating: "x", count: ControlServer.openSessionTitleLimit + 50)
        guard case .openSession(let request) = decideOpen(
            #"{"cmd":"open-session","version":1,"cwd":"/tmp","command":"ls","title":"\#(long)"}"#
        ) else {
            return XCTFail("a long title is only a long label — it must not refuse the session")
        }
        XCTAssertEqual(request.title?.count, ControlServer.openSessionTitleLimit)
    }

    func testOpenSessionRefusesAnyVersionButOne() {
        for version in [#""#, #","version":0"#, #","version":2"#] {
            XCTAssertEqual(
                decideOpen(#"{"cmd":"open-session"\#(version),"cwd":"/tmp","command":"ls"}"#),
                .refuse("unsupported open-session version — this app speaks version 1"),
                "version clause: \(version)"
            )
        }
    }

    func testOpenSessionRefusesACwdThatIsMissingRelativeOrNotADirectory() {
        XCTAssertEqual(
            decideOpen(#"{"cmd":"open-session","version":1,"command":"ls"}"#),
            .refuse("open-session requires cwd, the directory to open the session in")
        )
        XCTAssertEqual(
            decideOpen(#"{"cmd":"open-session","version":1,"cwd":"","command":"ls"}"#),
            .refuse("open-session requires cwd, the directory to open the session in")
        )
        XCTAssertEqual(
            decideOpen(#"{"cmd":"open-session","version":1,"cwd":"code/agents","command":"ls"}"#),
            .refuse("cwd must be an absolute path: code/agents"),
            "a relative path is relative to whatever the app's own directory happens to be — never what the sender meant"
        )
        XCTAssertEqual(
            decideOpen(#"{"cmd":"open-session","version":1,"cwd":"/Users/kira/gone/","command":"ls"}"#),
            .refuse("cwd is not an existing directory: /Users/kira/gone")
        )
    }

    func testOpenSessionRefusesACommandThatIsMissingBlankOrTooLong() {
        let required = ControlServer.RequestDecision.refuse(
            "open-session requires command, the shell command to run in the new session"
        )
        XCTAssertEqual(decideOpen(#"{"cmd":"open-session","version":1,"cwd":"/tmp"}"#), required)
        XCTAssertEqual(decideOpen(#"{"cmd":"open-session","version":1,"cwd":"/tmp","command":"   "}"#), required)

        let limit = ControlServer.openSessionCommandLimit
        let atLimit = String(repeating: "x", count: limit)
        XCTAssertEqual(
            decideOpen(#"{"cmd":"open-session","version":1,"cwd":"/tmp","command":"\#(atLimit)"}"#),
            .openSession(ControlOpenSession(workingDirectory: "/tmp", command: atLimit, title: nil))
        )
        XCTAssertEqual(
            decideOpen(#"{"cmd":"open-session","version":1,"cwd":"/tmp","command":"\#(atLimit)x"}"#),
            .refuse("command is longer than \(limit) characters")
        )
    }

    /// The command is typed at a prompt as a paste, so a control character
    /// in it is never inert: each of these would make the pane run
    /// something other than the one line that was asked for.
    func testOpenSessionRefusesACommandCarryingControlCharacters() {
        for (escaped, why) in [
            (#"ls\nrm -rf ~"#, "a newline makes it two commands"),
            (#"ls\rpwd"#, "a carriage return is Enter"),
            (#"ls\u001b[201~pwd"#, "an escape can close the bracketed paste early"),
            (#"ls\u0003"#, "Ctrl-C"),
            (#"ls\tpwd"#, "a tab completes, it isn't typed"),
        ] {
            XCTAssertEqual(
                decideOpen(#"{"cmd":"open-session","version":1,"cwd":"/tmp","command":"\#(escaped)"}"#),
                .refuse("command must be a single line with no control characters"),
                why
            )
        }
    }

    /// The whole path a sender takes: a real `ControlServer` on a private
    /// socket, `nc -U` speaking the README's own example, and the wired
    /// callback receiving the decoded request — then the same with nothing
    /// wired, which must still answer, and close, rather than leave the
    /// sender's `nc` waiting.
    @MainActor
    func testOpenSessionIsAnsweredOverTheSocket() async throws {
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("agents-open-test-\(getpid()).sock").path
        let server = ControlServer(socketPath: socketPath)
        var opened: [ControlOpenSession] = []
        server.openSession = { request in
            opened.append(request)
            return nil
        }
        server.start()
        defer { server.stop() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socketPath) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "the server never bound its socket")

        let line = #"{"cmd":"open-session","version":1,"cwd":"/tmp","command":"claude-seeq attach 7ea9eb92","title":"Attach"}"#
        let accepted = try await Self.run(
            "/usr/bin/nc", ["-U", "-w", "2", socketPath], environment: [:], stdin: line + "\n"
        )
        XCTAssertEqual(accepted.output.trimmingCharacters(in: .whitespacesAndNewlines), #"{"ok":true}"#)
        XCTAssertEqual(
            opened,
            [ControlOpenSession(workingDirectory: "/tmp", command: "claude-seeq attach 7ea9eb92", title: "Attach")]
        )

        let refused = try await Self.run(
            "/usr/bin/nc", ["-U", "-w", "2", socketPath], environment: [:],
            stdin: #"{"cmd":"open-session","version":1,"cwd":"tmp","command":"ls"}"# + "\n"
        )
        XCTAssertTrue(
            refused.output.contains(#""ok":false"#) && refused.output.contains("absolute"),
            "a refusal reaches the sender as a JSON line saying what to fix, got: \(refused.output)"
        )
        XCTAssertEqual(opened.count, 1, "a refused request opens nothing")

        server.openSession = nil
        let unwired = try await Self.run(
            "/usr/bin/nc", ["-U", "-w", "2", socketPath], environment: [:], stdin: line + "\n"
        )
        XCTAssertTrue(unwired.output.contains("open-session is not wired"), "got: \(unwired.output)")
    }

    func testControlSocketPathIsScopedToTheBundleAndProcess() {
        let path = ControlServer.socketPath
        let bundleID = Bundle(for: ControlServerTests.self).bundleIdentifier
        let pid = ProcessInfo.processInfo.processIdentifier

        XCTAssertTrue(
            path.hasSuffix(".control.\(pid).sock"),
            "the socket path must carry the process id so simultaneous app and test-host launches cannot contend for one endpoint: \(path)"
        )
        XCTAssertTrue(
            path.contains("com.kirahowe.agents"),
            "the socket path must carry the bundle id so Debug and Release builds cannot collide (got \(path), test bundle \(bundleID ?? "nil"))"
        )
        XCTAssertLessThan(
            path.utf8.count,
            104,
            "sockaddr_un.sun_path is 104 bytes on Darwin; a longer path cannot be bound"
        )
    }

    func testSweepDeadSocketsRemovesOnlyDeadMatchingSockets() throws {
        // Keep the fixture path short enough for sockaddr_un.sun_path.
        let directory = "/tmp/ctrlsweep-\(ProcessInfo.processInfo.processIdentifier)-\(Int(Date().timeIntervalSince1970 * 1000))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let prefix = "com.kirahowe.agents.control."
        let deadPath = "\(directory)/\(prefix)111.sock"
        let livePath = "\(directory)/\(prefix)222.sock"
        let unrelatedPath = "\(directory)/not-a-control-socket.txt"
        FileManager.default.createFile(atPath: unrelatedPath, contents: Data("hello".utf8))

        let deadFD = try bindUnixSocket(at: deadPath)
        close(deadFD)

        let liveFD = try bindUnixSocket(at: livePath)
        XCTAssertEqual(listen(liveFD, 1), 0, "failed to listen on the live test socket")
        defer { close(liveFD) }

        ControlServer.sweepDeadSockets(
            in: directory, prefix: prefix, ownPath: "/nonexistent-own-path"
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: deadPath),
            "the sweep must remove a socket file with no listener"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: livePath),
            "the sweep must preserve a socket with a live listener"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unrelatedPath),
            "the sweep must preserve files outside the control-socket naming scheme"
        )
    }

    // MARK: - End to end: the real hook, a real socket

    /// The whole reporting path exactly as the hook drives it: the bundled
    /// script, run the way Claude Code runs it, speaking `nc -U` to a real
    /// `ControlServer` bound on a private path, landing on a
    /// `TerminalCenter` pane. Every other test here pins one link; this one
    /// proves the chain holds. A framing mismatch between the script's line
    /// and the server's reader, a reply that never closes (the hook's `nc`
    /// would sit on it until its timeout, stalling the agent), or a gap in
    /// the closures `AgentsApp` wires would each pass the unit tests and
    /// only show up as a dot that never lights or a banner that never
    /// prints.
    @MainActor
    func testTheRealHookReportsOverTheSocketAndLandsOnItsPane() async throws {
        let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        guard searchPath.split(separator: ":").contains(where: {
            FileManager.default.isExecutableFile(atPath: "\($0)/jq")
        }) else {
            throw XCTSkip("jq is not installed, so the hook cannot run here")
        }
        let hook = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AgentsTests
            .deletingLastPathComponent()  // macapp
            .deletingLastPathComponent()  // repo
            .appendingPathComponent("hooks/agents-status.sh")

        let center = TerminalCenter()
        _ = center.terminalView(for: "row-1", workingDirectory: "/tmp", restoredResume: nil)
        let pane = center.layouts["row-1"]!.initialPane
        var signals: [(pane: UUID, signal: AttentionSignal)] = []
        center.onSessionSignal = { _, pane, signal in signals.append((pane, signal)) }
        var announced: [AgentSessionEvent] = []
        center.onAgentSessionEvent = { _, event, _ in announced.append(event) }

        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("agents-hook-test-\(getpid()).sock").path
        let server = ControlServer(socketPath: socketPath)
        server.validateSession = { $0 == "row-1" }
        server.applySessionEvent = { [center] event in center.handleControlSessionEvent(event) }
        server.start()
        defer { server.stop() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socketPath) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "the server never bound its socket")

        let environment = [
            "PATH": searchPath,
            "AGENTS_APP": "1",
            "AGENTS_CONTROL_SOCK": socketPath,
            "AGENTS_SESSION_ID": "row-1",
            "AGENTS_PANE_ID": pane.uuidString,
            // Under xctest there is no `claude` ancestor to find; this is the
            // hook's documented fallback for exactly that situation.
            "CLAUDECODE": "1",
            "CLAUDE_CONFIG_DIR": "/tmp/claude-config",
        ]
        let hookRun = try await Self.run(
            "/bin/bash", [hook.path], environment: environment,
            stdin: #"{"hook_event_name":"UserPromptSubmit","session_id":"abc-123","prompt":"Fix the parser"}"#
        )
        XCTAssertEqual(hookRun.status, 0, "hook exited \(hookRun.status): \(hookRun.output)")
        XCTAssertEqual(signals.map(\.pane), [pane])
        XCTAssertEqual(signals.map(\.signal), [.structured(.clear)])
        XCTAssertEqual(
            announced,
            [AgentSessionEvent(
                agent: "claude", name: "UserPromptSubmit", sessionID: "abc-123", query: "Fix the parser",
                home: "/tmp/claude-config"
            )],
            "the hook's UserPromptSubmit must arrive as one announcement carrying the harness, its session id, the prompt preview, and the configuration home it ran under"
        )

        // A refusal must be answered AND the connection closed, or the
        // hook's nc hangs on it: drive nc directly to read the reply.
        let refusal = try await Self.run(
            "/usr/bin/nc", ["-U", "-w", "2", socketPath], environment: ["PATH": searchPath],
            stdin: #"{"cmd":"session-event","session":"row-1","pane":"\#(UUID().uuidString)","event":"Stop","status":"clear"}"# + "\n"
        )
        XCTAssertTrue(
            refusal.output.contains(#""ok":false"#) && refusal.output.contains("unknown pane"),
            "a refusal must reach the caller as a JSON line naming the problem, got: \(refusal.output)"
        )
        XCTAssertEqual(signals.count, 1, "a refused event must apply nothing")

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath), "stop() must remove the socket file")
    }

    private static func run(
        _ executable: String, _ arguments: [String], environment: [String: String], stdin: String
    ) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        // Never waitUntilExit() here: the server applies events on the main
        // actor, and blocking the main thread would deadlock the very reply
        // the hook's nc is waiting for.
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
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

    /// Binds without listening, allowing the sweep test to construct both
    /// live and abandoned Unix socket files.
    private func bindUnixSocket(at path: String) throws -> Int32 {
        struct SocketSetupError: Error, CustomStringConvertible {
            let description: String
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketSetupError(description: "socket() failed: \(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw SocketSetupError(description: "test socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                Darwin.bind(fd, address, size)
            }
        }
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw SocketSetupError(description: "bind() failed: \(message)")
        }
        return fd
    }
}
