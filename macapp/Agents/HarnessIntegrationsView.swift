import AppKit
import SwiftUI

@MainActor
final class HarnessIntegrationsModel: ObservableObject {
    static let addedHomesKey = "harnessIntegrationHomes"

    @Published private(set) var inspections: [HarnessSetupInspection] = []
    @Published var preview: HarnessSetupPlan?
    @Published var error: String?
    @Published private(set) var notice: String?

    private let service: HarnessSetupService
    private let defaults: UserDefaults
    private var addedHomes: [HarnessHome]

    init(service: HarnessSetupService = HarnessSetupService(), defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.addedHomesKey),
           let homes = try? JSONDecoder().decode([HarnessHome].self, from: data) {
            addedHomes = homes
        } else {
            addedHomes = []
        }
    }

    func refresh() {
        do {
            let discovered = try service.discoverHomes()
            var seen = Set<String>()
            inspections = (discovered + addedHomes)
                .filter { seen.insert($0.id).inserted }
                .sorted { ($0.harness.rawValue, $0.directory.path) < ($1.harness.rawValue, $1.directory.path) }
                .map { service.inspect($0) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func addHome(_ directory: URL, for harness: HarnessKind) {
        let home = HarnessHome(harness: harness, directory: directory.standardizedFileURL)
        guard !addedHomes.contains(where: { $0.id == home.id }) else {
            refresh()
            return
        }
        do {
            let homes = addedHomes + [home]
            defaults.set(try JSONEncoder().encode(homes), forKey: Self.addedHomesKey)
            addedHomes = homes
            refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func prepare(_ home: HarnessHome, action: HarnessSetupAction) {
        notice = nil
        do {
            preview = try service.prepare(home, action: action)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func apply(_ plan: HarnessSetupPlan) {
        do {
            try service.apply(plan)
            preview = nil
            refresh()
            if plan.action == .remove {
                notice = "Removed the Agents integration from \(plan.home.directory.path)."
            } else {
                var message = "Configured \(plan.home.harness.label). Start a fresh harness in a new Agents pane to send reports."
                if plan.home.harness == .codex {
                    message += " Open /hooks in Codex to review and approve its hooks."
                }
                notice = message
            }
        } catch {
            preview = nil
            refresh()
            self.error = error.localizedDescription
        }
    }
}

struct HarnessIntegrationsView: View {
    @ObservedObject var store: AppStore
    @StateObject private var model = HarnessIntegrationsModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Text("Configure each user configuration home once to receive harness reports in Agents panes.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
            }
            .padding()

            Form {
                ForEach(HarnessKind.allCases) { harness in
                    Section {
                        runtimeEvidence(for: harness)
                        ForEach(model.inspections.filter { $0.home.harness == harness }, id: \.home.id) { inspection in
                            homeRow(inspection)
                        }
                        Button("Add configuration home…") { chooseHome(for: harness) }
                    } header: {
                        Text(harness.label)
                    }
                }
            }
            .formStyle(.grouped)

            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
        }
        .onAppear { model.refresh() }
        .sheet(item: $model.preview) { plan in
            HarnessSetupPreview(plan: plan, cancel: { model.preview = nil }, apply: { model.apply(plan) })
        }
        .alert("Harness setup could not finish", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private func runtimeEvidence(for harness: HarnessKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let date = store.observedHarnessReports[harness.rawValue] {
                Text("Runtime: report received \(date.formatted(date: .abbreviated, time: .standard)).")
                Text("This report confirms \(harness.label) has reported during this app launch; its configuration home is not identified.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Runtime: no report received during this app launch.")
                Text("An idle harness may not send reports. Start a fresh harness in a new Agents pane to check the integration.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func homeRow(_ inspection: HarnessSetupInspection) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(inspection.home.directory.path)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Text("Configuration: \(inspection.status.label)")
                .fontWeight(.medium)
            Text(inspection.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            if inspection.home.harness == .codex {
                Text("Codex requires its own hook trust review. Open /hooks in Codex to review the installed hooks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Install…") { model.prepare(inspection.home, action: .install) }
                    .disabled(inspection.status != .notInstalled)
                Button("Repair…") { model.prepare(inspection.home, action: .repair) }
                    .disabled(inspection.status == .unavailable || inspection.status == .notInstalled)
                Button("Remove…") { model.prepare(inspection.home, action: .remove) }
                    .disabled(inspection.status == .notInstalled)
            }
        }
        .padding(.vertical, 5)
    }

    private func chooseHome(for harness: HarnessKind) {
        let panel = NSOpenPanel()
        panel.title = "Choose a \(harness.label) configuration home"
        panel.message = "Select the user configuration directory used by this harness or profile."
        panel.prompt = "Add home"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let directory = panel.url {
            model.addHome(directory, for: harness)
        }
    }
}

private struct HarnessSetupPreview: View {
    let plan: HarnessSetupPlan
    let cancel: () -> Void
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(plan.action.label) \(plan.home.harness.label) integration")
                .font(.title2)
            Text(plan.home.directory.path)
                .textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(plan.notes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                    }
                    if plan.changes.isEmpty {
                        Text("The integration is already up to date. No files will change.")
                    }
                    ForEach(Array(plan.changes.enumerated()), id: \.offset) { _, change in
                        HarnessSetupFilePreview(change: change)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 580)
    }
}

private struct HarnessSetupFilePreview: View {
    let change: HarnessSetupFileChange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(change.path)
                .fontWeight(.medium)
                .textSelection(.enabled)
            Text(change.before == nil ? "Create file" : change.after == nil ? "Remove file" : "Update file")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isConfiguration {
                contents
            } else {
                DisclosureGroup("Show file changes") { contents }
            }
        }
    }

    private var isConfiguration: Bool {
        let url = URL(fileURLWithPath: change.path)
        return url.lastPathComponent != "registry.json"
            && ["json", "yml", "yaml", "toml"].contains(url.pathExtension)
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let before = change.before {
                DisclosureGroup("Current contents") { source(before) }
            }
            if let after = change.after {
                Text("Contents after applying")
                    .font(.caption)
                source(after)
            }
        }
    }

    private func source(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

private extension HarnessConfigurationStatus {
    var label: String {
        switch self {
        case .notInstalled: "Not installed"
        case .configured: "Configured"
        case .needsRepair: "Needs repair"
        case .unavailable: "Unavailable"
        }
    }
}

private extension HarnessSetupAction {
    var label: String {
        switch self {
        case .install: "Install"
        case .repair: "Repair"
        case .remove: "Remove"
        }
    }
}
