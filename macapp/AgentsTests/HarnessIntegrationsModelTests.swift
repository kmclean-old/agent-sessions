import Foundation
import XCTest
@testable import Agents

@MainActor
final class HarnessIntegrationsModelTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let integrationRoot: URL
        let defaults: UserDefaults
        let service: HarnessSetupService
        let model: HarnessIntegrationsModel

        func home(_ name: String, harness: HarnessKind = .claude) throws -> HarnessHome {
            let path = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            return HarnessHome(harness: harness, directory: path)
        }
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("integration-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "HarnessIntegrationsModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: directory)
        }
        let root = directory.appendingPathComponent("Application Support/Agents/integrations")
        let service = HarnessSetupService(
            root: root,
            emitters: [
                "agents-status.sh": Data("#!/bin/sh\nexit 0\n".utf8),
                "agents-omp.ts": Data("export default function () {}\n".utf8)
            ],
            userHome: directory,
            environment: [:]
        )
        return Fixture(directory: directory, integrationRoot: root, defaults: defaults, service: service,
                       model: HarnessIntegrationsModel(service: service, defaults: defaults))
    }

    func testMultipleSelectedHomesPersistWithoutDuplicateRows() throws {
        let f = try fixture()
        let first = try f.home("personal")
        let second = try f.home("work")
        let codex = try f.home("codex", harness: .codex)
        for home in [first, second, codex, first] {
            f.model.addHome(home.directory, for: home.harness)
        }
        let expected = Set([first.id, second.id, codex.id])
        XCTAssertEqual(Set(f.model.inspections.map(\.home.id)), expected)
        XCTAssertEqual(f.model.inspections.count, 3)
        XCTAssertTrue(f.model.inspections.allSatisfy { $0.status == .notInstalled })
        XCTAssertNil(f.model.error)

        let restored = HarnessIntegrationsModel(service: f.service, defaults: f.defaults)
        restored.refresh()
        XCTAssertEqual(Set(restored.inspections.map(\.home.id)), expected)
        XCTAssertEqual(restored.inspections.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.integrationRoot.path))
    }

    func testPreparingAndCancellingLeavesExistingConfigurationUntouched() throws {
        let f = try fixture()
        let home = try f.home("profile")
        let config = home.directory.appendingPathComponent("settings.json")
        let original = Data("{\"theme\": \"dark\"}\n".utf8)
        try original.write(to: config)
        f.model.addHome(home.directory, for: home.harness)
        f.model.prepare(home, action: .install)

        let plan = try XCTUnwrap(f.model.preview)
        let change = try XCTUnwrap(plan.changes.first { $0.path == config.path })
        XCTAssertTrue(try XCTUnwrap(change.after).contains("agents-status.sh"))
        XCTAssertEqual(try Data(contentsOf: config), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.integrationRoot.path))
        f.model.preview = nil
        XCTAssertEqual(try Data(contentsOf: config), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.integrationRoot.path))
        XCTAssertNil(f.model.notice)
        XCTAssertNil(f.model.error)
    }

    func testApplyRefreshesConfigurationAndExplainsCodexTrustAndRemoval() throws {
        let f = try fixture()
        let home = try f.home("codex", harness: .codex)
        f.model.addHome(home.directory, for: home.harness)
        f.model.prepare(home, action: .install)
        f.model.apply(try XCTUnwrap(f.model.preview))

        XCTAssertNil(f.model.preview)
        XCTAssertNil(f.model.error)
        XCTAssertEqual(f.model.inspections.first?.status, .configured)
        XCTAssertEqual(f.model.inspections.count, 1, "Discovery and the selected home share one row")
        XCTAssertTrue(try XCTUnwrap(f.model.notice).contains("/hooks"))
        XCTAssertTrue(try XCTUnwrap(f.model.notice).contains("new Agents pane"))

        f.model.prepare(home, action: .remove)
        XCTAssertNil(f.model.notice)
        f.model.apply(try XCTUnwrap(f.model.preview))
        XCTAssertNil(f.model.error)
        XCTAssertNil(f.model.preview)
        XCTAssertEqual(f.model.inspections.first?.status, .notInstalled)
        XCTAssertTrue(try XCTUnwrap(f.model.notice).contains("Removed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.directory.appendingPathComponent("hooks.json").path))
    }

    func testDeletedHomeMakesApplyFailAndRefreshShowsUnavailable() throws {
        let f = try fixture()
        let home = try f.home("profile")
        f.model.addHome(home.directory, for: home.harness)
        f.model.prepare(home, action: .install)
        let plan = try XCTUnwrap(f.model.preview)
        try FileManager.default.removeItem(at: home.directory)
        f.model.apply(plan)

        XCTAssertNotNil(f.model.error)
        XCTAssertNil(f.model.preview)
        XCTAssertNil(f.model.notice)
        XCTAssertEqual(f.model.inspections.first?.status, .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.integrationRoot.path))

        f.model.error = nil
        f.model.prepare(home, action: .repair)
        XCTAssertNotNil(f.model.error)
        XCTAssertNil(f.model.preview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.directory.path))
    }

    func testInterveningEditsArePreservedAndUserCanPrepareAgain() throws {
        let f = try fixture()
        let home = try f.home("profile")
        f.model.addHome(home.directory, for: home.harness)
        f.model.prepare(home, action: .install)
        let plan = try XCTUnwrap(f.model.preview)
        let config = home.directory.appendingPathComponent("settings.json")
        let edited = Data("{\"theme\": \"light\"}\n".utf8)
        try edited.write(to: config)
        f.model.apply(plan)

        XCTAssertNotNil(f.model.error)
        XCTAssertNil(f.model.notice)
        XCTAssertNil(f.model.preview)
        XCTAssertEqual(try Data(contentsOf: config), edited)
        XCTAssertEqual(f.model.inspections.first?.status, .notInstalled)

        f.model.error = nil
        f.model.prepare(home, action: .install)
        let replacement = try XCTUnwrap(f.model.preview)
        XCTAssertNotEqual(replacement.id, plan.id)
        f.model.apply(replacement)
        XCTAssertNil(f.model.error)
        XCTAssertEqual(f.model.inspections.first?.status, .configured)
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        XCTAssertEqual(settings["theme"] as? String, "light")
    }
}
