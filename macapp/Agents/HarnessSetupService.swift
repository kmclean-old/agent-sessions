import CryptoKit
import Darwin
import Foundation
import Yams

enum HarnessKind: String, CaseIterable, Codable, Identifiable {
    case claude, codex, omp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .omp: return "OMP"
        }
    }
}

struct HarnessHome: Identifiable, Codable, Equatable {
    let harness: HarnessKind
    let directory: URL
    var id: String { harness.rawValue + ":" + directory.resolvingSymlinksInPath().standardizedFileURL.path }

    init(harness: HarnessKind, directory: URL) {
        self.harness = harness
        self.directory = directory.standardizedFileURL
    }
}

enum HarnessSetupAction: String { case install, repair, remove }
enum HarnessConfigurationStatus { case notInstalled, configured, needsRepair, unavailable }

struct HarnessSetupInspection {
    let home: HarnessHome
    let status: HarnessConfigurationStatus
    let detail: String
}

struct HarnessSetupFileChange {
    let path: String
    let before: String?
    let after: String?
}

struct HarnessSetupPlan: Identifiable {
    let id = UUID()
    let home: HarnessHome
    let action: HarnessSetupAction
    let changes: [HarnessSetupFileChange]
    let notes: [String]
    fileprivate let root: URL
    fileprivate let homeIdentity: SetupDirectoryIdentity
    fileprivate let guards: [SetupFileSnapshot]
    fileprivate let extensionDirectories: [URL: [String]]
    fileprivate let writes: [SetupWrite]
}

