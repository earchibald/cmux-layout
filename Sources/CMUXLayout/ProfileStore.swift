import Foundation

public struct ProfileStore {
    private let path: String

    public init(path: String? = nil) {
        self.path = path
            ?? (NSHomeDirectory() + "/.config/cmux-layout/profiles.json")
    }

    public func list() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return dict
    }

    public func load(_ name: String) throws -> String {
        let profiles = try list()
        guard let descriptor = profiles[name] else {
            throw ProfileError.notFound(name)
        }
        return descriptor
    }

    public func save(name: String, descriptor: String) throws {
        var profiles = (try? list()) ?? [:]
        profiles[name] = descriptor

        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        let data = try JSONSerialization.data(
            withJSONObject: profiles,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: path))
    }

    public func delete(_ name: String) throws {
        var profiles = try list()
        profiles.removeValue(forKey: name)
        let data = try JSONSerialization.data(
            withJSONObject: profiles,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: path))
    }
}

public enum ProfileError: Error {
    case notFound(String)
}
