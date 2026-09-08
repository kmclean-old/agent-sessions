import AppKit
import GhosttyTerminal
import XCTest
@testable import Agents

/// `TerminalCenter.terminalConfiguration` is the ghostty configuration
/// applied to every spawned session's shell. It used to be built inline as
/// an anonymous closure passed straight to `TerminalController`, which made
/// it impossible to assert on. Now that it's a static `TerminalConfiguration`
/// value, these tests pin its rendered output directly.
///
/// `TerminalConfigCommand.renderedLine` (GhosttyTerminal) renders each
/// setting as `"key = value"` — a single space on each side of `=`, no
/// quoting — so assertions below match that exact shape rather than
/// guessing at ghostty.conf syntax.
@MainActor
final class TerminalCenterTests: XCTestCase {
    private var rendered: String { TerminalCenter.terminalConfiguration.rendered }

    func testTermIsXterm256Color() {
        XCTAssertTrue(
            rendered.contains("term = xterm-256color"),
            "term=xterm-256color is missing from the terminal configuration — dropping the override is a pending decision (see .issues), not a side effect: every spawned shell would silently switch to TERM=xterm-ghostty, which remote hosts without that terminfo entry cannot use"
        )
    }

    func testWindowPaddingXIsSet() {
        XCTAssertTrue(
            rendered.contains("window-padding-x = 10"),
            "window-padding-x=10 is missing from the terminal configuration — terminal content will lose its horizontal breathing room"
        )
    }

    func testWindowPaddingYIsSet() {
        XCTAssertTrue(
            rendered.contains("window-padding-y = 10"),
            "window-padding-y=10 is missing from the terminal configuration — terminal content will lose its vertical breathing room"
        )
    }

    func testCursorColorMatchesBrandTheme() {
        XCTAssertTrue(
            rendered.contains("cursor-color = \(Theme.Terminal.cursorColor)"),
            "cursor-color no longer matches Theme.Terminal.cursorColor — the app has quietly lost its brand cursor colour"
        )
    }

    func testCursorTextMatchesBrandTheme() {
        XCTAssertTrue(
            rendered.contains("cursor-text = \(Theme.Terminal.cursorText)"),
            "cursor-text no longer matches Theme.Terminal.cursorText — the app has quietly lost its brand cursor text colour"
        )
    }

    func testSelectionBackgroundMatchesBrandTheme() {
        XCTAssertTrue(
            rendered.contains("selection-background = \(Theme.Terminal.selectionBackground)"),
            "selection-background no longer matches Theme.Terminal.selectionBackground — the app has quietly lost its brand selection colour"
        )
    }

    func testSelectionForegroundMatchesBrandTheme() {
        XCTAssertTrue(
            rendered.contains("selection-foreground = \(Theme.Terminal.selectionForeground)"),
            "selection-foreground no longer matches Theme.Terminal.selectionForeground — the app has quietly lost its brand selection colour"
        )
    }

    /// `TerminalCenter.sessionEnvVars` is the app's half of its contract with
    /// `hooks/agents-status.sh`: that hook is registered globally in the
    /// user's Claude Code settings (so it also runs for sessions hosted in
    /// iTerm2 and every other terminal), and it refuses to report anything
    /// unless it sees a non-empty `AGENTS_APP` in its environment. If this
    /// function ever loses that key — or stops being passed through to
    /// `TerminalSurfaceOptions.envVars` — the hook keeps running exactly as
    /// before but silently exits before connecting, which means every
    /// session's sidebar status indicator (the gold/red dot) and every
    /// restore banner simply stop working, with nothing in this app's own
    /// logs to explain why.
    func testSessionEnvVarsStampsAGENTS_APP() {
        let value = TerminalCenter.sessionEnvVars(for: "some-session")["AGENTS_APP"]
        XCTAssertNotNil(
            value,
            "TerminalCenter.sessionEnvVars is missing AGENTS_APP — hooks/agents-status.sh gates everything it does on that variable, so every session's sidebar status indicator and restore banner would silently stop working with no error to point at why"
        )
        XCTAssertFalse(
            value?.isEmpty ?? true,
            "TerminalCenter.sessionEnvVars sets AGENTS_APP to an empty string — the hook's guard treats an unset-or-empty value identically, so this would disable the hook just as completely as dropping the key entirely"
        )
    }

