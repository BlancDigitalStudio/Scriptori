import Foundation

/// Small JSON-file store for offline-first state (profile, reflections, progress).
/// Remote sync layers on top of this; the device copy is always the source of truth for the UI.
public actor LocalStore {
    public enum Key: String, Sendable {
        case profile, reflections, chapterProgress, reflectionDraft
    }

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scriptori", isDirectory: true)
        self.directory = base
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func load<Value: Decodable & Sendable>(_ type: Value.Type, for key: Key, namespace: String) -> Value? {
        guard let data = try? Data(contentsOf: url(for: key, namespace: namespace)) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    public func save<Value: Encodable & Sendable>(_ value: Value, for key: Key, namespace: String) throws {
        let url = url(for: key, namespace: namespace)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtection])
    }

    public func remove(_ key: Key, namespace: String) {
        try? FileManager.default.removeItem(at: url(for: key, namespace: namespace))
    }

    public func removeAll(namespace: String) throws {
        let folder = directory.appendingPathComponent(namespace, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    private func url(for key: Key, namespace: String) -> URL {
        directory
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("\(key.rawValue).json")
    }
}
