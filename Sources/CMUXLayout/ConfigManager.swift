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

    // MARK: - Persistence

    private func persist() throws {
        let content = TOMLParser.serialize(document)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