    /// `AGENTS_PANE_ID` is how the hook names the pane it runs in when it
    /// reports over the control socket. Every pane of a session shares the
    /// session's socket and session id, so without it the app could tell
    /// neither which pane's agent is blocked nor which pane's agent may
    /// author the row's resume record — and the hook, finding it unset,
    /// exits without reporting at all.
    func testSessionEnvVarsStampsThePaneIDOnlyForPanes() {
        let pane = UUID()
        XCTAssertEqual(
            TerminalCenter.sessionEnvVars(for: "row-uuid-123", paneID: pane)["AGENTS_PANE_ID"],
            pane.uuidString
        )
        XCTAssertNil(
            TerminalCenter.sessionEnvVars(for: "row-uuid-123")["AGENTS_PANE_ID"],
            "a caller without a pane identity must not report hook events for another pane"
        )
    }

    func testSessionEnvVarsEnablesWarpCliAgentProtocol() {
        XCTAssertEqual(
            TerminalCenter.sessionEnvVars(for: "some-session")["WARP_CLI_AGENT_PROTOCOL_VERSION"],
            "1"
        )
    }

    func testSessionEnvVarsStampsTheSessionID() {
        XCTAssertEqual(
            TerminalCenter.sessionEnvVars(for: "row-uuid-123")["AGENTS_SESSION_ID"],
            "row-uuid-123"
        )
    }

    func testSessionEnvVarsAdvertisesTheControlSocket() {
        XCTAssertEqual(
            TerminalCenter.sessionEnvVars(for: "some-session")["AGENTS_CONTROL_SOCK"],
            ControlServer.socketPath
        )
    }

    func testQuiescedSessionCannotBeLazilyRecreatedUntilResumed() async {
        let center = TerminalCenter()
        let sessionID = "quiesced"

        await center.quiesceSessions(Set([sessionID]))

        XCTAssertTrue(center.isSessionQuiesced(sessionID))
        XCTAssertNil(
            center.terminalView(
                for: sessionID,
                workingDirectory: "/tmp",
                restoredResume: nil
            )
        )

        center.resumeSessions(Set([sessionID]))

        XCTAssertFalse(center.isSessionQuiesced(sessionID))
        XCTAssertNotNil(
            center.terminalView(
                for: sessionID,
                workingDirectory: "/tmp",
                restoredResume: nil
            )
        )
    }

