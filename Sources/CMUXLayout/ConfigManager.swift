import Foundation

public enum ConfigError: Error, Equatable {
    case templateNotFound(String)
    case versionTooNew(fileVersion: Int, maxSupported: Int)
    case invalidConfig(String)
}

public struct ConfigManager: Sendable {
    public static let currentSchemaVersion = 1
    public static let defaultPath = NSHomeDirectory() + "/.config/cmux-layout/config.toml"
    private let path: String
    private var document: TOMLDocument

    public static let defaultScaffold = """
    # cmux-layout configuration
    # Version: 1

    [settings]
    # No settings defined yet. Future options will appear here.

    [templates]
    # Save workspace templates using: cmux-layout save <name> <descriptor>
    # Example:
    # [templates.dev]
    # descriptor = "workspace:Dev | cols:25,50,25 | rows[0]:60,40"
    """

    public init(path: String? = nil) throws {
        self.path = path ?? Self.defaultPath

        let dir = (self.path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: self.path) {
            let content = try String(contentsOfFile: self.path, encoding: .utf8)
            self.document = try TOMLParser.parse(content)
            try checkVersion()
        } else {
            self.document = try TOMLParser.parse(Self.defaultScaffold)
            try persist()
        }
    }

    public var configPath: String { path }

    // MARK: - Version management

    private func fileVersion() -> Int? {
        for entry in document.entries {
            if case .comment(let text) = entry {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("# Version:") {
                    let numStr = trimmed.dropFirst("# Version:".count)
                        .trimmingCharacters(in: .whitespaces)
                    return Int(numStr)
                }
            }
        }
        return nil
    }

    private func checkVersion() throws {
        guard let version = fileVersion() else { return }
        if version > Self.currentSchemaVersion {
            throw ConfigError.versionTooNew(
                fileVersion: version,
                maxSupported: Self.currentSchemaVersion
            )
        }
    }

    // MARK: - Template CRUD

    public mutating func save(name: String, descriptor: String) throws {
        _ = try Parser().parse(descriptor)

        let tableName = "templates.\(name)"
        if document.getString(table: tableName, key: "descriptor") != nil {
            document.setString(table: tableName, key: "descriptor", value: descriptor)
        } else {
            let existing = document.tablesWithPrefix("templates.")
            let insertAfter = existing.last ?? "templates"
            document.insertTable(tableName, after: insertAfter)
            document.setString(table: tableName, key: "descriptor", value: descriptor)
        }
        try persist()
    }

    public func load(name: String) throws -> String {
        let tableName = "templates.\(name)"
        guard let descriptor = document.getString(table: tableName, key: "descriptor") else {
            throw ConfigError.templateNotFound(name)
        }
        return descriptor
    }

    public func list() throws -> [(name: String, descriptor: String)] {
        document.tablesWithPrefix("templates.")
            .compactMap { tableName in
                let name = String(tableName.dropFirst("templates.".count))
                guard let desc = document.getString(table: tableName, key: "descriptor") else {
                    return nil
                }
                return (name: name, descriptor: desc)
            }
            .sorted { $0.name < $1.name }
    }

    public mutating func delete(name: String) throws {
        let tableName = "templates.\(name)"
        guard document.getString(table: tableName, key: "descriptor") != nil else {
            throw ConfigError.templateNotFound(name)
        }
        document.removeTable(tableName)
        try persist()
    }

    // MARK: - Persistence

    private func persist() throws {
        let content = TOMLParser.serialize(document)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
