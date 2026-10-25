import CryptoKit
import Foundation

/// `manifest.json` in a model folder (shared/manifest.schema.md, schema 1).
public struct ModelManifest: Codable, Equatable, Sendable {
    public struct Quantization: Codable, Equatable, Sendable {
        public var bits: Int
        public var groupSize: Int

        enum CodingKeys: String, CodingKey {
            case bits
            case groupSize = "group_size"
        }
    }

    public struct Training: Codable, Equatable, Sendable {
        public var method: String
        public var datasetHash: String?
        public var chunks: Int?
        public var layers: Int?
        public var iterations: Int?
        public var mlxLMVersion: String?
        public var trainedAt: String?

        enum CodingKeys: String, CodingKey {
            case method, chunks, layers, iterations
            case datasetHash = "dataset_hash"
            case mlxLMVersion = "mlx_lm_version"
            case trainedAt = "trained_at"
        }
    }

    public var schema: Int
    public var id: String
    public var family: String
    public var baseRepo: String
    public var baseRevision: String
    public var sourceRepo: String?
    public var sourceRevision: String?
    public var tokenizerSHA256: String
    public var chatTemplateSHA256: String
    public var promptVersion: String?
    public var quantization: Quantization?
    public var files: [String: String]
    public var training: Training?
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case schema, id, family, quantization, files, training
        case baseRepo = "base_repo"
        case baseRevision = "base_revision"
        case sourceRepo = "source_repo"
        case sourceRevision = "source_revision"
        case tokenizerSHA256 = "tokenizer_sha256"
        case chatTemplateSHA256 = "chat_template_sha256"
        case promptVersion = "prompt_version"
        case createdAt = "created_at"
    }

    public static let fileName = "manifest.json"
    public static let supportedSchema = 1

    /// Reads `<folder>/manifest.json`, refusing a missing file, an unknown
    /// schema, or (when loading by id) an `id` that isn't the folder's name.
    public static func load(folder: URL, expectedID: String?) throws -> ModelManifest {
        let manifest = try load(folder: folder)
        if let expectedID, manifest.id != expectedID {
            throw ModelFolderError.idMismatch(folder: expectedID, manifest: manifest.id)
        }
        return manifest
    }

    /// Reads `<folder>/manifest.json`, refusing a missing file or an unknown schema.
    public static func load(folder: URL) throws -> ModelManifest {
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else {
            throw ModelFolderError.missingManifest(folder.path)
        }
        struct SchemaOnly: Decodable { var schema: Int }
        let schema = try JSONDecoder().decode(SchemaOnly.self, from: data).schema
        guard schema == supportedSchema else {
            throw ModelFolderError.unknownSchema(schema)
        }
        return try JSONDecoder().decode(ModelManifest.self, from: data)
    }

    /// Whether this model can run with a prompt version: base models (no
    /// `prompt_version`) work with any; a trained one only with its own.
    public func accepts(promptVersion current: String) -> Bool {
        promptVersion == nil || promptVersion == current
    }

    /// Checks every file against `files`. Refuses the folder when a listed file
    /// is missing or differs, or when a file in the folder isn't listed.
    /// Dot files (".DS_Store", anything in ".cache/") aren't part of a model
    /// folder: they're neither hashed nor required, even if listed.
    public func verify(folder: URL) throws {
        let present = try Self.filesInFolder(folder)
        let listed = files.filter { !Self.isDotPath($0.key) }
        let unlisted = present.subtracting(listed.keys).subtracting([Self.fileName])
        if let name = unlisted.sorted().first {
            throw ModelFolderError.unlistedFile(name)
        }
        for (name, expected) in listed.sorted(by: { $0.key < $1.key }) {
            guard present.contains(name) else { throw ModelFolderError.missingFile(name) }
            let actual = try Self.sha256(of: folder.appendingPathComponent(name))
            guard actual == expected.lowercased() else {
                throw ModelFolderError.checksumMismatch(name)
            }
        }
    }

    /// Whether a path relative to the model folder is skipped: its name, or
    /// any parent folder's name inside the model folder, starts with "."
    /// (shared/manifest.schema.md). Not `.skipsHiddenFiles`, which also
    /// skips files with the macOS hidden flag, so Swift and Python would differ.
    static func isDotPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// Relative paths of the regular files under `folder`, without dot paths.
    /// Files with the Finder "hidden" flag but no leading dot still count.
    static func filesInFolder(_ folder: URL) throws -> Set<String> {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            throw ModelFolderError.missingManifest(folder.path)
        }
        var names: Set<String> = []
        for case let url as URL in enumerator {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(root + "/") else { continue }
            let name = String(path.dropFirst(root.count + 1))
            if !isDotPath(name) { names.insert(name) }
        }
        return names
    }

    /// The SHA-256 of a file as lowercase hex, read in 4 MB pieces so multi-GB
    /// weights don't sit in memory.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum ModelFolderError: Error, Equatable, LocalizedError {
    case missingManifest(String)
    case unknownSchema(Int)
    case missingFile(String)
    case unlistedFile(String)
    case idMismatch(folder: String, manifest: String)
    case checksumMismatch(String)
    case promptVersionMismatch(model: String, current: String)

    public var errorDescription: String? {
        switch self {
        case .missingManifest(let path): "No readable manifest.json in \(path)."
        case .unknownSchema(let schema): "manifest.json has unknown schema \(schema)."
        case .missingFile(let name): "\(name) is listed in manifest.json but missing."
        case .unlistedFile(let name): "\(name) is in the model folder but not in manifest.json."
        case .idMismatch(let folder, let manifest): "The model folder \(folder) has a manifest for \(manifest)."
        case .checksumMismatch(let name): "\(name) doesn't match its checksum in manifest.json."
        case .promptVersionMismatch(let model, let current):
            "The model was trained on prompt \(model), but the current prompt is \(current)."
        }
    }
}

/// `vocabulary.json` (shared/vocabulary.schema.md).
public struct Vocabulary: Codable, Equatable, Sendable {
    public var version: Int
    public var generatedAt: String?
    public var terms: [String]

    enum CodingKeys: String, CodingKey {
        case version, terms
        case generatedAt = "generated_at"
    }

    /// The terms in file order, or none when the file is missing.
    public static func terms(at url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(Vocabulary.self, from: Data(contentsOf: url)).terms
    }

    /// The first `limit` terms, which the prompt and the hard checks use.
    public static func terms(at url: URL, limit: Int) throws -> [String] {
        Array(try terms(at: url).prefix(limit))
    }
}

/// Where the app keeps models and the vocabulary.
public enum ModelPaths {
    public static var supportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/irudd-voice")
    }

    public static var modelsFolder: URL { supportFolder.appendingPathComponent("models") }

    public static var vocabularyFile: URL { supportFolder.appendingPathComponent("vocabulary.json") }

    /// A model id matches `[a-z0-9][a-z0-9.-]*`, so it can't leave the models folder.
    public static func isValidID(_ id: String) -> Bool {
        guard let first = id.utf8.first, isLowerOrDigit(first) else { return false }
        return id.utf8.allSatisfy { isLowerOrDigit($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }
            && id != "." && !id.contains("..")
    }

    private static func isLowerOrDigit(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
    }

    public static func folder(forModel id: String, in models: URL = modelsFolder) -> URL? {
        isValidID(id) ? models.appendingPathComponent(id) : nil
    }
}
