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

    private mutating func checkVersion() throws {
        let version = fileVersion() ?? 0
        if version > Self.currentSchemaVersion {
            throw ConfigError.versionTooNew(
                fileVersion: version,
                maxSupported: Self.currentSchemaVersion
            )
        }
        if version < Self.currentSchemaVersion {
            try upgradeFrom(version: version)
        }
    }

    private mutating func upgradeFrom(version: Int) throws {
        var v = version

        if v < 1 {
            // v0 -> v1: ensure [templates] section exists
            let hasTemplates = document.tablesWithPrefix("templates").contains(where: { $0 == "templates" })
                || !document.tablesWithPrefix("templates.").isEmpty
            if !hasTemplates {
                document.insertTable("templates", after: "settings")
                // Add scaffold comments after the [templates] header
                if let range = document.tableRange("templates") {
                    let comments = [
                        "# Save workspace templates using: cmux-layout save <name> <descriptor>",
                        "# Example:",
                        "# [templates.dev]",
                        #"# descriptor = "workspace:Dev | cols:25,50,25 | rows[0]:60,40""#,
                    ]
                    for (offset, comment) in comments.enumerated() {
                        document.entries.insert(.comment(comment), at: range.headerIndex + 1 + offset)
                    }
                }
            }
            v = 1
        }

        // Update version comment
        updateVersionComment(to: Self.currentSchemaVersion)
        try persist()
    }

    private mutating func updateVersionComment(to version: Int) {
        for (i, entry) in document.entries.enumerated() {
            if case .comment(let text) = entry,
               text.trimmingCharacters(in: .whitespaces).hasPrefix("# Version:") {
                document.entries[i] = .comment("# Version: \(version)")
                return
            }
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

    // MARK: - Model loading

    public func loadModel(name: String) throws -> LayoutModel {
        let descriptor = try load(name: name)
        var model = try Parser().parse(descriptor)

        let cellTablePrefix = "templates.\(name).cells."
        let cellTables = document.tablesWithPrefix(cellTablePrefix)
        guard !cellTables.isEmpty else { return model }

        var overrides: [String: CellSpec] = [:]
        for tableName in cellTables {
            let cellName = String(tableName.dropFirst(cellTablePrefix.count))
            let typeStr = document.getString(table: tableName, key: "type") ?? "terminal"
            let url = document.getString(table: tableName, key: "url")
            let surfaceType: SurfaceType
            if typeStr == "browser" {
                surfaceType = .browser(url: url)
            } else {
                surfaceType = .terminal
            }
            overrides[cellName] = CellSpec(name: cellName, type: surfaceType)
        }

        if var cells = model.cells {
            for i in cells.indices {
                if let name = cells[i].name, let override = overrides[name] {
                    cells[i] = override
                }
            }
            model.cells = cells
        }

        return model
    }

    // MARK: - Settings

    public func getSetting(key: String) -> String? {
        document.getString(table: "settings", key: key)
    }

    public mutating func setSetting(key: String, value: String) throws {
        document.setString(table: "settings", key: key, value: value)
        try persist()
    }

    // MARK: - Persistence

    private func persist() throws {
        let content = TOMLParser.serialize(document)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
