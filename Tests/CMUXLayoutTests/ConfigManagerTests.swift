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

    // MARK: - Settings

    @Test func getSettingReturnsNilWhenEmpty() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let mgr = try ConfigManager(path: dir + "/config.toml")
        #expect(mgr.getSetting(key: "anything") == nil)
    }

    @Test func setAndGetSetting() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        var mgr = try ConfigManager(path: dir + "/config.toml")
        try mgr.setSetting(key: "some-option", value: "enabled")
        #expect(mgr.getSetting(key: "some-option") == "enabled")
    }

    // MARK: - Version management

    @Test func rejectNewerVersion() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        let content = """
        # cmux-layout configuration
        # Version: 999

        [settings]
        """
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: ConfigError.self) {
            try ConfigManager(path: path)
        }
    }

    @Test func upgradeFromOlderVersion() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        let content = """
        # cmux-layout configuration
        # Version: 0

        [settings]
        """
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        let _ = try ConfigManager(path: path)
        let updated = try String(contentsOfFile: path, encoding: .utf8)
        #expect(updated.contains("# Version: \(ConfigManager.currentSchemaVersion)"))
        #expect(updated.contains("[templates]"))
    }

    // MARK: - Cell table merge

    @Test func loadModelReturnsLayoutModel() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        var mgr = try ConfigManager(path: path)
        try mgr.save(name: "dev", descriptor: "cols:50,50 | names:nav,main")
        let model = try mgr.loadModel(name: "dev")
        #expect(model.columns.count == 2)
        #expect(model.cells?.count == 2)
        #expect(model.cells?[0].name == "nav")
    }

    @Test func loadModelMergesTomlCellTables() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        var mgr = try ConfigManager(path: path)
        try mgr.save(name: "dev", descriptor: "cols:50,50 | names:nav,docs")

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let updated = content + "\n\n[templates.dev.cells.docs]\ntype = \"browser\"\nurl = \"https://docs.example.com\""
        try updated.write(toFile: path, atomically: true, encoding: .utf8)

        let mgr2 = try ConfigManager(path: path)
        let model = try mgr2.loadModel(name: "dev")
        let cells = try #require(model.cells)
        #expect(cells[0] == CellSpec(name: "nav", type: .terminal))
        #expect(cells[1] == CellSpec(name: "docs", type: .browser(url: "https://docs.example.com")))
    }

    @Test func tomlCellTableOverridesInlineSpec() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        var mgr = try ConfigManager(path: path)
        try mgr.save(name: "dev", descriptor: "cols:100 | names:docs=b:https://old.com")

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let updated = content + "\n\n[templates.dev.cells.docs]\ntype = \"browser\"\nurl = \"https://new.com\""
        try updated.write(toFile: path, atomically: true, encoding: .utf8)

        let mgr2 = try ConfigManager(path: path)
        let model = try mgr2.loadModel(name: "dev")
        let cells = try #require(model.cells)
        #expect(cells[0] == CellSpec(name: "docs", type: .browser(url: "https://new.com")))
    }

    @Test func missingTomlCellDefaultsToTerminal() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        var mgr = try ConfigManager(path: path)
        try mgr.save(name: "dev", descriptor: "cols:50,50 | names:nav,docs")

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let updated = content + "\n\n[templates.dev.cells.docs]\ntype = \"browser\""
        try updated.write(toFile: path, atomically: true, encoding: .utf8)

        let mgr2 = try ConfigManager(path: path)
        let model = try mgr2.loadModel(name: "dev")
        let cells = try #require(model.cells)
        #expect(cells[0] == CellSpec(name: "nav", type: .terminal))
        #expect(cells[1] == CellSpec(name: "docs", type: .browser(url: nil)))
    }
}
