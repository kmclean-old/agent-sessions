import AppKit
import Darwin
import Foundation

/// A tiny local control channel: a Unix domain socket used by
/// `hooks/agents-status.sh` to report what the agent in one pane is doing:
/// its attention state and its resumable session (see
/// `ControlSessionEvent`). The hook used to write those facts as OSC 777
/// escapes to the pane's pty and lost most of them: Ghostty throttles
/// desktop notifications app-wide — one per second across every surface,
/// identical content suppressed for five — so the session announcement
/// that followed a status escape by microseconds was dropped every single
/// time, and two agents reporting within a second of each other lost one
/// report. A socket line is never throttled, never deduplicated, needs no
/// pty discovery, and gets an answer.
///
/// The socket path carries the bundle id, so each build gets its own endpoint,
/// AND the pid of the process that bound it, so two launches of the same
/// binary can never contend for one endpoint either — including a test-host
/// launch, which boots this same `AgentsApp.init` (see `AgentsApp`) and would
/// otherwise steal the running app's socket file for the seconds it takes to
/// run and exit, leaving the real app listening on an unlinked inode with no
/// way back in. The path is stamped into every session's environment as
/// `AGENTS_CONTROL_SOCK` (see `TerminalCenter.sessionEnvVars`), so a client
/// always finds its own instance directly without discovery, cross-build
/// mixups, or cross-instance contention.
final class ControlServer: @unchecked Sendable {
    /// Absolute path of this process's socket.
    ///
    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, which is the real
    /// constraint on where this can live; Application Support keeps it well
    /// inside that with room for the longest bundle id in use, and the pid
    /// suffix only ever adds another five to seven digits on top.
    static let socketPath: String = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let directory = base.appendingPathComponent("Agents", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let bundleID = Bundle.main.bundleIdentifier ?? "com.kirahowe.agents"
        let pid = ProcessInfo.processInfo.processIdentifier
        return directory.appendingPathComponent("\(bundleID).control.\(pid).sock").path
    }()

    /// The path THIS instance binds: `socketPath` for the app, or the
    /// private path a test hands `init` so it can stand up a real server
    /// without touching this build's socket namespace.
    let path: String

    /// Directory holding every build's control sockets, live or dead —
    /// `path` with its last component removed. Shared by the startup
    /// sweep, which has to look at siblings this instance did not create.
    private var socketDirectory: String {
        (path as NSString).deletingLastPathComponent
    }