struct HarnessSetupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// File preparation is read-only. Applying a plan checks its snapshots under
/// a shared lock, saves recovery copies, and writes the ownership record last.
final class HarnessSetupService {
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Agents/integrations", isDirectory: true)
    }

    private let root: URL
    private let emitters: [String: Data]
    private let beforeWrite: ((URL) throws -> Void)?
    private let userHome: URL
    private let environment: [String: String]
    private let fm = FileManager.default
    private var registryURL: URL { root.appendingPathComponent("registry.json") }

    init(root: URL = HarnessSetupService.defaultRoot,
         emitters: [String: Data]? = nil,
         beforeWrite: ((URL) throws -> Void)? = nil,
         userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.root = root.standardizedFileURL
        self.emitters = emitters ?? Self.bundledEmitters()
        self.beforeWrite = beforeWrite
        self.userHome = userHome
        self.environment = environment
    }

    static func bundledEmitters() -> [String: Data] {
        var files: [String: Data] = [:]
        for name in ["agents-status.sh", "agents-omp.ts"] {
            if let url = Bundle.main.url(forResource: name, withExtension: nil),
               let data = try? Data(contentsOf: url) { files[name] = data }
        }
        return files
    }

    func discoverHomes() throws -> [HarnessHome] {
        try discoverHomes(userHome: userHome, environment: environment)
    }

    func discoverHomes(userHome: URL, environment: [String: String]) throws -> [HarnessHome] {
        var homes = try readRegistry().records.map(\.home)
        func add(_ harness: HarnessKind, _ directory: URL) {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
            let home = HarnessHome(harness: harness, directory: directory)
            if !homes.contains(where: { $0.id == home.id }) { homes.append(home) }
        }
        for (kind, name, variable) in [(HarnessKind.claude, ".claude", "CLAUDE_CONFIG_DIR"),
                                       (.codex, ".codex", "CODEX_HOME")] {
            add(kind, userHome.appendingPathComponent(name))
            if let path = environment[variable], path.hasPrefix("/") { add(kind, URL(fileURLWithPath: path)) }
            for child in (try? fm.contentsOfDirectory(at: userHome, includingPropertiesForKeys: nil)) ?? []
                where child.lastPathComponent.hasPrefix(name + "-") {
                let config = kind == .claude ? "settings.json" : "hooks.json"
                if fm.fileExists(atPath: child.appendingPathComponent(config).path)
                    || (kind == .codex && fm.fileExists(atPath: child.appendingPathComponent("config.toml").path)) {
                    add(kind, child)
                }
            }
        }
        add(.omp, userHome.appendingPathComponent(".omp/agent"))
        if let path = environment["PI_CODING_AGENT_DIR"], path.hasPrefix("/") {
            add(.omp, URL(fileURLWithPath: path))
        }
        let profileRoot = userHome.appendingPathComponent(".omp/profiles")
        for profile in (try? fm.contentsOfDirectory(at: profileRoot, includingPropertiesForKeys: nil)) ?? [] {
            add(.omp, profile.appendingPathComponent("agent"))
        }
        return homes.sorted { $0.id < $1.id }
    }

    func inspect(_ home: HarnessHome) -> HarnessSetupInspection {
        do {
            _ = try SetupDirectoryIdentity(home.directory)
            let receipt = try readRegistry().records.first { $0.home.id == home.id }
            let plan = try prepare(home, action: receipt == nil ? .install : .repair)
            return HarnessSetupInspection(
                home: home,
                status: receipt == nil ? .notInstalled : (plan.writes.isEmpty ? .configured : .needsRepair),
                detail: receipt == nil ? "Ready to install." :
                    (plan.writes.isEmpty ? "Integration files and entries are installed." : "Integration files or entries need repair.")
            )
        } catch {
            return HarnessSetupInspection(home: home, status: .unavailable, detail: error.localizedDescription)
        }
    }

    func prepare(_ home: HarnessHome, action: HarnessSetupAction) throws -> HarnessSetupPlan {
        let identity = try SetupDirectoryIdentity(home.directory)
        let registrySnapshot = try SetupFileSnapshot(registryURL)
        var registry = try decodeRegistry(registrySnapshot.data)
        let oldReceipt = registry.records.first { $0.home.id == home.id }
        var snapshots = [registrySnapshot]
        var extensionDirectories: [URL: [String]] = [:]
        var writes: [SetupWrite] = []
        var notes: [String] = []
        if home.harness == .codex && action != .remove {
            notes.append("After applying, start Codex and review the commands with /hooks. Agents does not approve hook trust or change Codex feature settings.")
        }
        if action != .remove {
            notes.append("Start a fresh harness in a new Agents pane to check reporting. Harness options or policies can disable hooks and extensions.")
        }
        if action == .repair && oldReceipt == nil {
            throw HarnessSetupError(message: "This configuration home has no Agents installation record. Use Install first.")
        }
        if action == .remove && oldReceipt == nil {
            throw HarnessSetupError(message: "There is no recorded Agents installation to remove.")
        }

        let emitterName = home.harness == .omp ? "agents-omp.ts" : "agents-status.sh"
        let emitter: Data
        if action == .remove { emitter = Data() }
        else {
            guard let bundled = emitters[emitterName], !bundled.isEmpty else {
                throw HarnessSetupError(message: "The app is missing its bundled \(emitterName) emitter. Reinstall the app.")
            }
            emitter = bundled
        }
        let digest = SHA256.hash(data: emitter).map { String(format: "%02x", $0) }.joined()
        let emitterURL = root.appendingPathComponent("emitters/\(digest)/\(emitterName)")
        if action != .remove {
            let snapshot = try SetupFileSnapshot(emitterURL)
            snapshots.append(snapshot)
            if snapshot.data != emitter { writes.append(SetupWrite(snapshot: snapshot, data: emitter)) }
        }

        let configURL = configurationURL(for: home)
        let configSnapshot = try SetupFileSnapshot(configURL)
        snapshots.append(configSnapshot)
        for other in registry.records where other.home.id != home.id {
            let otherConfig = try SetupFileSnapshot(configurationURL(for: other.home))
            snapshots.append(otherConfig)
            guard otherConfig.resolved.path != configSnapshot.resolved.path else {
                throw HarnessSetupError(message: "This configuration file is shared with \(other.home.directory.path). Manage the integration through that home.")
            }
        }
        var receipt = SetupReceipt(home: home, emitterPath: emitterURL.path,
                                   entries: [:], loader: nil,
                                   createdConfig: oldReceipt?.createdConfig ?? (configSnapshot.data == nil))
        let configAfter: Data?
        if home.harness == .omp {
            if action != .remove {
                try checkOMPManualSetup(home, excluding: configURL, snapshots: &snapshots,
                                        directories: &extensionDirectories)
                let quotedPath = String(decoding: try JSONEncoder().encode(emitterURL.path), as: UTF8.self)
                receipt.loader = Data("// Installed by Agents. Manage this integration in Agents Settings.\nexport { default } from \(quotedPath);\n".utf8)
            }
            if let existing = configSnapshot.data, existing != oldReceipt?.loader, existing != receipt.loader {
                throw HarnessSetupError(message: "\(configURL.path) contains unrecognized or edited content. Move it aside or restore it before changing this integration.")
            }
            configAfter = action == .remove ? nil : receipt.loader
        } else {
            let result = try HarnessHookConfiguration.prepare(
                data: configSnapshot.data, harness: home.harness,
                command: "/bin/bash " + Self.shellQuote(emitterURL.path),
                previous: oldReceipt?.entries ?? [:], remove: action == .remove,
                managedEmitterPaths: [root.appendingPathComponent("emitters").path] +
                    [oldReceipt?.emitterPath].compactMap { $0 }
            )
            receipt.entries = result.entries
            notes += result.notes
            configAfter = action == .remove && (configSnapshot.data == nil ||
                (oldReceipt?.createdConfig == true && result.isEmpty)) ? nil : result.data
        }
        if configSnapshot.data != configAfter { writes.append(SetupWrite(snapshot: configSnapshot, data: configAfter)) }
        registry.records.removeAll { $0.home.id == home.id }
        if action != .remove { registry.records.append(receipt) }
        registry.records.sort { $0.home.id < $1.home.id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let registryAfter = try encoder.encode(registry)
        if registrySnapshot.data != registryAfter {
            writes.append(SetupWrite(snapshot: registrySnapshot, data: registryAfter))
        }
        // Old content-addressed emitters stay available for running harnesses
        // and other app builds. Removal only detaches the selected home.
        notes.append("Shared emitter versions are retained so other homes and running harnesses can continue using them.")
        let changes = writes.map {
            HarnessSetupFileChange(path: $0.snapshot.url.path,
                                   before: $0.snapshot.data.map { String(decoding: $0, as: UTF8.self) },
                                   after: $0.data.map { String(decoding: $0, as: UTF8.self) })
        }
        return HarnessSetupPlan(home: home, action: action, changes: changes, notes: notes,
                                root: root, homeIdentity: identity, guards: snapshots,
                                extensionDirectories: extensionDirectories, writes: writes)
    }

    func apply(_ plan: HarnessSetupPlan) throws {
        guard plan.root == root else { throw HarnessSetupError(message: "This plan belongs to a different integration directory.") }
        guard try SetupDirectoryIdentity(plan.home.directory) == plan.homeIdentity else {
            throw HarnessSetupError(message: "The configuration home changed. Refresh and prepare the action again.")
        }
        if plan.writes.isEmpty { return }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(root.appendingPathComponent("setup.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw HarnessSetupError(message: "Cannot open the integration setup lock.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw HarnessSetupError(message: "Another Agents app is changing integrations. Try again when it finishes.")
        }
        defer { flock(lock, LOCK_UN) }
        for snapshot in plan.guards { try snapshot.validate() }
        for (directory, names) in plan.extensionDirectories {
            guard try directoryNames(directory) == names else {
                throw HarnessSetupError(message: "The extensions in \(directory.path) changed after the preview. Refresh and prepare the action again.")
            }
        }
        let recovery = root.appendingPathComponent("recovery/\(plan.id.uuidString)", isDirectory: true)
        try fm.createDirectory(at: recovery, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var backupIndex: [[String: String]] = []
        for (index, write) in plan.writes.enumerated() {
            let name = "\(index).before"
            if let data = write.snapshot.data {
                try data.write(to: recovery.appendingPathComponent(name), options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recovery.appendingPathComponent(name).path)
            }
            backupIndex.append(["path": write.snapshot.url.path, "target": write.snapshot.resolved.path,
                                "backup": write.snapshot.data == nil ? "absent" : name])
        }
        try JSONSerialization.data(withJSONObject: backupIndex, options: [.prettyPrinted, .sortedKeys])
            .write(to: recovery.appendingPathComponent("index.json"), options: .atomic)
        var completed: [SetupWrite] = []
        do {
            for write in plan.writes {
                try beforeWrite?(write.snapshot.url)
                guard try SetupDirectoryIdentity(plan.home.directory) == plan.homeIdentity else {
                    throw HarnessSetupError(message: "The configuration home changed during installation.")
                }
                try write.snapshot.validate()
                completed.append(write)
                try write.put(write.data)
            }
        } catch {
            var unrestored: [String] = []
            for write in completed.reversed() {
                do {
                    if write.snapshot.url.path.hasPrefix(root.appendingPathComponent("emitters").path + "/"),
                       !unrestored.isEmpty { continue }
                    if write.snapshot.url == configurationURL(for: plan.home),
                       (try? SetupDirectoryIdentity(plan.home.directory)) != plan.homeIdentity {
                        unrestored.append(write.snapshot.url.path)
                        continue
                    }
                    let current = try SetupFileSnapshot(write.snapshot.url)
                    if current.resolved == write.snapshot.resolved, current.data == write.snapshot.data { continue }
                    guard current.resolved == write.snapshot.resolved, current.data == write.data else {
                        unrestored.append(write.snapshot.url.path)
                        continue
                    }
                    try write.put(write.snapshot.data)
                } catch { unrestored.append(write.snapshot.url.path) }
            }
            let restoration = unrestored.isEmpty ? "Completed writes were rolled back." :
                "Could not restore: " + unrestored.joined(separator: ", ") + "."
            throw HarnessSetupError(message: "\(error.localizedDescription) \(restoration) Recovery copies: \(recovery.path)")
        }
        try? fm.removeItem(at: recovery)
    }

    private func readRegistry() throws -> SetupRegistry {
        try decodeRegistry(SetupFileSnapshot(registryURL).data)
    }

    private func configurationURL(for home: HarnessHome) -> URL {
        home.directory.appendingPathComponent(home.harness == .claude ? "settings.json" :
            home.harness == .codex ? "hooks.json" : "extensions/agents-integration.ts")
    }

    private func decodeRegistry(_ data: Data?) throws -> SetupRegistry {
        guard let data else { return SetupRegistry() }
        let value = try JSONDecoder().decode(SetupRegistry.self, from: data)
        guard value.version == 1 else {
            throw HarnessSetupError(message: "This installation record was written by an unsupported version of Agents.")
        }
        return value
    }

    private func checkOMPManualSetup(_ home: HarnessHome, excluding configURL: URL,
                                     snapshots: inout [SetupFileSnapshot],
                                     directories: inout [URL: [String]]) throws {
        let extensions = home.directory.appendingPathComponent("extensions")
        var candidates = try ompDirectoryEntries(extensions, excluding: configURL.lastPathComponent,
                                                 snapshots: &snapshots, directories: &directories)
        var readYAML = false
        for name in ["config.yml", "config.yaml", "settings.json"] {
            let snapshot = try SetupFileSnapshot(home.directory.appendingPathComponent(name))
            snapshots.append(snapshot)
            guard let data = snapshot.data else { continue }
            let object: Any?
            if name == "settings.json" { object = try JSONSerialization.jsonObject(with: data) }
            else {
                if readYAML { continue }
                object = try Yams.load(yaml: String(decoding: data, as: UTF8.self))
                readYAML = object is [String: Any]
            }
            guard let settings = object as? [String: Any], let value = settings["extensions"] else { continue }
            guard let values = value as? [Any] else {
                throw HarnessSetupError(message: "Unrecognized extensions setting in \(name). Expected an array of extension paths.")
            }
            for declaredPath in values.compactMap({ $0 as? String }) {
                let path = declaredPath.hasPrefix("@") ? String(declaredPath.dropFirst()) : declaredPath
                if path.contains("agents-omp") || path.contains("agents-integration") {
                    throw HarnessSetupError(message: "\(name) references a manual Agents extension. Remove that registration before installing to avoid duplicate reports.")
                }
                let entry: URL
                if path.hasPrefix("~/") { entry = userHome.appendingPathComponent(String(path.dropFirst(2))) }
                else if path.hasPrefix("/") { entry = URL(fileURLWithPath: path) }
                else if let url = URL(string: path), url.isFileURL { entry = url }
                else {
                    throw HarnessSetupError(message: "\(name) uses a relative extension path: \(path). Use an absolute path before setup so Agents can check for an existing integration across projects.")
                }
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    let declared = try ompPackageEntries(entry, fallbackForMissing: true,
                                                         snapshots: &snapshots, directories: &directories)
                    if declared.isEmpty {
                        candidates += try ompDirectoryEntries(entry, excluding: nil,
                                                               snapshots: &snapshots, directories: &directories)
                    } else { candidates += declared }
                } else { candidates.append(entry) }
            }
        }
        for file in candidates {
            let snapshot = try SetupFileSnapshot(file)
            snapshots.append(snapshot)
            guard let data = snapshot.data else { continue }
            let text = String(decoding: data, as: UTF8.self)
            if file.lastPathComponent == "agents-omp.ts" || text.contains("agents-omp.ts")
                || (text.contains("AGENTS_PANE_GENERATION") && text.contains("harness-event")) {
                throw HarnessSetupError(message: "An existing Agents extension was found at \(file.path). Remove its manual registration before installing to avoid duplicate reports.")
            }
        }
    }

    private func ompDirectoryEntries(_ directory: URL, excluding: String?,
                                     snapshots: inout [SetupFileSnapshot],
                                     directories: inout [URL: [String]]) throws -> [URL] {
        let names = try directoryNames(directory)
        directories[directory] = names
        var entries: [URL] = []
        for name in names where name != excluding {
            let file = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: file.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                entries += try ompPackageEntries(file, fallbackForMissing: false,
                                                  snapshots: &snapshots, directories: &directories)
            } else if ["ts", "js"].contains(file.pathExtension) { entries.append(file) }
        }
        return entries
    }

    private func ompPackageEntries(_ directory: URL, fallbackForMissing: Bool,
                                   snapshots: inout [SetupFileSnapshot],
                                   directories: inout [URL: [String]]) throws -> [URL] {
        directories[directory] = try directoryNames(directory)
        let package = try SetupFileSnapshot(directory.appendingPathComponent("package.json"))
        snapshots.append(package)
        if let data = package.data,
           let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let manifest = (object["omp"] ?? object["pi"]) as? [String: Any],
           let values = manifest["extensions"] as? [Any] {
            let paths = values.compactMap { $0 as? String }
            if !paths.isEmpty {
                var entries: [URL] = []
                for path in paths {
                    let entry = URL(fileURLWithPath: path, relativeTo: directory.appendingPathComponent("", isDirectory: true)).absoluteURL
                    var isDirectory: ObjCBool = false
                    if fm.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue {
                        directories[entry] = try directoryNames(entry)
                        if let index = try ompIndex(entry, snapshots: &snapshots) { entries.append(index) }
                    } else {
                        let snapshot = try SetupFileSnapshot(entry)
                        snapshots.append(snapshot)
                        if snapshot.data != nil { entries.append(entry) }
                    }
                }
                if !entries.isEmpty || !fallbackForMissing { return entries }
            }
        }
        return try ompIndex(directory, snapshots: &snapshots).map { [$0] } ?? []
    }

    private func ompIndex(_ directory: URL, snapshots: inout [SetupFileSnapshot]) throws -> URL? {
        for name in ["index.ts", "index.js"] {
            let snapshot = try SetupFileSnapshot(directory.appendingPathComponent(name))
            snapshots.append(snapshot)
            if snapshot.data != nil { return snapshot.url }
        }
        return nil
    }

    private func directoryNames(_ directory: URL) throws -> [String] {
        do { return try fm.contentsOfDirectory(atPath: directory.path).sorted() }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}

private struct SetupRegistry: Codable {
    var version = 1
    var records: [SetupReceipt] = []
}

private struct SetupReceipt: Codable {
    let home: HarnessHome
    let emitterPath: String
    var entries: [String: Data]
    var loader: Data?
    let createdConfig: Bool
}

fileprivate struct SetupDirectoryIdentity: Equatable {
    let resolved: URL
    let inode: UInt64
    init(_ url: URL) throws {
        resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw HarnessSetupError(message: "The selected configuration home is not a directory: \(url.path)")
        }
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

fileprivate struct SetupFileSnapshot {
    let url: URL
    let resolved: URL
    let data: Data?
    let permissions: NSNumber?

    init(_ url: URL) throws {
        self.url = url
        resolved = url.resolvingSymlinksInPath().standardizedFileURL
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw HarnessSetupError(message: "Expected a regular configuration file at \(url.path).")
            }
            data = try Data(contentsOf: resolved)
            permissions = attributes[.posixPermissions] as? NSNumber
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            data = nil
            permissions = nil
        }
    }

    func validate() throws {
        let current = try SetupFileSnapshot(url)
        guard current.resolved == resolved, current.data == data, current.permissions == permissions else {
            throw HarnessSetupError(message: "\(url.path) changed after the preview. Refresh and prepare the action again.")
        }
    }
}

fileprivate struct SetupWrite {
    let snapshot: SetupFileSnapshot
    let data: Data?

    func put(_ value: Data?) throws {
        let fm = FileManager.default
        if let value {
            try fm.createDirectory(at: snapshot.resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try value.write(to: snapshot.resolved, options: .atomic)
            try fm.setAttributes([.posixPermissions: snapshot.permissions ?? NSNumber(value: 0o600)],
                                 ofItemAtPath: snapshot.resolved.path)
        } else if fm.fileExists(atPath: snapshot.resolved.path) {
            try fm.removeItem(at: snapshot.resolved)
        }
    }
}