    func testRecreatedOmpSurfaceDeliversPersistedResumeHintExactlyOnce() async {
        var deliveredTexts: [String] = []
        var deliveryProxies: [SessionDelegateProxy] = []
        let center = TerminalCenter(
            textDelivery: { view, text in
                deliveredTexts.append(text)
                deliveryProxies.append(view.delegate as! SessionDelegateProxy)
            },
            promptSettleDelay: 0, promptFallbackDelay: 0, loginShell: "/bin/zsh"
        )
        let sessionID = "recreated"
        let hostView = NSView()
        let oldView = center.terminalView(
            for: sessionID,
            workingDirectory: "/tmp",
            restoredResume: nil
        )!
        hostView.addSubview(oldView)
        let oldProxy = oldView.delegate as! SessionDelegateProxy
        XCTAssertNil(oldView.configuration.command, "nothing to resume yet: a plain login shell")
        var exitedIDs: [String] = []
        center.onProcessExit = { exitedIDs.append($0) }

        await center.quiesceSessions(Set([sessionID]))
        XCTAssertNil(oldView.controller)

        center.resumeSessions(Set([sessionID]))
        let metadata = SessionResumeMetadata(
            agent: "omp",
            sessionID: "omp-recreated",
            title: "Repair recreation",
            prompt: nil
        )
        let recreatedView = center.terminalView(
            for: sessionID,
            workingDirectory: "/tmp",
            restoredResume: metadata
        )!
        let recreatedProxy = recreatedView.delegate as! SessionDelegateProxy
        XCTAssertEqual(
            recreatedView.configuration.command,
            SessionResumeMetadata.restoreShellCommand(for: metadata, loginShell: "/bin/zsh"),
            "the reused view is respawned with the CURRENT record's heading command, not whatever it was first spawned with"
        )
        hostView.addSubview(recreatedView)
        center.handleSurfaceAttached(paneID: center.layouts[sessionID]!.initialPane)

        oldProxy.terminalDidClose(processAlive: false)

        XCTAssertTrue(exitedIDs.isEmpty)
        XCTAssertTrue(recreatedView === oldView)
        XCTAssertFalse(recreatedProxy === oldProxy)
        XCTAssertTrue(
            center.terminalView(
                for: sessionID,
                workingDirectory: "/tmp",
                restoredResume: metadata
            ) === recreatedView
        )
        XCTAssertTrue(deliveredTexts.isEmpty)

        center.showResumeHintIfNeeded(for: sessionID)
        center.showResumeHintIfNeeded(for: sessionID)
        await drainMainQueue()

        center.showResumeHintIfNeeded(for: sessionID)
        await drainMainQueue()

        XCTAssertEqual(
            deliveredTexts,
            ["omp --resume omp-recreated"],
            "only the resume command is typed — the heading is the spawn's own output"
        )
        XCTAssertEqual(deliveryProxies.count, 1)
        XCTAssertTrue(deliveryProxies[0] === recreatedProxy)
        XCTAssertFalse(deliveryProxies[0] === oldProxy)
    }

    func testRestoredSessionsInitialPaneIsSpawnedWithTheHeadingCommand() {
        let center = TerminalCenter(promptSettleDelay: 0, promptFallbackDelay: 0, loginShell: "/bin/zsh")
        let metadata = SessionResumeMetadata(agent: "claude", sessionID: "c-1", title: "Restored work", prompt: nil)

        let restored = center.terminalView(for: "restored", workingDirectory: "/tmp", restoredResume: metadata)!
        XCTAssertEqual(
            restored.configuration.command,
            SessionResumeMetadata.restoreShellCommand(for: metadata, loginShell: "/bin/zsh"),
            "the heading is the pane's own output: the initial pane is spawned with the command that prints it and then becomes the login shell"
        )
        XCTAssertEqual(restored.configuration.workingDirectory, "/tmp")
        XCTAssertEqual(
            restored.configuration.envVars["AGENTS_SESSION_ID"], "restored",
            "the heading command changes nothing else about the spawn — the hook's environment contract still holds"
        )

        let split = center.splitPane(in: "restored", axis: .horizontal, workingDirectory: "/tmp")!
        XCTAssertNil(
            center.view(forPane: split)?.configuration.command,
            "a split is a plain shell — the heading belongs to the initial pane only, like the typed command"
        )

        let fresh = center.terminalView(for: "fresh", workingDirectory: "/tmp", restoredResume: nil)!
        XCTAssertNil(fresh.configuration.command, "a session with nothing to resume is spawned as the plain login shell")
    }

    func testRestoredSessionUnderANonZshLoginShellIsSpawnedPlain() {
        let center = TerminalCenter(promptSettleDelay: 0, promptFallbackDelay: 0, loginShell: "/bin/bash")
        let metadata = SessionResumeMetadata(agent: "claude", sessionID: "c-1", title: "Restored work", prompt: nil)

        let restored = center.terminalView(for: "restored", workingDirectory: "/tmp", restoredResume: metadata)!

        XCTAssertNil(
            restored.configuration.command,
            "no heading for a shell whose Ghostty integration the spawn could not carry through — the plain shell, with the resume command still typed into it, beats a pane that quietly lost its integration"
        )
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
