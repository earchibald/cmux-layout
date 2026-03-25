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

    // TODO: bootstrapPreservesExistingFile — deferred to Task 6 (needs save/list)
}
