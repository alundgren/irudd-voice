import CryptoKit
import Foundation
import Testing
@testable import IruddVoiceKit

struct ModelManifestTests {
    func sha(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A model folder with two small files and a matching manifest.
    func makeFolder(schema: Int = 1, promptVersion: String? = nil) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("irudd-voice-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "{}".write(to: folder.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "weights".write(to: folder.appendingPathComponent("model.safetensors"), atomically: true, encoding: .utf8)
        let manifest: [String: Any?] = [
            "schema": schema, "id": "test-model", "family": "qwen3_5",
            "base_repo": "Qwen/Qwen3.5-2B", "base_revision": "abc",
            "source_repo": nil, "source_revision": nil,
            "tokenizer_sha256": "t", "chat_template_sha256": "c",
            "prompt_version": promptVersion,
            "quantization": ["bits": 4, "group_size": 64],
            "files": ["config.json": sha("{}"), "model.safetensors": sha("weights")],
            "training": nil, "created_at": "2026-10-25T10:00:00Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest.mapValues { $0 ?? NSNull() })
        try data.write(to: folder.appendingPathComponent("manifest.json"))
        return folder
    }

    @Test func readsAndVerifies() throws {
        let folder = try makeFolder()
        let manifest = try ModelManifest.load(folder: folder)
        #expect(manifest.id == "test-model")
        #expect(manifest.quantization == .init(bits: 4, groupSize: 64))
        try manifest.verify(folder: folder)
        // Finder's hidden files don't count.
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        try manifest.verify(folder: folder)
    }

    @Test func refusesAChangedFile() throws {
        let folder = try makeFolder()
        let manifest = try ModelManifest.load(folder: folder)
        try "weightz".write(to: folder.appendingPathComponent("model.safetensors"), atomically: true, encoding: .utf8)
        #expect(throws: ModelFolderError.checksumMismatch("model.safetensors")) { try manifest.verify(folder: folder) }
    }

    @Test func refusesAMissingOrExtraFile() throws {
        let folder = try makeFolder()
        let manifest = try ModelManifest.load(folder: folder)
        try "x".write(to: folder.appendingPathComponent("extra.json"), atomically: true, encoding: .utf8)
        #expect(throws: ModelFolderError.unlistedFile("extra.json")) { try manifest.verify(folder: folder) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("extra.json"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("config.json"))
        #expect(throws: ModelFolderError.missingFile("config.json")) { try manifest.verify(folder: folder) }
    }

    @Test func refusesUnknownSchemaOrNoManifest() throws {
        let folder = try makeFolder(schema: 2)
        #expect(throws: ModelFolderError.unknownSchema(2)) { try ModelManifest.load(folder: folder) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("manifest.json"))
        #expect(throws: ModelFolderError.missingManifest(folder.path)) { try ModelManifest.load(folder: folder) }
    }

    @Test func promptVersion() throws {
        #expect(try ModelManifest.load(folder: makeFolder()).accepts(promptVersion: "cleanup-v2"))
        let trained = try ModelManifest.load(folder: makeFolder(promptVersion: "cleanup-v1"))
        #expect(trained.accepts(promptVersion: "cleanup-v1"))
        #expect(!trained.accepts(promptVersion: "cleanup-v2"))
    }

    @Test func modelIDs() {
        #expect(ModelPaths.isValidID("qwen3.5-2b-base-q4"))
        #expect(!ModelPaths.isValidID("../voice"))
        #expect(!ModelPaths.isValidID("Qwen"))
        #expect(!ModelPaths.isValidID(""))
        #expect(ModelPaths.folder(forModel: "a/b") == nil)
    }

    @Test func vocabularyTakesTheFirstTerms() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-\(UUID().uuidString).json")
        #expect(try Vocabulary.terms(at: url).isEmpty)
        try #"{"version": 1, "generated_at": "2026-10-25T10:00:00Z", "terms": ["T3 Code", "SwiftUI", "irudd-voice"]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(try Vocabulary.terms(at: url, limit: 2) == ["T3 Code", "SwiftUI"])
    }
}
