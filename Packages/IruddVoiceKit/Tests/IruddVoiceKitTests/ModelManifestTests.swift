import CryptoKit
import Foundation
import Testing
@testable import IruddVoiceKit

struct ModelManifestTests {
    func sha(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A model folder with two small files and a matching manifest.
    /// With `drafter`, also a `drafter/` folder and the manifest's drafter field.
    func makeFolder(schema: Int = 1, promptVersion: String? = nil, drafter: [String: Any]? = nil) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("irudd-voice-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "{}".write(to: folder.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "weights".write(to: folder.appendingPathComponent("model.safetensors"), atomically: true, encoding: .utf8)
        var files = ["config.json": sha("{}"), "model.safetensors": sha("weights")]
        if drafter != nil {
            let sub = folder.appendingPathComponent("drafter")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try "{\"model_type\": \"gemma4_assistant\"}".write(to: sub.appendingPathComponent("config.json"),
                                                               atomically: true, encoding: .utf8)
            try "drafter".write(to: sub.appendingPathComponent("model.safetensors"), atomically: true, encoding: .utf8)
            files["drafter/config.json"] = sha("{\"model_type\": \"gemma4_assistant\"}")
            files["drafter/model.safetensors"] = sha("drafter")
        }
        let manifest: [String: Any?] = [
            "schema": schema, "id": "test-model", "family": "qwen3_5",
            "base_repo": "Qwen/Qwen3.5-2B", "base_revision": "abc",
            "source_repo": nil, "source_revision": nil,
            "tokenizer_sha256": "t", "chat_template_sha256": "c",
            "prompt_version": promptVersion,
            "quantization": ["bits": 4, "group_size": 64],
            "files": files,
            "training": nil, "drafter": drafter, "created_at": "2026-10-25T10:00:00Z",
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

    @Test func dotFilesArentPartOfTheFolder() throws {
        let folder = try makeFolder()
        let manifest = try ModelManifest.load(folder: folder)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        try "x".write(to: folder.appendingPathComponent(".cache/x"), atomically: true, encoding: .utf8)
        try "x".write(to: folder.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        try manifest.verify(folder: folder)
        // Listed dot files aren't required either.
        var listing = manifest
        listing.files[".gitattributes"] = "0000"
        try listing.verify(folder: folder)
    }

    @Test func theMacHiddenFlagDoesntSkipAFile() throws {
        let folder = try makeFolder()
        let manifest = try ModelManifest.load(folder: folder)
        var extra = folder.appendingPathComponent("extra.json")
        try "x".write(to: extra, atomically: true, encoding: .utf8)
        var values = URLResourceValues()
        values.isHidden = true
        try extra.setResourceValues(values)
        #expect(try extra.resourceValues(forKeys: [.isHiddenKey]).isHidden == true)
        // Hidden by flag but no leading dot: still part of the folder, so unlisted.
        #expect(throws: ModelFolderError.unlistedFile("extra.json")) { try manifest.verify(folder: folder) }
        // And a listed weights file with the flag is still hashed.
        var weights = folder.appendingPathComponent("model.safetensors")
        try weights.setResourceValues(values)
        try FileManager.default.removeItem(at: extra)
        try manifest.verify(folder: folder)
        try "changed".write(to: weights, atomically: false, encoding: .utf8)
        try weights.setResourceValues(values)
        #expect(throws: ModelFolderError.checksumMismatch("model.safetensors")) { try manifest.verify(folder: folder) }
    }

    @Test func refusesAWrongID() throws {
        let folder = try makeFolder()
        #expect(throws: ModelFolderError.idMismatch(folder: "other-model", manifest: "test-model")) {
            try ModelManifest.load(folder: folder, expectedID: "other-model")
        }
        #expect(try ModelManifest.load(folder: folder, expectedID: "test-model").id == "test-model")
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

    /// The gemma-4-e2b drafter field, with `change` (JSON) applied.
    static func assistant(_ change: String = "{}") throws -> [String: Any] {
        let base: [String: Any] = [
            "repo": "google/gemma-4-E2B-it-assistant", "revision": "2d874ef7d29f9a30599a1e4b3c1cbc9595f005df",
            "folder": "drafter", "draft_tokens": 3,
        ]
        let changes = try JSONSerialization.jsonObject(with: Data(change.utf8)) as? [String: Any] ?? [:]
        return base.merging(changes) { $1 }
    }

    @Test func readsAndVerifiesADrafter() throws {
        let folder = try makeFolder(drafter: Self.assistant())
        let manifest = try ModelManifest.load(folder: folder)
        #expect(manifest.drafter == .init(repo: "google/gemma-4-E2B-it-assistant",
                                          revision: "2d874ef7d29f9a30599a1e4b3c1cbc9595f005df",
                                          folder: "drafter", draftTokens: 3))
        #expect(manifest.drafterFolder(in: folder) == folder.appendingPathComponent("drafter", isDirectory: true))
        try manifest.verify(folder: folder)
        // The drafter's files are checked like the rest.
        try "changed".write(to: folder.appendingPathComponent("drafter/model.safetensors"), atomically: true, encoding: .utf8)
        #expect(throws: ModelFolderError.checksumMismatch("drafter/model.safetensors")) { try manifest.verify(folder: folder) }
    }

    @Test func noDrafterIsFine() throws {
        // Newer manifests write null; older ones have no drafter key.
        let folder = try makeFolder()
        #expect(try ModelManifest.load(folder: folder).drafter == nil)
        let url = folder.appendingPathComponent("manifest.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(object.removeValue(forKey: "drafter") != nil)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let older = try ModelManifest.load(folder: folder)
        #expect(older.drafter == nil && older.drafterFolder(in: folder) == nil)
    }

    @Test(arguments: [
        (#"{"folder": "../elsewhere"}"#, "drafter folder ../elsewhere must be one plain name inside the model folder"),
        (#"{"folder": ".drafter"}"#, "drafter folder .drafter must be one plain name inside the model folder"),
        (#"{"folder": "a/b"}"#, "drafter folder a/b must be one plain name inside the model folder"),
        (#"{"folder": "other"}"#, "drafter folder other/ has no config.json in the manifest"),
        (#"{"draft_tokens": 0}"#, "drafter draft_tokens must be at least 1"),
        (#"{"revision": ""}"#, "drafter needs a repo and a revision"),
    ])
    func refusesABadDrafter(change: String, problem: String) throws {
        let folder = try makeFolder(drafter: Self.assistant(change))
        #expect(throws: ModelFolderError.badDrafter(problem)) { try ModelManifest.load(folder: folder) }
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
