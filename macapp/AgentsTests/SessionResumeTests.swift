import XCTest
@testable import Agents

final class SessionResumeTests: XCTestCase {

    // MARK: - Parsing

    func testParsesWarpTitleWithOmpAgent() {
        let event = AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.warpNotificationTitle,
            body: #"{"event":"permission_request","v":1,"agent":"omp","session_id":"abc-123","cwd":"/tmp/p","project":"p","plugin_version":"1.2.3","summary":"Run tests","future":true}"#
        )

        XCTAssertEqual(event?.agent, "omp")
        XCTAssertEqual(event?.name, "permission_request")
        XCTAssertEqual(event?.sessionID, "abc-123")
        XCTAssertNil(event?.query)
    }

    func testParsesHookTitleWithClaudeAgent() {
        let event = AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.hookNotificationTitle,
            body: #"{"event":"session_start","v":1,"agent":"claude","session_id":"c-1"}"#
        )

        XCTAssertEqual(event?.agent, "claude", "the app's own hook title must decode Claude Code sessions, not just OMP's Warp title")
        XCTAssertEqual(event?.sessionID, "c-1")
    }

    func testParsesHookTitleWithCodexAgent() {
        let event = AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.hookNotificationTitle,
            body: #"{"event":"session_start","v":1,"agent":"codex","session_id":"x-1"}"#
        )

        XCTAssertEqual(event?.agent, "codex")
        XCTAssertEqual(event?.sessionID, "x-1")
    }

    func testClaudeUnderWarpTitleIsNowAcceptedBecauseTheProtocolIsHarnessAgnostic() {
        // Inverts the old OMP-only test: the wire shape is shared, so any
        // emitter speaking it through Warp's title must be accepted, not
        // just OMP. Rejecting a non-"omp" agent here would make the app
        // brittle to a future harness that (for whatever reason) speaks
        // through the Warp title instead of the app's own hook title.
        let event = AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.warpNotificationTitle,
            body: #"{"event":"session_start","v":1,"agent":"claude","session_id":"c-1"}"#
        )

        XCTAssertEqual(event?.agent, "claude")
    }

    func testAgentIsLowercasedAndTrimmed() {
        let event = AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.hookNotificationTitle,
            body: #"{"event":"session_start","v":1,"agent":" Claude ","session_id":"c-1"}"#
        )

        XCTAssertEqual(event?.agent, "claude", "AppStore/SessionResumeMetadata switch on lowercase agent strings, so a differently-cased or padded value from the hook must be normalized here, once, rather than everywhere it's compared")
    }

    func testExtraFieldsAreIgnored() {
        let event = AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.hookNotificationTitle,
            body: #"{"event":"session_start","v":1,"agent":"codex","session_id":"x-1","cwd":"/tmp","future_field":42}"#
        )

        XCTAssertEqual(event?.sessionID, "x-1")
    }

    func testExtractsAndCapsOptionalQueryPreview() {
        let query = String(repeating: "é", count: 205)
        let body = #"{"event":"prompt_submit","v":1,"agent":"omp","session_id":"abc","query":"\#(query)"}"#

        let event = AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.warpNotificationTitle,
            body: body
        )

        XCTAssertEqual(event?.query?.count, 200)
        XCTAssertEqual(event?.query, String(query.prefix(200)))
    }

    func testQueryPreviewCollapsesWhitespaceStripsControlsThenCapsAt200Characters() {
        let prefix = String(repeating: "a", count: 195)
        let body = #"{"event":"prompt_submit","v":1,"agent":"omp","session_id":"abc","query":"\#(prefix)\n\t\u001B\u0003tail and more"}"#

        let event = AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.warpNotificationTitle,
            body: body
        )

        XCTAssertEqual(event?.query, String(repeating: "a", count: 195) + " tail")
        XCTAssertEqual(event?.query?.count, 200)
        XCTAssertFalse(event?.query?.contains("\n") ?? true)
        XCTAssertFalse(event?.query?.contains("\u{001B}") ?? true)
        XCTAssertFalse(event?.query?.contains("\u{0003}") ?? true)
    }

    func testRejectsWrongTitles() {
        let validBody = #"{"event":"stop","v":1,"agent":"omp","session_id":"abc"}"#
        XCTAssertNil(
            AgentSessionEvent.parseNotification(title: "warp://cli-agent/other", body: validBody),
            "only an exact match on one of the two magic titles may decode — a look-alike title must not slip through"
        )
        XCTAssertNil(
            AgentSessionEvent.parseNotification(title: "agents:status", body: validBody),
            "agents:status is a different protocol entirely (free-text/structured attention), not a session-resume envelope"
        )
    }

    func testRejectsMalformedJSON() {
        XCTAssertNil(AgentSessionEvent.parseNotification(title: AgentSessionEvent.warpNotificationTitle, body: "{"))
        XCTAssertNil(AgentSessionEvent.parseNotification(title: AgentSessionEvent.hookNotificationTitle, body: "not json"))
    }

    func testRejectsVersionOtherThanOne() {
        XCTAssertNil(AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.warpNotificationTitle,
            body: #"{"event":"stop","v":2,"agent":"omp","session_id":"abc"}"#
        ))
    }

    func testRejectsMissingEvent() {
        XCTAssertNil(AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.warpNotificationTitle,
            body: #"{"v":1,"agent":"omp","session_id":"abc"}"#
        ))
    }

    func testRejectsBlankSessionID() {
        XCTAssertNil(AgentSessionEvent.parseNotification(
            title: AgentSessionEvent.warpNotificationTitle,
            body: #"{"event":"stop","v":1,"agent":"omp","session_id":"  "}"#
        ))
    }

    func testRejectsBlankOrMissingAgent() {
        XCTAssertNil(
            AgentSessionEvent.parseNotification(
                title: AgentSessionEvent.hookNotificationTitle,
                body: #"{"event":"stop","v":1,"agent":"  ","session_id":"abc"}"#
            ),
            "a blank agent must not decode into an empty-string harness identifier that would then silently fail every downstream switch"
        )
        XCTAssertNil(
            AgentSessionEvent.parseNotification(
                title: AgentSessionEvent.hookNotificationTitle,
                body: #"{"event":"stop","v":1,"session_id":"abc"}"#
            ),
            "a missing agent field must reject rather than decode as an empty string"
        )
    }

    // MARK: - make (shared by the OSC and control-socket transports)

    func testMakeNormalizesExactlyLikeParseNotification() {
        let made = AgentSessionEvent.make(
            agent: " Claude ", name: " UserPromptSubmit ", sessionID: " c-1 ", query: "Fix\n\tthe\u{001B} parser"
        )

        XCTAssertEqual(
            made,
            AgentSessionEvent(agent: "claude", name: "UserPromptSubmit", sessionID: "c-1", query: "Fix the parser"),
            "the control-socket path builds events through make() — it must apply the same lowercase/trim/one-line rules the OSC path does, or the same session would look different depending on which transport announced it"
        )
    }

    func testMakeRejectsBlankIdentityAndDropsABlankQuery() {
        XCTAssertNil(AgentSessionEvent.make(agent: " ", name: "e", sessionID: "s", query: nil))
        XCTAssertNil(AgentSessionEvent.make(agent: "claude", name: " ", sessionID: "s", query: nil))
        XCTAssertNil(AgentSessionEvent.make(agent: "claude", name: "e", sessionID: " ", query: nil))
        let blankQuery = AgentSessionEvent.make(agent: "claude", name: "e", sessionID: "s", query: " \n ")
        XCTAssertNotNil(blankQuery)
        XCTAssertNil(blankQuery?.query, "a whitespace-only prompt is no prompt — it must not become an empty heading fallback in the banner")
    }

    // MARK: - displayName / resumeCommand

    func testMakeTrimsTheHomeAndDropsABlankOne() {
        XCTAssertEqual(
            AgentSessionEvent.make(agent: "codex", name: "SessionStart", sessionID: "x", query: nil, home: " /Users/kira/.codex-kira ")?.home,
            "/Users/kira/.codex-kira"
        )
        XCTAssertNil(AgentSessionEvent.make(agent: "codex", name: "SessionStart", sessionID: "x", query: nil, home: "  ")?.home)
        XCTAssertNil(AgentSessionEvent.make(agent: "codex", name: "SessionStart", sessionID: "x", query: nil)?.home)
    }

    func testDisplayNameForKnownAndUnknownAgents() {
        XCTAssertEqual(SessionResumeMetadata.displayName(agent: "omp"), "OMP")
        XCTAssertEqual(SessionResumeMetadata.displayName(agent: "claude"), "Claude Code")
        XCTAssertEqual(SessionResumeMetadata.displayName(agent: "codex"), "Codex")
        XCTAssertEqual(
            SessionResumeMetadata.displayName(agent: "gemini"), "gemini",
            "an agent this table has never heard of must still print something sensible in a resume hint, rather than an empty or placeholder string"
        )
    }

    func testResumeCommandForKnownAgents() {
        let omp = SessionResumeMetadata(agent: "omp", sessionID: "s-1", title: nil, prompt: nil)
        let claude = SessionResumeMetadata(agent: "claude", sessionID: "s-2", title: nil, prompt: nil)
        let codex = SessionResumeMetadata(agent: "codex", sessionID: "s-3", title: nil, prompt: nil)

        XCTAssertEqual(SessionResumeMetadata.resumeCommand(for: omp), "omp --resume s-1")
        XCTAssertEqual(SessionResumeMetadata.resumeCommand(for: claude), "claude --resume s-2")
        XCTAssertEqual(
            SessionResumeMetadata.resumeCommand(for: codex), "codex resume s-3",
            "Codex's real CLI syntax has no `--` before the session id, unlike omp/claude — getting this wrong would hand the user a command that fails outright"
        )
    }

    func testResumeCommandForUnknownAgentIsNil() {
        let gemini = SessionResumeMetadata(agent: "gemini", sessionID: "s-4", title: nil, prompt: nil)

        XCTAssertNil(
            SessionResumeMetadata.resumeCommand(for: gemini),
            "an agent with no known resume syntax must yield no command, not a guessed-at one that could fail or do the wrong thing"
        )
    }

    // MARK: - normalizedTitle

    func testNormalizesOnlyDocumentedOmpTitleDecorations() {
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("π > Refactor parser", agent: "omp"), "Refactor parser")
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("π ⠼ Refactor parser", agent: "omp"), "Refactor parser")
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("π ! Refactor parser", agent: "omp"), "Refactor parser")
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("π: Refactor parser", agent: "omp"), "Refactor parser")
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("π >", agent: "omp"))
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("π project shell", agent: "omp"))
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("π >not a decoration", agent: "omp"))
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("ordinary title", agent: "omp"))
    }

    func testNormalizesAllFiveDocumentedClaudeGlyphs() {
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("✳ Fix parser", agent: "claude"), "Fix parser")
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("◐ Fix parser", agent: "claude"), "Fix parser")
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("◓ Fix parser", agent: "claude"), "Fix parser")
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("◑ Fix parser", agent: "claude"), "Fix parser")
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("◒ Fix parser", agent: "claude"), "Fix parser")
    }

    func testClaudeBareGlyphAndNoSpaceAreNotRecognized() {
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("✳", agent: "claude"), "a bare idle glyph with no summary must not be read as a title")
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("✳Fix", agent: "claude"), "no separating space means this isn't Claude Code's documented decoration")
    }

    func testClaudeRejectsPlainShellTitle() {
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("kira@Mac:~/code", agent: "claude"))
    }

    func testClaudeLaunchPlaceholderTitleIsNotATitle() {
        XCTAssertNil(
            SessionResumeMetadata.normalizedTitle("✳ Claude Code", agent: "claude"),
            "'✳ Claude Code' is what Claude Code shows before the first exchange is summarized — the program's name, not the conversation's — and a banner saying 'Last Claude Code session: Claude Code' would displace the more useful prompt fallback"
        )
        XCTAssertEqual(SessionResumeMetadata.normalizedTitle("✳ Claude Code review", agent: "claude"), "Claude Code review")
    }

    func testCrossAgentDecorationsDoNotMatch() {
        XCTAssertNil(
            SessionResumeMetadata.normalizedTitle("π > Task", agent: "claude"),
            "OMP's own decoration must never be mistaken for Claude Code's just because a row switched harnesses — a stale π title surviving under the wrong agent would misreport whose session this is"
        )
    }

    func testCodexAndUnknownAgentsHaveNoKnownDecoration() {
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("anything", agent: "codex"))
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("✳ Fix parser", agent: "codex"), "Claude's glyphs must not be recognized under a different agent")
        XCTAssertNil(SessionResumeMetadata.normalizedTitle("anything", agent: "gemini"))
    }

    // MARK: - resumeCommand: configuration home

    func testResumeCommandCarriesTheHarnessHomeAsAVariablePrefix() {
        let codex = SessionResumeMetadata(agent: "codex", sessionID: "s-3", title: nil, prompt: nil, home: "/Users/kira/.codex-kira")
        let claude = SessionResumeMetadata(agent: "claude", sessionID: "s-2", title: nil, prompt: nil, home: "/Users/kira/.claude-kira")

        XCTAssertEqual(
            SessionResumeMetadata.resumeCommand(for: codex), "CODEX_HOME=/Users/kira/.codex-kira codex resume s-3",
            "Codex keeps its sessions under CODEX_HOME: a bare `codex resume` typed into a fresh shell that never set it looks in ~/.codex and fails, so the command must carry the home it ran under"
        )
        XCTAssertEqual(SessionResumeMetadata.resumeCommand(for: claude), "CLAUDE_CONFIG_DIR=/Users/kira/.claude-kira claude --resume s-2")
    }

    func testResumeCommandIgnoresAHomeForOmpAndABlankHome() {
        let omp = SessionResumeMetadata(agent: "omp", sessionID: "s-1", title: nil, prompt: nil, home: "/somewhere")
        let blank = SessionResumeMetadata(agent: "codex", sessionID: "s-3", title: nil, prompt: nil, home: "  ")

        XCTAssertEqual(
            SessionResumeMetadata.resumeCommand(for: omp), "omp --resume s-1",
            "OMP has no home variable this app knows; a stray value must not be turned into a made-up prefix"
        )
        XCTAssertEqual(SessionResumeMetadata.resumeCommand(for: blank), "codex resume s-3")
    }

    func testResumeCommandQuotesIdsAndHomesTheShellWouldOtherwiseInterpret() {
        let hostile = SessionResumeMetadata(
            agent: "codex", sessionID: "id'; touch /tmp/nope; echo '", title: nil, prompt: nil,
            home: "/Users/kira/My Codex"
        )

        XCTAssertEqual(
            SessionResumeMetadata.resumeCommand(for: hostile),
            "CODEX_HOME='/Users/kira/My Codex' codex resume 'id'\"'\"'; touch /tmp/nope; echo '\"'\"''",
            "the command is typed at the prompt and run by Enter, so a session id or home carrying metacharacters must arrive as one quoted word, never as a second command"
        )
    }

    // MARK: - restoreHeading

    func testRestoreHeadingNamesTheHarnessAndTheRememberedTitle() {
        let metadata = SessionResumeMetadata(agent: "claude", sessionID: "session-123", title: "Repair persistence", prompt: nil)

        XCTAssertEqual(
            SessionResumeMetadata.restoreHeading(for: metadata),
            ["Last Claude Code session: Repair persistence"],
            "a harness with a resume command gets one line — what Enter will resume is already visible in the typed command beneath it"
        )
    }

    func testRestoreHeadingFallsBackToThePromptForAnUntitledSession() {
        let metadata = SessionResumeMetadata(agent: "claude", sessionID: "session-123", title: nil, prompt: "Repair persistence")

        XCTAssertEqual(SessionResumeMetadata.restoreHeading(for: metadata), ["Last Claude Code session: Repair persistence"])
    }

    func testRestoreHeadingForUnknownAgentAddsTheSessionIDAndTypesNothing() {
        let metadata = SessionResumeMetadata(agent: "gemini", sessionID: "id-1", title: "T", prompt: nil)

        XCTAssertEqual(
            SessionResumeMetadata.restoreHeading(for: metadata),
            ["Last gemini session: T", "Session id: id-1"],
            "an agent with no known resume command must not leave a guessed-at command at the prompt — printing the raw session id is the honest fallback"
        )
        XCTAssertNil(SessionResumeMetadata.resumeCommand(for: metadata))
    }

    func testRestoreHeadingWithNoTitleOrPromptOmitsTheColonEntirely() {
        let metadata = SessionResumeMetadata(agent: "claude", sessionID: "session-123", title: nil, prompt: nil)

        XCTAssertEqual(
            SessionResumeMetadata.restoreHeading(for: metadata),
            ["Last Claude Code session"],
            "with neither a title nor a prompt there is nothing to put after a colon, so the heading must read as a plain statement rather than dangle one"
        )
    }

    func testTitleWinsOverPromptAndThePromptNeverGetsItsOwnLine() {
        let titled = SessionResumeMetadata(agent: "claude", sessionID: "s-1", title: "Fix it", prompt: "Original ask")

        XCTAssertEqual(
            SessionResumeMetadata.restoreHeading(for: titled),
            ["Last Claude Code session: Fix it"],
            "the prompt is only ever the heading's fallback for an untitled session — printing it beneath a real title would repeat what the title says"
        )
    }

    func testRestoreHeadingCollapsesNewlinesAndStripsTerminalControls() {
        let titled = SessionResumeMetadata(
            agent: "claude", sessionID: "session-123", title: "Line one\n\tLine two\u{001B}\u{0007}", prompt: nil
        )
        let untitled = SessionResumeMetadata(
            agent: "claude", sessionID: "session-123", title: nil, prompt: "Prompt\r\nnext\u{0003}"
        )

        XCTAssertEqual(SessionResumeMetadata.restoreHeading(for: titled), ["Last Claude Code session: Line one Line two"])
        XCTAssertEqual(SessionResumeMetadata.restoreHeading(for: untitled), ["Last Claude Code session: Prompt next"])
    }

    // MARK: - restoreShellCommand

    func testRestoreShellCommandPrintsTheHeadingThenBecomesTheLoginShell() {
        let metadata = SessionResumeMetadata(agent: "claude", sessionID: "session-123", title: "Repair persistence", prompt: nil)

        XCTAssertEqual(
            SessionResumeMetadata.restoreShellCommand(for: metadata, loginShell: "/bin/zsh"),
            "/bin/zsh -f -c 'printf '\"'\"'%s\\n'\"'\"' '\"'\"'Last Claude Code session: Repair persistence'\"'\"'; exec -l /bin/zsh'",
            "one bash command line for the runtime's `exec -l`: zsh with no startup files, running a script that prints the heading and execs the same zsh as a login shell — the heading is output above the first prompt, and nothing is ever typed to print it"
        )
    }

    func testRestoreShellCommandPrintsEveryHeadingLineForAnUnknownAgent() {
        let metadata = SessionResumeMetadata(agent: "gemini", sessionID: "id-1", title: "T", prompt: nil)

        XCTAssertEqual(
            SessionResumeMetadata.restoreShellCommand(for: metadata, loginShell: "/bin/zsh"),
            "/bin/zsh -f -c 'printf '\"'\"'%s\\n'\"'\"' '\"'\"'Last gemini session: T'\"'\"' '\"'\"'Session id: id-1'\"'\"'; exec -l /bin/zsh'"
        )
    }

    func testRestoreShellCommandIsComposedOnlyForZsh() {
        let metadata = SessionResumeMetadata(agent: "claude", sessionID: "session-123", title: "T", prompt: nil)

        XCTAssertNil(
            SessionResumeMetadata.restoreShellCommand(for: metadata, loginShell: "/bin/bash"),
            "Ghostty picks a pane's shell integration from the command's first word, and bash's rewrites the command line — another login shell gets a plain spawn and no heading rather than a pane that silently lost its integration"
        )
        XCTAssertNil(SessionResumeMetadata.restoreShellCommand(for: metadata, loginShell: "/opt/homebrew/bin/fish"))
        XCTAssertNil(SessionResumeMetadata.restoreShellCommand(for: metadata, loginShell: "/bin/sh"))
        XCTAssertEqual(
            SessionResumeMetadata.restoreShellCommand(for: metadata, loginShell: "/opt/homebrew/bin/zsh")?
                .hasPrefix("/opt/homebrew/bin/zsh -f -c '"),
            true,
            "any zsh counts, not only Apple's: the login shell is whatever the user set"
        )
    }

    /// Runs the composed command exactly as Ghostty's embedded runtime does
    /// on macOS — `/bin/bash --noprofile --norc -c "exec -l <command>"`,
    /// minus `login` — against a stand-in login shell that hands the `-f -c`
    /// script to the real zsh and reports when the script's final `exec -l`
    /// lands back on it. Two levels of quoting (bash around the words, zsh
    /// inside the script) are exactly where a hostile title would break
    /// out, so this is checked against real shells, not by inspection.
    func testRestoreShellCommandSurvivesRealShellParsingWithAHostileTitle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("nope").path
        let stub = directory.appendingPathComponent("zsh")
        try """
        #!/bin/sh
        if [ "$1" = -f ] && [ "$2" = -c ]; then exec /bin/zsh -f -c "$3"; fi
        echo "login shell started with $# arguments"
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let metadata = SessionResumeMetadata(
            agent: "omp", sessionID: "id-1", title: "Kira's run'; touch \(marker); echo '", prompt: nil
        )
        let command = try XCTUnwrap(
            SessionResumeMetadata.restoreShellCommand(for: metadata, loginShell: stub.path)
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", "exec -l \(command)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "Last OMP session: Kira's run'; touch \(marker); echo '\nlogin shell started with 0 arguments\n",
            "the heading is printed verbatim, once, and the login shell follows it"
        )
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "a title is printed, never run — at either quoting level")
    }
}
