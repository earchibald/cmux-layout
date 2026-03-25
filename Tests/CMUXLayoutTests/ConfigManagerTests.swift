import Testing
import Foundation
@testable import CMUXLayout

@Suite("Config Manager Tests")
struct ConfigManagerTests {
    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "cmux-layout-test-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test func bootstrapCreatesConfigFile() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        let _ = try ConfigManager(path: path)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func bootstrapScaffoldContainsVersionAndSections() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        let _ = try ConfigManager(path: path)
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("# Version: 1"))
        #expect(content.contains("[settings]"))
        #expect(content.contains("[templates]"))
    }

    // MARK: - Template CRUD

    @Test func bootstrapPreservesExistingFile() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        var mgr = try ConfigManager(path: path)
        try mgr.save(name: "dev", descriptor: "grid:2x2")
        let mgr2 = try ConfigManager(path: path)
        let templates = try mgr2.list()
        #expect(templates.count == 1)
        #expect(templates[0].name == "dev")
    }

    @Test func saveAndLoadTemplate() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        var mgr = try ConfigManager(path: dir + "/config.toml")
        try mgr.save(name: "dev", descriptor: "grid:2x2")
        let loaded = try mgr.load(name: "dev")
        #expect(loaded == "grid:2x2")
    }

    @Test func saveValidatesDescriptor() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        var mgr = try ConfigManager(path: dir + "/config.toml")
        #expect(throws: ParseError.self) {
            try mgr.save(name: "bad", descriptor: "not-a-valid-descriptor")
        }
    }

    @Test func loadThrowsForMissingTemplate() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let mgr = try ConfigManager(path: dir + "/config.toml")
        #expect(throws: ConfigError.self) {
            try mgr.load(name: "nope")
        }
    }

    @Test func listReturnsAllTemplatesSorted() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        var mgr = try ConfigManager(path: dir + "/config.toml")
        try mgr.save(name: "zeta", descriptor: "grid:2x2")
        try mgr.save(name: "alpha", descriptor: "grid:3x3")
        let all = try mgr.list()
        #expect(all.count == 2)
        #expect(all[0].name == "alpha")
        #expect(all[1].name == "zeta")
    }

    @Test func deleteRemovesTemplate() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        var mgr = try ConfigManager(path: dir + "/config.toml")
        try mgr.save(name: "dev", descriptor: "grid:2x2")
        try mgr.delete(name: "dev")
        #expect(throws: ConfigError.self) {
            try mgr.load(name: "dev")
        }
    }

    @Test func savePersistsAcrossInstances() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        var mgr1 = try ConfigManager(path: path)
        try mgr1.save(name: "dev", descriptor: "grid:2x2")
        let mgr2 = try ConfigManager(path: path)
        let loaded = try mgr2.load(name: "dev")
        #expect(loaded == "grid:2x2")
    }

    @Test func saveOverwritesExistingTemplate() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        var mgr = try ConfigManager(path: dir + "/config.toml")
        try mgr.save(name: "dev", descriptor: "grid:2x2")
        try mgr.save(name: "dev", descriptor: "grid:3x3")
        let loaded = try mgr.load(name: "dev")
        #expect(loaded == "grid:3x3")
    }
}
