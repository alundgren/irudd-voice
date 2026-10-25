import Foundation

/// What Settings → Model shows about the active model: which one, whether
/// it's a base or a trained model, and its latest eval against the model
/// before it. Read from the `active_model` and `models` rows and the
/// model's manifest.
public struct ModelOverview: Equatable, Sendable {
    /// The active model, or the default when `active_model` is empty.
    public var activeID: String
    /// `active_model` is empty, so the default base model is used.
    public var isDefault: Bool
    public var previousID: String?
    /// The manifest's training block; nil for a base model.
    public var training: ModelManifest.Training?
    public var eval: EvalSummary?

    public init(activeID: String, isDefault: Bool, previousID: String? = nil,
                training: ModelManifest.Training? = nil, eval: EvalSummary? = nil) {
        self.activeID = activeID
        self.isDefault = isDefault
        self.previousID = previousID
        self.training = training
        self.eval = eval
    }

    public static func read(store: ChunkStore, modelsFolder: URL = ModelPaths.modelsFolder,
                            defaultID: String = CleanupDefaults.modelID) async -> ModelOverview {
        let active: (modelID: String?, previousID: String?) = (try? await store.activeModel()) ?? (nil, nil)
        let id = active.modelID ?? defaultID
        let row = (try? await store.modelRow(id: id)) ?? nil
        // The manifest the CLI recorded, or the one in the folder.
        var manifest: ModelManifest?
        if let json = row?.manifestJSON {
            manifest = try? JSONDecoder().decode(ModelManifest.self, from: Data(json.utf8))
        }
        if manifest == nil, let folder = ModelPaths.folder(forModel: id, in: modelsFolder) {
            manifest = try? ModelManifest.load(folder: folder)
        }
        var training = manifest?.training
        if var block = training {
            block.chunks = block.chunks ?? row?.trainedChunks.map(Int.init)
            block.trainedAt = block.trainedAt ?? row?.trainedAt
            training = block
        }
        return ModelOverview(activeID: id, isDefault: active.modelID == nil, previousID: active.previousID,
                             training: training, eval: row?.evalReportJSON.flatMap(EvalSummary.parse))
    }
}

/// The summary of an `irudd-voice eval-compare` report (the `models` row's
/// `eval_report_json`): this model against the one it was compared with.
public struct EvalSummary: Equatable, Sendable {
    public var incumbentID: String?
    public var createdAt: String?
    /// Frozen test thoughts both models cleaned (`summary.thoughts`).
    public var thoughts: Int
    /// Those with a usable vote.
    public var compared: Int
    /// Votes that went one way or the other (ties and failed calls don't count).
    public var decided: Int
    public var wins: Int
    /// Test thoughts where this model, and the incumbent, failed a hard check.
    public var thoughtsFailed: Int?
    public var incumbentThoughtsFailed: Int?
    public var promotable: Bool?

    public var winPercent: Double? { decided > 0 ? 100 * Double(wins) / Double(decided) : nil }

    /// Reads the fields Settings shows; nil when the JSON isn't a report.
    public static func parse(_ json: String) -> EvalSummary? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let summary = object["summary"] as? [String: Any] else { return nil }
        let votes = summary["votes"] as? [String: Any]
        let checks = summary["hard_checks"] as? [String: Any]
        return EvalSummary(
            incumbentID: (object["incumbent"] as? [String: Any])?["id"] as? String,
            createdAt: object["created_at"] as? String,
            // Reports from before `thoughts` existed only had `compared`.
            thoughts: summary["thoughts"] as? Int ?? summary["compared"] as? Int ?? 0,
            compared: summary["compared"] as? Int ?? 0,
            decided: summary["decided"] as? Int ?? 0,
            wins: votes?["win"] as? Int ?? 0,
            thoughtsFailed: checks?["candidate_thoughts_failed"] as? Int,
            incumbentThoughtsFailed: checks?["incumbent_thoughts_failed"] as? Int,
            promotable: (object["decision"] as? [String: Any])?["promotable"] as? Bool)
    }
}
