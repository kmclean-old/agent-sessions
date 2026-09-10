import Foundation
import XCTest
@testable import Agents

final class HarnessSetupServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    private let emitters = [
        "agents-status.sh": Data("#!/bin/sh\nprintf '%s' \"$0\"\n".utf8),
        "agents-omp.ts": Data("export default function () {}\n".utf8)
    ]

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    private func fixture(_ harness: HarnessKind = .claude) throws -> (URL, HarnessHome, HarnessSetupService) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let homeURL = directory.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let root = directory.appendingPathComponent("Application Support/O'Brien $(no-command)", isDirectory: true)
        return (root, HarnessHome(harness: harness, directory: homeURL),
                HarnessSetupService(root: root, emitters: emitters))
    }

    private func config(_ home: HarnessHome) -> URL {
        home.directory.appendingPathComponent(home.harness == .codex ? "hooks.json" : "settings.json")
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    private func groups(_ object: [String: Any], event: String) -> [[String: Any]] {
        (object["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }

    private func commands(_ object: [String: Any], event: String) -> [String] {
        groups(object, event: event).flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    private func allCommands(_ object: [String: Any]) -> [String] {
        (object["hooks"] as? [String: Any] ?? [:]).keys.sorted().flatMap { commands(object, event: $0) }
    }

    private func emitterURL(_ plan: HarnessSetupPlan, name: String = "agents-status.sh") throws -> URL {
        URL(fileURLWithPath: try XCTUnwrap(plan.changes.first { $0.path.hasSuffix("/\(name)") }?.path))
    }

    func testInspectionAndPreparationDoNotWriteFiles() throws {
        let (root, home, service) = try fixture()
        let original = Data("{\"theme\":\"dark\"}\n".utf8)
        try original.write(to: config(home))
        XCTAssertEqual(service.inspect(home).status, .notInstalled)
        let plan = try service.prepare(home, action: .install)
        XCTAssertFalse(plan.changes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: config(home)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRepeatedInstallPreservesSettingsAndDoesNotDuplicateHooks() throws {
        for harness in [HarnessKind.claude, .codex] {
            let (_, home, service) = try fixture(harness)
            let originalGroup: [String: Any] = [
                "matcher": "Read", "description": "User hook",
                "hooks": [["type": "command", "command": "printf user", "timeout": 7]]
            ]
            try writeJSON(["theme": "dark", "hooks": ["PreToolUse": [originalGroup]]], to: config(home))
            try service.apply(service.prepare(home, action: .install))
            let first = try readJSON(config(home))
            try service.apply(service.prepare(home, action: .install))
            let second = try readJSON(config(home))
            XCTAssertEqual(first as NSDictionary, second as NSDictionary)
            XCTAssertEqual(second["theme"] as? String, "dark")
            XCTAssertEqual(groups(second, event: "PreToolUse").first as NSDictionary?, originalGroup as NSDictionary)
            let installed = groups(second, event: "PreToolUse").filter {
                ($0["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String)?.contains("agents-status.sh") == true
                }
            }
            XCTAssertEqual(installed.count, 1)
            let matcher = installed.first?["matcher"] as? String
            XCTAssertTrue(matcher == nil || matcher == "*")
            XCTAssertEqual(commands(second, event: "SessionStart").count, 1)
            XCTAssertEqual(service.inspect(home).status, .configured)
        }
    }

    func testInstallWritesThroughConfigurationSymlink() throws {
        let (_, home, service) = try fixture()
        let target = home.directory.deletingLastPathComponent().appendingPathComponent("dotfiles-settings.json")
        try writeJSON(["theme": "dark"], to: target)
        try FileManager.default.createSymbolicLink(atPath: config(home).path, withDestinationPath: "../dotfiles-settings.json")
        try service.apply(service.prepare(home, action: .install))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: config(home).path), "../dotfiles-settings.json")
        XCTAssertEqual(try readJSON(target)["theme"] as? String, "dark")
        XCTAssertEqual(commands(try readJSON(target), event: "SessionStart").count, 1)
    }

    func testRetargetedConfigurationSymlinkRejectsPreparedPlan() throws {
        let (_, home, service) = try fixture()
        let originalTarget = home.directory.appendingPathComponent("first.json")
        let replacementTarget = home.directory.appendingPathComponent("second.json")
        let original = Data("{\"theme\":\"dark\"}\n".utf8)
        try original.write(to: originalTarget)
        try original.write(to: replacementTarget)
        try FileManager.default.createSymbolicLink(atPath: config(home).path, withDestinationPath: "first.json")
        let plan = try service.prepare(home, action: .install)
        try FileManager.default.removeItem(at: config(home))
        try FileManager.default.createSymbolicLink(atPath: config(home).path, withDestinationPath: "second.json")
        XCTAssertThrowsError(try service.apply(plan))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: config(home).path), "second.json")
        XCTAssertEqual(try Data(contentsOf: originalTarget), original)
        XCTAssertEqual(try Data(contentsOf: replacementTarget), original)
    }

    func testInstalledCommandRunsWithSpacesApostrophesAndShellSyntaxInItsPath() throws {
        let (_, home, service) = try fixture()
        let plan = try service.prepare(home, action: .install)
        let emitter = try emitterURL(plan)
        try service.apply(plan)
        let command = try XCTUnwrap(commands(try readJSON(config(home)), event: "SessionStart").first)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), emitter.path)
    }

    func testMissingHomeIsNotRecreatedAfterPreparation() throws {
        let (root, home, service) = try fixture()
        let plan = try service.prepare(home, action: .install)
        try FileManager.default.removeItem(at: home.directory)
        XCTAssertThrowsError(try service.apply(plan))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(service.inspect(home).status, .unavailable)
        XCTAssertThrowsError(try service.prepare(home, action: .repair))
    }

    func testInterveningConfigurationEditRejectsPreparedPlan() throws {
        let (_, home, service) = try fixture()
        try writeJSON(["theme": "dark"], to: config(home))
        let plan = try service.prepare(home, action: .install)
        let emitter = try emitterURL(plan)
        let edited = Data("{\"theme\":\"light\"}\n".utf8)
        try edited.write(to: config(home))
        XCTAssertThrowsError(try service.apply(plan))
        XCTAssertEqual(try Data(contentsOf: config(home)), edited)
        XCTAssertFalse(FileManager.default.fileExists(atPath: emitter.path))
    }

    func testAnotherHomesInstallationInvalidatesPreparedRegistryUpdate() throws {
        let (root, first, service) = try fixture()
        let directory = first.directory.deletingLastPathComponent().appendingPathComponent("second-profile")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let second = HarnessHome(harness: .claude, directory: directory)
        let pending = try service.prepare(first, action: .install)
        let otherApp = HarnessSetupService(root: root, emitters: emitters)
        try otherApp.apply(otherApp.prepare(second, action: .install))
        XCTAssertThrowsError(try service.apply(pending))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config(first).path))
        XCTAssertEqual(otherApp.inspect(second).status, .configured)
    }

    func testRepairRestoresMissingEntriesAndEmitter() throws {
        let (_, home, service) = try fixture()
        let install = try service.prepare(home, action: .install)
        let emitter = try emitterURL(install)
        try service.apply(install)
        var object = try readJSON(config(home))
        var hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        hooks.removeValue(forKey: "SessionStart")
        object["hooks"] = hooks
        object["theme"] = "light"
        try writeJSON(object, to: config(home))
        try FileManager.default.removeItem(at: emitter)
        XCTAssertEqual(service.inspect(home).status, .needsRepair)
        try service.apply(service.prepare(home, action: .repair))
        let repaired = try readJSON(config(home))
        XCTAssertEqual(repaired["theme"] as? String, "light")
        XCTAssertEqual(commands(repaired, event: "SessionStart").count, 1)
        XCTAssertEqual(try Data(contentsOf: emitter), emitters["agents-status.sh"])
        XCTAssertEqual(service.inspect(home).status, .configured)
    }

    func testRemovePreservesUserModifiedHookAndUnrelatedEntries() throws {
        let (_, home, service) = try fixture()
        try writeJSON(["theme": "dark", "hooks": ["CustomEvent": [
            ["matcher": "custom", "hooks": [["type": "command", "command": "printf custom"]]]
        ]]], to: config(home))
        try service.apply(service.prepare(home, action: .install))
        var object = try readJSON(config(home))
        var hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        var startGroups = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        var startHooks = try XCTUnwrap(startGroups[0]["hooks"] as? [[String: Any]])
        let editedCommand = try XCTUnwrap(startHooks[0]["command"] as? String) + " # user override"
        startHooks[0]["command"] = editedCommand
        startGroups[0]["hooks"] = startHooks
        hooks["SessionStart"] = startGroups
        object["hooks"] = hooks
        try writeJSON(object, to: config(home))
        try service.apply(service.prepare(home, action: .remove))
        let removed = try readJSON(config(home))
        XCTAssertEqual(removed["theme"] as? String, "dark")
        XCTAssertEqual(allCommands(removed).sorted(), [editedCommand, "printf custom"].sorted())
    }

    func testRepairRefusesEditedOwnedCommandWithApostropheInEmitterPath() throws {
        let (root, home, service) = try fixture()
        XCTAssertTrue(root.path.contains("'"))
        try service.apply(service.prepare(home, action: .install))
        var object = try readJSON(config(home))
        var hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        var startGroups = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        var startHooks = try XCTUnwrap(startGroups[0]["hooks"] as? [[String: Any]])
        startHooks[0]["command"] = try XCTUnwrap(startHooks[0]["command"] as? String) + " # user customization"
        startGroups[0]["hooks"] = startHooks
        hooks["SessionStart"] = startGroups
        object["hooks"] = hooks
        try writeJSON(object, to: config(home))
        let edited = try Data(contentsOf: config(home))
        XCTAssertThrowsError(try service.prepare(home, action: .repair))
        XCTAssertEqual(try Data(contentsOf: config(home)), edited)
        XCTAssertEqual(commands(try readJSON(config(home)), event: "SessionStart").count, 1)
    }

    func testMultipleHomesShareEmittersAndRemovingOnePreservesTheOther() throws {
        let (root, first, service) = try fixture()
        let firstPlan = try service.prepare(first, action: .install)
        let emitter = try emitterURL(firstPlan)
        try service.apply(firstPlan)
        let directory = first.directory.deletingLastPathComponent().appendingPathComponent("work-profile")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let second = HarnessHome(harness: .claude, directory: directory)
        let anotherAppBuild = HarnessSetupService(root: root, emitters: emitters)
        try anotherAppBuild.apply(anotherAppBuild.prepare(second, action: .install))
        XCTAssertEqual(commands(try readJSON(config(first)), event: "SessionStart"),
                       commands(try readJSON(config(second)), event: "SessionStart"))
        try service.apply(service.prepare(first, action: .remove))
        XCTAssertTrue(FileManager.default.fileExists(atPath: emitter.path))
        XCTAssertEqual(anotherAppBuild.inspect(second).status, .configured)
    }

    func testEmitterUpgradeKeepsOtherHomesVersionWorking() throws {
        let (root, first, service) = try fixture()
        let firstPlan = try service.prepare(first, action: .install)
        let oldEmitter = try emitterURL(firstPlan)
        try service.apply(firstPlan)
        let directory = first.directory.deletingLastPathComponent().appendingPathComponent("older-profile")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let second = HarnessHome(harness: .claude, directory: directory)
        try service.apply(service.prepare(second, action: .install))
        var changedEmitters = emitters
        changedEmitters["agents-status.sh"] = Data("#!/bin/sh\nprintf updated\n".utf8)
        let newerApp = HarnessSetupService(root: root, emitters: changedEmitters)
        let upgrade = try newerApp.prepare(first, action: .repair)
        let newEmitter = try emitterURL(upgrade)
        XCTAssertNotEqual(newEmitter, oldEmitter)
        try newerApp.apply(upgrade)
        XCTAssertEqual(try Data(contentsOf: oldEmitter), emitters["agents-status.sh"])
        XCTAssertEqual(try Data(contentsOf: newEmitter), changedEmitters["agents-status.sh"])
        XCTAssertEqual(service.inspect(second).status, .configured)
        XCTAssertEqual(newerApp.inspect(first).status, .configured)
        XCTAssertNotEqual(commands(try readJSON(config(first)), event: "SessionStart"),
                          commands(try readJSON(config(second)), event: "SessionStart"))
    }

    func testManualHookMigrationRemovesOnlyRecognizedEmitterCommands() throws {
        let (_, home, service) = try fixture()
        let legacy = "bash '/tmp/example checkout/hooks/agents-status.sh'"
        let unrelated = "printf '/tmp/example checkout/hooks/agents-status.sh'"
        try writeJSON(["hooks": ["SessionStart": [["hooks": [
            ["type": "command", "command": legacy],
            ["type": "command", "command": legacy],
            ["type": "command", "command": unrelated]
        ]]]]], to: config(home))
        try service.apply(service.prepare(home, action: .install))
        let installed = commands(try readJSON(config(home)), event: "SessionStart")
        XCTAssertFalse(installed.contains(legacy))
        XCTAssertTrue(installed.contains(unrelated))
        XCTAssertEqual(installed.count, 2)
    }

    func testMalformedConfigurationIsReportedWithoutReplacingIt() throws {
        let (root, home, service) = try fixture()
        let malformed = Data("{\"hooks\": [unterminated".utf8)
        try malformed.write(to: config(home))
        XCTAssertEqual(service.inspect(home).status, .unavailable)
        XCTAssertThrowsError(try service.prepare(home, action: .install))
        XCTAssertEqual(try Data(contentsOf: config(home)), malformed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRemovalPreservesAnExistingEmptyConfigurationFile() throws {
        for harness in [HarnessKind.claude, .codex] {
            let (_, home, service) = try fixture(harness)
            try writeJSON([:], to: config(home))
            try service.apply(service.prepare(home, action: .install))
            try service.apply(service.prepare(home, action: .remove))
            XCTAssertTrue(FileManager.default.fileExists(atPath: config(home).path))
            XCTAssertTrue(try readJSON(config(home)).isEmpty)
        }
    }

    func testRemovalDoesNotRecreateADeletedConfigurationFile() throws {
        let (_, home, service) = try fixture()
        try writeJSON(["theme": "dark"], to: config(home))
        try service.apply(service.prepare(home, action: .install))
        try FileManager.default.removeItem(at: config(home))
        try service.apply(service.prepare(home, action: .remove))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config(home).path))
        XCTAssertEqual(service.inspect(home).status, .notInstalled)
    }

    func testTwoHomesCannotInstallIntoTheSameSymlinkTarget() throws {
        let (_, first, service) = try fixture()
        let parent = first.directory.deletingLastPathComponent()
        let target = parent.appendingPathComponent("shared-settings.json")
        try writeJSON(["theme": "dark"], to: target)
        try FileManager.default.createSymbolicLink(atPath: config(first).path, withDestinationPath: target.path)
        try service.apply(service.prepare(first, action: .install))
        let installed = try Data(contentsOf: target)
        let secondDirectory = parent.appendingPathComponent("alias-profile")
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let second = HarnessHome(harness: .claude, directory: secondDirectory)
        try FileManager.default.createSymbolicLink(atPath: config(second).path, withDestinationPath: target.path)
        XCTAssertThrowsError(try service.prepare(second, action: .install))
        XCTAssertEqual(try Data(contentsOf: target), installed)
        XCTAssertEqual(service.inspect(first).status, .configured)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: config(second).path), target.path)
    }

    func testAppBundleIncludesBothEmitterResources() {
        let bundled = HarnessSetupService.bundledEmitters()
        XCTAssertFalse(bundled["agents-status.sh"]?.isEmpty ?? true)
        XCTAssertFalse(bundled["agents-omp.ts"]?.isEmpty ?? true)
    }

    func testDiscoveryIncludesDefaultsEnvironmentProfilesAndRecordedHomesWithoutDuplicates() throws {
        let (_, selected, service) = try fixture()
        let userHome = selected.directory.deletingLastPathComponent()
        try service.apply(service.prepare(selected, action: .install))
        let paths: [(HarnessKind, String)] = [
            (.claude, ".claude"), (.claude, ".claude-work"),
            (.codex, ".codex"), (.codex, "custom-codex"),
            (.omp, ".omp/agent"), (.omp, ".omp/profiles/work/agent")
        ]
        for (_, path) in paths {
            try FileManager.default.createDirectory(at: userHome.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try writeJSON([:], to: userHome.appendingPathComponent(".claude-work/settings.json"))
        let environment = [
            "CLAUDE_CONFIG_DIR": userHome.appendingPathComponent(".claude").path,
            "CODEX_HOME": userHome.appendingPathComponent("custom-codex").path
        ]
        let homes = try service.discoverHomes(userHome: userHome, environment: environment)
        XCTAssertEqual(Set(homes.map(\.id)).count, homes.count)
        XCTAssertTrue(homes.contains { $0.id == selected.id })
        for (harness, path) in paths {
            let expected = HarnessHome(harness: harness, directory: userHome.appendingPathComponent(path))
            XCTAssertTrue(homes.contains { $0.id == expected.id }, "Missing \(path)")
        }
        try FileManager.default.removeItem(at: selected.directory)
        let afterRemoval = try service.discoverHomes(userHome: userHome, environment: environment)
        XCTAssertTrue(afterRemoval.contains { $0.id == selected.id })
        XCTAssertEqual(service.inspect(selected).status, .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.directory.path))
    }

    func testFailureBeforeRegistryWriteRollsBackConfigAndKeepsRecoveryCopy() throws {
        let (root, home, _) = try fixture()
        let original = Data("{\"theme\":\"dark\"}\n".utf8)
        try original.write(to: config(home))
        var attempted: [URL] = []
        let service = HarnessSetupService(root: root, emitters: emitters, beforeWrite: { url in
            attempted.append(url)
            if url.lastPathComponent == "registry.json" {
                throw NSError(domain: "HarnessSetupTest", code: 1)
            }
        })
        let plan = try service.prepare(home, action: .install)
        let emitter = try emitterURL(plan)
        XCTAssertThrowsError(try service.apply(plan)) { error in
            XCTAssertTrue(error.localizedDescription.contains("rolled back"))
            XCTAssertTrue(error.localizedDescription.contains("Recovery copies"))
        }
        XCTAssertTrue(attempted.contains(config(home)))
        XCTAssertEqual(try Data(contentsOf: config(home)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: emitter.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("registry.json").path))
        XCTAssertEqual(service.inspect(home).status, .notInstalled)
        let recovery = root.appendingPathComponent("recovery")
        let saved = try XCTUnwrap(FileManager.default.enumerator(at: recovery, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
        XCTAssertTrue(saved.contains { (try? Data(contentsOf: $0)) == original })
    }

    func testRollbackDoesNotOverwriteAnEditMadeDuringFailedInstallation() throws {
        let (root, home, _) = try fixture()
        try writeJSON(["theme": "dark"], to: config(home))
        let edited = Data("{\"theme\":\"user edit\"}\n".utf8)
        let service = HarnessSetupService(root: root, emitters: emitters, beforeWrite: { url in
            if url.lastPathComponent == "registry.json" {
                try edited.write(to: self.config(home))
                throw NSError(domain: "HarnessSetupTest", code: 1)
            }
        })
        XCTAssertThrowsError(try service.apply(service.prepare(home, action: .install))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Could not restore"))
        }
        XCTAssertEqual(try Data(contentsOf: config(home)), edited)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("registry.json").path))
    }

    func testRollbackRetainsEmitterWhenAnInterveningEditKeepsItsHooks() throws {
        let (root, home, _) = try fixture()
        try writeJSON(["theme": "dark"], to: config(home))
        let service = HarnessSetupService(root: root, emitters: emitters, beforeWrite: { url in
            if url.lastPathComponent == "registry.json" {
                var edited = try self.readJSON(self.config(home))
                edited["theme"] = "user edit"
                try self.writeJSON(edited, to: self.config(home))
                throw NSError(domain: "HarnessSetupTest", code: 1)
            }
        })
        let plan = try service.prepare(home, action: .install)
        let emitter = try emitterURL(plan)
        XCTAssertThrowsError(try service.apply(plan))
        let preserved = try readJSON(config(home))
        XCTAssertEqual(preserved["theme"] as? String, "user edit")
        XCTAssertEqual(commands(preserved, event: "SessionStart").count, 1)
        XCTAssertEqual(try Data(contentsOf: emitter), emitters["agents-status.sh"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("registry.json").path))
    }

    func testFailedRemovalDoesNotRecreateAHomeDeletedDuringApply() throws {
        let (root, home, installer) = try fixture()
        try installer.apply(installer.prepare(home, action: .install))
        let service = HarnessSetupService(root: root, emitters: emitters, beforeWrite: { url in
            if url.lastPathComponent == "registry.json" {
                try FileManager.default.removeItem(at: home.directory)
            }
        })
        XCTAssertThrowsError(try service.apply(service.prepare(home, action: .remove)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.directory.path))
        XCTAssertEqual(service.inspect(home).status, .unavailable)
    }

    func testOMPInstallRepairAndRemovePreserveProfileConfiguration() throws {
        let (_, home, service) = try fixture(.omp)
        let settings = home.directory.appendingPathComponent("config.yml")
        let original = Data("theme: dark\nextensions:\n  - /tmp/unrelated-extension.ts\n".utf8)
        try original.write(to: settings)
        let loader = home.directory.appendingPathComponent("extensions/agents-integration.ts")
        let plan = try service.prepare(home, action: .install)
        let emitter = try emitterURL(plan, name: "agents-omp.ts")
        XCTAssertFalse(FileManager.default.fileExists(atPath: loader.path))
        try service.apply(plan)
        let installed = try Data(contentsOf: loader)
        let quotedEmitter = String(decoding: try JSONEncoder().encode(emitter.path), as: UTF8.self)
        XCTAssertTrue(String(decoding: installed, as: UTF8.self).contains("export { default } from \(quotedEmitter);"))
        XCTAssertEqual(try Data(contentsOf: settings), original)
        XCTAssertEqual(service.inspect(home).status, .configured)
        try service.apply(service.prepare(home, action: .install))
        XCTAssertEqual(try Data(contentsOf: loader), installed)
        try FileManager.default.removeItem(at: loader)
        XCTAssertEqual(service.inspect(home).status, .needsRepair)
        try service.apply(service.prepare(home, action: .repair))
        XCTAssertEqual(try Data(contentsOf: loader), installed)
        try service.apply(service.prepare(home, action: .remove))
        XCTAssertFalse(FileManager.default.fileExists(atPath: loader.path))
        XCTAssertEqual(try Data(contentsOf: settings), original)
        XCTAssertEqual(service.inspect(home).status, .notInstalled)
    }

    func testOMPRefusesToOverwriteOrRemoveUserEditedLoader() throws {
        let (_, home, service) = try fixture(.omp)
        try service.apply(service.prepare(home, action: .install))
        let loader = home.directory.appendingPathComponent("extensions/agents-integration.ts")
        var edited = try Data(contentsOf: loader)
        edited.append(Data("// User customization\n".utf8))
        try edited.write(to: loader)
        XCTAssertThrowsError(try service.prepare(home, action: .repair))
        XCTAssertThrowsError(try service.prepare(home, action: .remove))
        XCTAssertEqual(try Data(contentsOf: loader), edited)
    }

    func testOMPManualRegistrationRequiresResolutionBeforeInstalling() throws {
        for filename in ["config.yml", "config.yaml"] {
            let (root, home, service) = try fixture(.omp)
            let settings = home.directory.appendingPathComponent(filename)
            let original = Data("extensions:\n  - /tmp/checkout/hooks/agents-omp.ts\n".utf8)
            try original.write(to: settings)
            XCTAssertThrowsError(try service.prepare(home, action: .install))
            XCTAssertEqual(try Data(contentsOf: settings), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testOMPNestedManualExtensionRequiresResolutionBeforeInstalling() throws {
        let (root, home, service) = try fixture(.omp)
        let package = home.directory.appendingPathComponent("extensions/manual-integration")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let entry = package.appendingPathComponent("index.ts")
        let original = Data("export { default } from '/tmp/checkout/hooks/agents-omp.ts';\n".utf8)
        try original.write(to: entry)
        XCTAssertThrowsError(try service.prepare(home, action: .install))
        XCTAssertEqual(try Data(contentsOf: entry), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testOMPManifestDeclaredManualExtensionRequiresResolutionBeforeInstalling() throws {
        let (root, home, service) = try fixture(.omp)
        let package = home.directory.appendingPathComponent("extensions/manual-package")
        let source = package.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = package.appendingPathComponent("package.json")
        try writeJSON(["omp": ["extensions": [42, "src/extension.ts", false] as [Any]]], to: manifest)
        let originalManifest = try Data(contentsOf: manifest)
        let entry = source.appendingPathComponent("extension.ts")
        let original = Data("import integration from '/tmp/checkout/hooks/agents-omp.ts';\nexport default integration;\n".utf8)
        try original.write(to: entry)
        XCTAssertThrowsError(try service.prepare(home, action: .install))
        XCTAssertEqual(try Data(contentsOf: manifest), originalManifest)
        XCTAssertEqual(try Data(contentsOf: entry), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testOMPManualExtensionAddedAfterPreparationRejectsPlan() throws {
        let (_, home, service) = try fixture(.omp)
        let plan = try service.prepare(home, action: .install)
        let emitter = try emitterURL(plan, name: "agents-omp.ts")
        let directory = home.directory.appendingPathComponent("extensions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manual = directory.appendingPathComponent("manual.ts")
        let original = Data("export { default } from '/tmp/checkout/hooks/agents-omp.ts';\n".utf8)
        try original.write(to: manual)
        XCTAssertThrowsError(try service.apply(plan))
        XCTAssertEqual(try Data(contentsOf: manual), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: emitter.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("agents-integration.ts").path))
    }

    func testOMPConfiguredAbsoluteDirectoryDetectsManualEmitter() throws {
        let (root, home, service) = try fixture(.omp)
        let directory = home.directory.deletingLastPathComponent().appendingPathComponent("shared extensions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let emitter = directory.appendingPathComponent("agents-omp.ts")
        let original = Data("export default function () {}\n".utf8)
        try original.write(to: emitter)
        let quoted = String(decoding: try JSONEncoder().encode(directory.path), as: UTF8.self)
        let settings = home.directory.appendingPathComponent("config.yml")
        let yaml = Data("extensions: [\(quoted)]\n".utf8)
        try yaml.write(to: settings)
        XCTAssertThrowsError(try service.prepare(home, action: .install))
        XCTAssertEqual(try Data(contentsOf: settings), yaml)
        XCTAssertEqual(try Data(contentsOf: emitter), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testOMPQuotedYAMLAnchorDetectsRenamedEmitterByContent() throws {
        let (root, home, service) = try fixture(.omp)
        let emitter = home.directory.deletingLastPathComponent().appendingPathComponent("renamed integration.ts")
        let original = Data("const generation = process.env.AGENTS_PANE_GENERATION;\nconst event = 'harness-event';\n".utf8)
        try original.write(to: emitter)
        let quoted = String(decoding: try JSONEncoder().encode(emitter.path), as: UTF8.self)
        let settings = home.directory.appendingPathComponent("config.yaml")
        let yaml = Data("integration: &integration \(quoted)\nextensions: [*integration]\n".utf8)
        try yaml.write(to: settings)
        XCTAssertThrowsError(try service.prepare(home, action: .install))
        XCTAssertEqual(try Data(contentsOf: settings), yaml)
        XCTAssertEqual(try Data(contentsOf: emitter), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testOMPRelativeExtensionPathIsRejectedWithoutWrites() throws {
        let (root, home, service) = try fixture(.omp)
        let settings = home.directory.appendingPathComponent("config.yml")
        let original = Data("theme: dark\nextensions: ['./custom-extension.ts']\n".utf8)
        try original.write(to: settings)
        XCTAssertThrowsError(try service.prepare(home, action: .install)) { error in
            XCTAssertTrue(error.localizedDescription.contains("relative extension path"))
        }
        XCTAssertEqual(try Data(contentsOf: settings), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testOMPUsesActiveTypeScriptIndexBeforeInactiveJavaScriptIndex() throws {
        let (_, home, service) = try fixture(.omp)
        let package = home.directory.appendingPathComponent("extensions/user-package")
        let source = package.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = package.appendingPathComponent("package.json")
        try writeJSON(["omp": ["extensions": [false, "src", 42] as [Any]]], to: manifest)
        let active = source.appendingPathComponent("index.ts")
        let inactive = source.appendingPathComponent("index.js")
        let activeContent = Data("export default function () {}\n".utf8)
        let inactiveContent = Data("export { default } from '/tmp/checkout/hooks/agents-omp.ts';\n".utf8)
        try activeContent.write(to: active)
        try inactiveContent.write(to: inactive)
        try service.apply(service.prepare(home, action: .install))
        XCTAssertEqual(service.inspect(home).status, .configured)
        XCTAssertEqual(try Data(contentsOf: active), activeContent)
        XCTAssertEqual(try Data(contentsOf: inactive), inactiveContent)
    }
}
