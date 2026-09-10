import AppKit
import Sparkle
import SwiftUI

/// Tiny UI-only state that doesn't belong in AppStore's persisted model —
/// currently whether the ⌘? shortcut-help sheet is showing, and whether
/// there's a launch-time prerequisite notice to display. Owned by
/// AgentsApp alongside AppActions: AppActions.perform(.showShortcutHelp)
/// toggles showShortcutHelp, RootView observes both to drive its `.sheet`
/// and `.alert`.
@MainActor
final class UIState: ObservableObject {
    @Published var showShortcutHelp = false

    /// Guidance from `ToolPreflight` when bb or the temporary manager checkout
    /// is missing. Nil means every global prerequisite was found or the notice
    /// was dismissed. Project-specific version-control tools are not checked
    /// here; workspace operations resolve those when needed.
    @Published var prerequisiteNotice: String?
}

@main
struct AgentsApp: App {
    let center: TerminalCenter
    let controlServer: ControlServer
    let actions: AppActions
    let router: ShortcutRouter
    let shortcutCapture: ShortcutCapture
    let uiState: UIState
    let updaterEnabled: Bool
    let updaterController: SPUStandardUpdaterController
    @StateObject private var store: AppStore
    @StateObject private var shortcuts: ShortcutPreferences
    @AppStorage(AppearanceMode.defaultsKey) private var appearanceMode: AppearanceMode = .system