    /// Prefix shared by every socket file this bundle id could ever have
    /// created, at any pid, past or present: `<bundleid>.control.`. Scoping
    /// the sweep to this prefix is what keeps a dev build from ever touching
    /// a release build's socket, or vice versa.
    private static var socketPrefix: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.kirahowe.agents"
        return "\(bundleID).control."
    }

    private struct Request: Decodable {
        let cmd: String
        /// The row the hook runs in (`AGENTS_SESSION_ID`).
        let session: String?
        let pane: String?
        let event: String?
        let status: String?
        let agent: String?
        let agentSessionID: String?
        let prompt: String?
        /// The harness's configuration home (`CODEX_HOME`, `CLAUDE_CONFIG_DIR`)
        /// when the hook's environment had one — see `SessionResumeMetadata.home`.
        let agentHome: String?
        let version: Int?
        let generation: UUID?
        let runID: String?
        let pid: Int32?
        let turnID: String?
        let requestID: String?
        let message: String?
        let outcome: String?
        let toolName: String?
        let notificationType: String?
        let source: String?
        let willContinue: Bool?
        let isInterrupt: Bool?
        let sequence: UInt64?

        private enum CodingKeys: String, CodingKey {
            case cmd, session, pane, event, status, agent, prompt
            case agentSessionID = "agent_session_id"
            case agentHome = "agent_home"
            case version, generation, pid, message, outcome, source, sequence
            case runID = "run_id"
            case turnID = "turn_id"
            case requestID = "request_id"
            case toolName = "tool_name"
            case notificationType = "notification_type"
            case willContinue = "will_continue"
            case isInterrupt = "is_interrupt"
        }
    }

    /// What one request line asks the app to do, after syntactic validation
    /// but before any main-actor state (live sessions and panes) is
    /// consulted. Extracted from `serve` so the hook's wire-format rules can
    /// be pinned in tests without standing up a socket.
    enum RequestDecision: Equatable {
        case refuse(String)
        case sessionEvent(ControlSessionEvent)
        case harnessEvent(ControlHarnessEvent)
    }

    static func decide(line: String) -> RequestDecision {
        guard let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else {
            return .refuse("malformed request")
        }
        switch request.cmd {
        case "session-event": return decideSessionEvent(request)
        case "harness-event": return decideHarnessEvent(request)
        default: return .refuse("unknown cmd: \(request.cmd)")
        }
    }

    private static func decideHarnessEvent(_ request: Request) -> RequestDecision {
        guard request.version == 1 else { return .refuse("unsupported harness-event version") }
        guard let session = request.session, !session.isEmpty,
              let pane = request.pane.flatMap(UUID.init(uuidString:)),
              let generation = request.generation else {
            return .refuse("harness-event requires session, pane and generation")
        }
        guard let agent = request.agent?.trimmingCharacters(in: .whitespacesAndNewlines), !agent.isEmpty,
              let run = request.runID?.trimmingCharacters(in: .whitespacesAndNewlines), !run.isEmpty,
              let name = request.event?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return .refuse("harness-event requires agent, run_id and event")
        }
        guard request.pid.map({ $0 > 1 }) ?? true else { return .refuse("invalid harness pid") }
        if let outcome = request.outcome, HarnessOutcome(rawValue: outcome) == nil {
            return .refuse("unknown harness outcome")
        }
        let event = HarnessEvent(
            agent: agent.lowercased(), runID: run, conversationID: request.agentSessionID,
            event: name, processID: request.pid, turnID: request.turnID,
            requestID: request.requestID, message: request.message, outcome: request.outcome,
            toolName: request.toolName, notificationType: request.notificationType,
            willContinue: request.willContinue ?? false, isInterrupt: request.isInterrupt ?? false,
            sequence: request.sequence, source: request.source
        )
        return .harnessEvent(ControlHarnessEvent(
            session: session, pane: pane, generation: generation, event: event,
            prompt: request.prompt, home: request.agentHome
        ))
    }

    /// Every refusal here is a contract violation by the sender, not a
    /// runtime condition, and the messages say what to fix: the hook
    /// discards replies, so these are read by someone driving `nc` by hand
    /// after something stopped working.
    private static func decideSessionEvent(_ request: Request) -> RequestDecision {
        guard let session = request.session, !session.isEmpty else {
            return .refuse("missing session — the hook forwards AGENTS_SESSION_ID; rebuild the app if its panes lack it")
        }
        guard let paneString = request.pane, !paneString.isEmpty else {
            return .refuse("missing pane — the hook forwards AGENTS_PANE_ID; rebuild the app if its panes lack it")
        }
        guard let pane = UUID(uuidString: paneString) else {
            return .refuse("malformed pane: \(paneString)")
        }
        let name = (request.event ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .refuse("missing event")
        }

        var status: SessionActivity.StatusMessage?
        if let token = request.status {
            guard let parsed = SessionActivity.statusMessage(token: token) else {
                return .refuse("unknown status: \(token)")
            }
            status = parsed
        }

        var event: AgentSessionEvent?
        let agent = request.agent ?? ""
        let agentSessionID = request.agentSessionID ?? ""
        switch (agent.isEmpty, agentSessionID.isEmpty) {
        case (true, true):
            event = nil
        case (false, true):
            return .refuse("missing agent_session_id")
        case (true, false):
            return .refuse("missing agent")
        case (false, false):
            guard let made = AgentSessionEvent.make(
                agent: agent, name: name, sessionID: agentSessionID, query: request.prompt,
                home: request.agentHome
            ) else {
                return .refuse("blank agent or agent_session_id")
            }
            event = made
        }

        guard status != nil || event != nil else {
            return .refuse("nothing to apply: no status and no agent session")
        }
        return .sessionEvent(
            ControlSessionEvent(session: session, pane: pane, status: status, event: event)
        )
    }

    private let queue = DispatchQueue(label: "com.kirahowe.agents.control")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    /// Answers whether a session id names a live session row. Wired by
    /// `AgentsApp` once the store exists; a request arriving before then (or
    /// naming a session this app has never heard of) is refused. There is no
    /// app-global fallback because each event belongs to one session row.
    @MainActor var validateSession: ((String) -> Bool)?

    /// Applies one hook-delivered session event to the pane it names, or
    /// returns why it can't (an unknown pane, a pane belonging to another
    /// session, a pane whose process is gone). Wired by `AgentsApp` to
    /// `TerminalCenter`, which owns the pane table and the two signal
    /// paths the event feeds. Like `validateSession`, unwired means
    /// refused: the hook's next event carries the same facts again.
    @MainActor var applySessionEvent: ((ControlSessionEvent) -> String?)?
    @MainActor var applyHarnessEvent: ((ControlHarnessEvent) -> String?)?

    init(socketPath: String = ControlServer.socketPath) {
        self.path = socketPath
    }

    @MainActor
    func start() {
        queue.async { [weak self] in self?.bindAndListen() }

        // A clean quit is the one shutdown path worth handling explicitly: it
        // is the only one where something is still around to act. A crash or
        // a force-quit leaves the socket file behind regardless, which is
        // exactly what the startup sweep below exists to clean up on the
        // next launch, so there is no need to duplicate that recovery here —
        // just don't litter the disk on the ordinary path.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
    }

    /// Stops listening and removes the socket file. Idempotent.
    func stop() {
        // Synchronous on purpose: termination does not drain dispatch queues,
        // so an async hop here would race exit(2) and lose often enough to
        // make this cleanup decorative. The control queue cannot deadlock a
        // sync call — bindAndListen has long since finished, accepts only run
        // when the listen fd is readable, and requests are served off-queue.
        queue.sync { [weak self] in
            guard let self else { return }
            if let acceptSource = self.acceptSource {
                acceptSource.cancel()
                self.acceptSource = nil
            }
            if self.listenFD >= 0 {
                close(self.listenFD)
                self.listenFD = -1
            }
            unlink(self.path)
        }
    }

    // MARK: - Socket setup

    private func bindAndListen() {
        let path = self.path
        // Two different processes can never collide on this exact path — it
        // is scoped to our own pid — but pids do wrap and get reused across
        // reboots, so on the small chance a stale file already sits here from
        // some earlier life of this same pid, clear it before bind(2)
        // refuses to reuse it.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("ControlServer: socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            NSLog("ControlServer: socket path too long: \(path)")
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, size)
            }
        }
        guard bound == 0 else {
            NSLog("ControlServer: bind() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        // Owner-only: reports can alter a session's attention state and
        // resume metadata, so other users on the machine must not reach it.
        chmod(path, S_IRUSR | S_IWUSR)

        guard listen(fd, 8) == 0 else {
            NSLog("ControlServer: listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        acceptSource = source

        // Now that our own endpoint exists (and is therefore excluded by
        // path), sweep the rest of the directory for anything this bundle id
        // left behind that nobody is listening on any more — see
        // `sweepDeadSockets` for why a crash or a test-host launch produces
        // exactly that kind of leftover.
        Self.sweepDeadSockets(in: socketDirectory, prefix: Self.socketPrefix, ownPath: path)
    }

    /// Removes control sockets under `directory` whose name starts with
    /// `prefix` and ends in `.sock`, other than `ownPath`, provided nothing
    /// is listening on them any more.
    ///
    /// A crashed instance's per-pid socket file has nobody left to unlink it
    /// — the process that would have done so is gone — and the pre-per-instance
    /// fixed-name file can be orphaned the exact same way by an older build.
    /// `stat` cannot tell a dead file from a live one; they look identical on
    /// disk. Attempting a `connect()` can: a live listener accepts it (the
    /// probe then closes without sending a line, which `serve` already treats
    /// as a no-op, so this never disturbs whatever session is using that
    /// endpoint), while a dead file refuses the connection and is safe to
    /// unlink. Scoping to `prefix` keeps a Debug build's sweep from ever
    /// touching a Release build's socket, and excluding `ownPath` keeps an
    /// instance from probing — let alone removing — the endpoint it just
    /// bound. Free-standing so it can be exercised directly in tests without
    /// standing up a whole `ControlServer`.
    static func sweepDeadSockets(in directory: String, prefix: String, ownPath: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in names {
            guard name.hasPrefix(prefix), name.hasSuffix(".sock") else { continue }
            let path = "\(directory)/\(name)"
            guard path != ownPath, !isSocketLive(at: path) else { continue }
            unlink(path)
        }
    }

    /// Whether some process is listening on the AF_UNIX socket at `path`,
    /// determined the only reliable way: trying to connect to it.
    private static func isSocketLive(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return true } // can't probe — assume live and leave it alone
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return true }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, size)
            }
        }
        return result == 0
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        // A hook can vanish while its request is being handled. The next
        // write(2) to that dead peer would otherwise raise SIGPIPE,
        // which terminates the whole app rather than just failing this one
        // write. SO_NOSIGPIPE turns that into an ordinary EPIPE return, which
        // `reply(to:...)`'s `n <= 0` check below already treats as "stop
        // writing, the peer is gone."
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // Each connection is served off the accept queue so reading one slow
        // client cannot stall later hook reports.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.serve(client: client)
        }
    }

    // MARK: - Request handling

    private func serve(client: Int32) {
        guard let line = readLine(from: client), !line.isEmpty else {
            close(client)
            return
        }
        switch Self.decide(line: line) {
        case .refuse(let error):
            reply(to: client, ok: false, error: error)
        case .sessionEvent(let event):
            serveSessionEvent(client: client, event: event)
        case .harnessEvent(let event):
            Task { @MainActor [weak self] in
                guard let self else { close(client); return }
                guard self.validateSession?(event.session) == true else {
                    self.reply(to: client, ok: false, error: "unknown session: \(event.session)")
                    return
                }
                guard let apply = self.applyHarnessEvent else {
                    self.reply(to: client, ok: false, error: "harness events are not wired")
                    return
                }
                let error = apply(event)
                self.reply(to: client, ok: error == nil, error: error)
            }
        }
    }

    /// Answered the moment the event is applied — the hook's `nc` is what
    /// holds the agent's next step until then, so this must never wait on
    /// anything but the main actor.
    private func serveSessionEvent(client: Int32, event: ControlSessionEvent) {
        Task { @MainActor [weak self] in
            guard let self else {
                close(client)
                return
            }
            guard self.validateSession?(event.session) == true else {
                self.reply(to: client, ok: false, error: "unknown session: \(event.session)")
                return
            }
            guard let apply = self.applySessionEvent else {
                self.reply(to: client, ok: false, error: "session events are not wired")
                return
            }
            let error = apply(event)
            self.reply(to: client, ok: error == nil, error: error)
        }
    }

    private func reply(to client: Int32, ok: Bool, error: String?) {
        var payload: [String: Any] = ["ok": ok]
        if let error { payload["error"] = error }
        let data = (try? JSONSerialization.data(withJSONObject: payload))
            ?? Data(#"{"ok":false}"#.utf8)
        var line = data
        line.append(0x0A)
        line.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(client, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
        close(client)
    }

    /// Reads one newline-terminated request. Capped because this socket takes
    /// a single small JSON object and nothing else — an unbounded read here
    /// would let any local process grow the app's memory at will.
    private func readLine(from fd: Int32, limit: Int = 64 * 1024) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < limit {
            let n = read(fd, &byte, 1)
            if n <= 0 { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
            if byte == 0x0A { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct ControlHarnessEvent: Equatable {
    let session: String
    let pane: UUID
    let generation: UUID
    let event: HarnessEvent
    let prompt: String?
    let home: String?
}

/// One hook event for one pane, as delivered over the control socket by
/// `hooks/agents-status.sh`: the same two facts the pty-borne protocols
/// carry, on a transport that cannot lose them. `status` is the structured
/// `agents:status` vocabulary (see `SessionActivity.statusMessage`) and
/// `event` the `agents:session` announcement (see `AgentSessionEvent.make`).
/// Either half may be absent — a `PostToolUse` carries status only, and a
/// hook that could not identify its harness carries no session — but a
/// line with neither is refused rather than accepted as a no-op.
struct ControlSessionEvent: Equatable {
    var session: String
    var pane: UUID
    var status: SessionActivity.StatusMessage?
    var event: AgentSessionEvent?
}
