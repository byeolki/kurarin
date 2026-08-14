import Foundation

/// Loads and saves user presets as one JSON file each.
///
/// A file per preset rather than a single library file: a corrupt write then
/// costs one preset instead of all of them, and the directory stays something
/// a user can back up, hand-edit or share a single entry from.
public final class PresetStore {
    public enum StoreError: Error, LocalizedError {
        case notEditable(String)

        public var errorDescription: String? {
            switch self {
            case .notEditable(let name):
                return "\(name) is a built-in preset and cannot be overwritten."
            }
        }
    }

    public let directory: URL

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("Kurarin/presets", isDirectory: true)
        }
    }

    /// Built-ins first, then user presets by name.
    public func loadAll() -> [Preset] {
        Preset.builtIns + loadUserPresets()
    }

    public func loadUserPresets() -> [Preset] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return entries
            .filter { $0.pathExtension == "json" }
            // A preset that fails to decode is skipped rather than aborting the
            // load: one bad file should not cost the user the rest of them.
            .compactMap { url -> Preset? in
                guard let data = try? Data(contentsOf: url),
                      var preset = try? decoder.decode(Preset.self, from: data) else {
                    return nil
                }
                preset.isBuiltIn = false
                return preset
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public func save(_ preset: Preset) throws -> Preset {
        guard !preset.isBuiltIn else {
            throw StoreError.notEditable(preset.name)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var stored = preset
        stored.parameters = preset.parameters.clamped()

        let data = try encoder.encode(stored)
        try data.write(to: url(for: stored.id), options: .atomic)
        return stored
    }

    public func delete(_ preset: Preset) throws {
        guard !preset.isBuiltIn else {
            throw StoreError.notEditable(preset.name)
        }
        let target = url(for: preset.id)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