    /// True when this process is an XCTest TEST_HOST launch rather than the
    /// user actually running the app. AgentsTests sets the app as its test
    /// host, so every `bb test` boots this same `AgentsApp.init` — and an
    /// unguarded init in that context touches the REAL user's world: it
    /// loads (and can save) the live state.json, binds a control socket in
    /// the shared socket directory, and installs an event monitor, all in a
    /// throwaway process running beside the app the user is looking at.
    /// That's not hypothetical — a test run doing exactly this alongside a
    /// live instance is what prompted the guard. Checked via the environment
    /// the test runner stamps at launch (the env is present from the first
    /// instruction, unlike the XCTest classes, which may not be injected yet
    /// when this init runs).
    static let isTestHost: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
    }()

    /// What the control server answers the hook for one session event: nil
    /// for applied, else the refusal. Written out as a function rather than
    /// the one-liner it replaced — `center?.handle…(event) ?? "…"` — because
    /// optional chaining flattens the method's own `String?`, where nil means
    /// SUCCESS, into the same nil as a gone center, so that fallback reported
    /// every applied event as "app is shutting down". Nothing read the reply
    /// then; the hook's log does now.
    @MainActor
    static func applySessionEvent(_ event: ControlSessionEvent, to center: TerminalCenter?) -> String? {
        guard let center else { return "app is shutting down" }
        return center.handleControlSessionEvent(event)
    }

    init() {
        let center = TerminalCenter()
        self.center = center

        // Hooks can report as soon as restored sessions start their shells.
        // Test hosts use private servers and must not bind the live app's socket.
        let controlServer = ControlServer()
        self.controlServer = controlServer
        if !Self.isTestHost {
            controlServer.start()
        }

        // A test host gets a throwaway per-pid state path: it must neither
        // read the user's real rows (restored rows spawn real login shells)
        // nor ever write over live state the running app is maintaining.
        let stateURL = Self.isTestHost
            ? FileManager.default.temporaryDirectory.appendingPathComponent(
                "agents-testhost-\(ProcessInfo.processInfo.processIdentifier)-state.json"
            )
            : AppStore.defaultStateURL
        let store = AppStore(terminals: center, stateURL: stateURL)
        _store = StateObject(wrappedValue: store)

        controlServer.validateSession = { [weak store] sessionID in
            store?.sessions.contains { $0.id == sessionID } ?? false
        }

        // TerminalCenter validates hook reports against live panes. The server
        // relays its answer; reports arriving before this wiring are refused.
        controlServer.applySessionEvent = { [weak center] event in
            Self.applySessionEvent(event, to: center)
        }
        controlServer.applyHarnessEvent = { [weak center] event in
            guard let center else { return "app is shutting down" }
            return center.handleControlHarnessEvent(event)
        }

        let uiState = UIState()
        self.uiState = uiState

        let shortcutCapture = ShortcutCapture()
        self.shortcutCapture = shortcutCapture
        let shortcuts = ShortcutPreferences()
        _shortcuts = StateObject(wrappedValue: shortcuts)

        let actions = AppActions(
            store: store,
            uiState: uiState,
            panes: center,
            suppressShortcut: { shortcutCapture.handle($0) }
        )
        self.actions = actions
        let router = ShortcutRouter(
            perform: { actions.perform($0) },
            bindings: { shortcuts.bindings },
            capture: { shortcutCapture.handle($0) }
        )
        self.router = router
        // Local monitors don't need NSApp to have finished launching, so
        // installing here (rather than deferring to RootView's .task) is
        // safe and keeps shortcut wiring colocated with the rest of app
        // construction. (If a real launch shows this is flaky, move the
        // install() call into RootView's .task instead and note why here.)
        if !Self.isTestHost { router.install() }

        // The dev build (com.kirahowe.agents.dev) never starts the updater
        // at all — this bundle-identifier check is the ONLY place that
        // happens, so a dev build can never phone home or attempt a
        // self-update against the release app's identity/state.
        let updaterEnabled = Bundle.main.bundleIdentifier == "com.kirahowe.agents"
        self.updaterEnabled = updaterEnabled
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: updaterEnabled,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Whether the current session belongs to a workspace, used to enable
    /// the selection-targeted close action.
    private var selectionTargetsWorkspace: Bool {
        guard let selection = store.selection,
              let row = store.sessions.first(where: { $0.id == selection })
        else { return false }
        if case .workspace = row.target { return true }
        return false
    }

    var body: some Scene {
        // `Window` (single-window), not `WindowGroup`: TerminalCenter caches
        // exactly one NSView/TerminalController pair per session id, with no
        // notion of "which window" it belongs to. WindowGroup can still spawn
        // a second window (Dock re-open, window-tabbing affordances) even
        // with File > New Window's menu item replaced above, and a second
        // window hosting the same session would either steal its NSView out
        // from under the first window (a view can only have one superview)
        // or show a blank surface. Don't revert this to WindowGroup without
        // first making TerminalCenter's cache window-aware.
        Window("Agents", id: "main") {
            RootView(store: store, center: center, uiState: uiState)
                .environment(\.appActions, actions)
                .environmentObject(shortcuts)
                .environmentObject(shortcutCapture)
                // Forced explicitly rather than left to the asset catalog
                // alone: ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME (set
                // in project.yml) only takes effect when the user's system
                // accent colour preference is "Multicolor" — any other
                // choice overrides it app-wide. This app's tint is part of
                // its identity, not a preference we want the system to
                // override, so `.tint` reapplies `Theme.accent` regardless
                // of that setting.
                .tint(Theme.accent)
        }
        .commands {
            // Deliberately does NOT route through AppActions/Keymap the way
            // the other menu items in this file do: Sparkle owns its own
            // update-checking UI and flow end-to-end, and this touches
            // neither `store` nor `uiState`. It's menu-only, exactly like
            // "Remove Project…" above is menu-only — no .keymapShortcut call
            // either, for the same reason: this isn't a shortcut-table
            // action.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
                .disabled(!updaterEnabled)
            }

            // Replaces (rather than extends) the system File > New Window
            // group: New Window (⌘N) makes no sense for this app, and ⌘N is
            // repurposed below for New Workspace.
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    actions.perform(.newSession)
                }
                .keymapShortcut(.newSession, bindings: shortcuts.bindings)

                Button("New Workspace") {
                    actions.perform(.newWorkspace)
                }
                .keymapShortcut(.newWorkspace, bindings: shortcuts.bindings)

                Button("Add Project…") {
                    actions.perform(.addProject)
                }
                .keymapShortcut(.addProject, bindings: shortcuts.bindings)

                Button("Hide Project") {
                    actions.perform(.archiveProject)
                }
                .keymapShortcut(.archiveProject, bindings: shortcuts.bindings)

                Button("Remove Project…") {
                    actions.perform(.removeProject)
                }
                .keymapShortcut(.removeProject, bindings: shortcuts.bindings)

                Button("Close Workspace…") {
                    actions.perform(.closeWorkspace)
                }
                .disabled(!selectionTargetsWorkspace)
                .keymapShortcut(.closeWorkspace, bindings: shortcuts.bindings)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Close Session") {
                    actions.perform(.closeSession)
                }
                .keymapShortcut(.closeSession, bindings: shortcuts.bindings)
                .disabled(store.selection == nil)

                Button("Close Window") {
                    actions.perform(.closeWindow)
                }
                .keymapShortcut(.closeWindow, bindings: shortcuts.bindings)
            }

            CommandMenu("Session") {
                Button("Rename Session…") {
                    actions.perform(.renameSession)
                }
                .keymapShortcut(.renameSession, bindings: shortcuts.bindings)
                .disabled(store.selection == nil)

                Button("Previous Session") {
                    actions.perform(.previousSession)
                }
                .keymapShortcut(.previousSession, bindings: shortcuts.bindings)

                Button("Next Session") {
                    actions.perform(.nextSession)
                }
                .keymapShortcut(.nextSession, bindings: shortcuts.bindings)

                Divider()

                // Pane commands live in the Session menu rather than their
                // own top-level menu: panes are a property of the selected
                // session, and a seven-item menu of their own would overstate
                // their place in the app.
                Button("Split Pane Right") {
                    actions.perform(.splitPaneRight)
                }
                .keymapShortcut(.splitPaneRight, bindings: shortcuts.bindings)
                .disabled(store.selection == nil)

                Button("Split Pane Down") {
                    actions.perform(.splitPaneDown)
                }
                .keymapShortcut(.splitPaneDown, bindings: shortcuts.bindings)
                .disabled(store.selection == nil)

                Button("Close Pane") {
                    actions.perform(.closePane)
                }
                .keymapShortcut(.closePane, bindings: shortcuts.bindings)
                .disabled(store.selection == nil)

                // The four focus-movement commands are deliberately NOT menu
                // items: they're navigation keystrokes like ⌘1–9 (also
                // menu-less), and four directional entries would double the
                // menu's length to say "arrow keys move focus."
            }

            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    actions.perform(.showShortcutHelp)
                }
                .keymapShortcut(.showShortcutHelp, bindings: shortcuts.bindings)
            }
        }
        // The single place the appearance preference is actually applied.
        // `initial: true` covers launch; the same observer fires again when
        // the Settings window's picker rewrites the shared @AppStorage key,
        // since both read/write the same UserDefaults entry — so there's no
        // second application site for the two to drift apart from each
        // other. (Scene.onChange(of:initial:) exists on macOS 14+; this
        // app's deployment target is 15.)
        .onChange(of: appearanceMode, initial: true) { _, mode in
            mode.apply()
        }

        // A `Settings` scene is what makes macOS add "Settings…" (⌘,) to the
        // app menu automatically — no CommandGroup wiring needed, unlike
        // every menu item above.
        Settings {
            SettingsView(store: store)
                // Reapplied here because the `.tint` on the main Window's
                // content (above) doesn't reach a separate scene — the same
                // system-accent-override reasoning applies as there.
                .tint(Theme.accent)
        }
    }
}

private extension View {
    /// Use the same effective bindings as the event router. Passing nil
    /// explicitly removes an old key equivalent when the user clears it.
    func keymapShortcut(_ action: AppAction, bindings: [AppAction: Shortcut]) -> some View {
        let shortcut = bindings[action]?.swiftUIShortcut
        return keyboardShortcut(shortcut.map { KeyboardShortcut($0.key, modifiers: $0.modifiers) })
    }
}
