import Foundation

/// Everything known about a thought when it's saved, apart from its audio.
public struct ChunkMeta: Sendable {
    public var uuid = UUID()
    public var startedAt: Date
    public var signalAt: Date
    public var endedAt: Date
    public var timeZone: TimeZone = .current
    public var startReason: ThoughtStartReason
    public var endReason: ThoughtEndReason
    public var micUID: String
    public var micName: String?
    public var micModelUID: String?
    public var targetAppBundleID: String?
    public var targetAppName: String?
    public var appVersion: String

    public init(startedAt: Date, signalAt: Date, endedAt: Date, startReason: ThoughtStartReason,
                endReason: ThoughtEndReason, micUID: String, micName: String? = nil, micModelUID: String? = nil,
                targetAppBundleID: String? = nil, targetAppName: String? = nil, appVersion: String) {
        self.startedAt = startedAt
        self.signalAt = signalAt
        self.endedAt = endedAt
        self.startReason = startReason
        self.endReason = endReason
        self.micUID = micUID
        self.micName = micName
        self.micModelUID = micModelUID
        self.targetAppBundleID = targetAppBundleID
        self.targetAppName = targetAppName
        self.appVersion = appVersion
    }

    /// Builds the times from a captured thought that ended now-ish:
    /// `signalAt` is when the start was heard, the rest follows from the audio.
    public init(thought: CapturedThought, signalAt: Date, micUID: String, micName: String?, micModelUID: String?,
                targetAppBundleID: String?, targetAppName: String?, appVersion: String) {
        let startedAt = signalAt.addingTimeInterval(-thought.preRollDuration)
        self.init(startedAt: startedAt, signalAt: signalAt, endedAt: startedAt.addingTimeInterval(thought.duration),
                  startReason: thought.startReason, endReason: thought.endReason, micUID: micUID, micName: micName,
                  micModelUID: micModelUID, targetAppBundleID: targetAppBundleID, targetAppName: targetAppName,
                  appVersion: appVersion)
    }
}

/// One row, as the panel and tests need it.
public struct ChunkSummary: Sendable, Equatable {
    public let id: Int64
    public let status: String
    public let error: String?
    public let rawText: String?
    public let durationMs: Int64
    public let endReason: String
    public let endedAt: Date
    public let audioFormat: String
    public let audioSampleRate: Int
    public let audioBytes: Int64
}

/// What cleanup did for a row: `status` is `cleaned` or why the raw text
/// was pasted instead (`CleanupOutcome`). `cleanedText` is only set when
/// the cleaned text was used.
public struct CleanupRecord: Sendable, Equatable {
    public var status: String
    public var cleanedText: String?
    public var modelID: String?
    public var milliseconds: Int64
    public var promptVersion: String?

    public init(status: String, cleanedText: String?, modelID: String?, milliseconds: Int64, promptVersion: String?) {
        self.status = status
        self.cleanedText = cleanedText
        self.modelID = modelID
        self.milliseconds = milliseconds
        self.promptVersion = promptVersion
    }
}

/// A `models` row, as Settings → Model needs it.
public struct ModelRow: Sendable, Equatable {
    public var id: String
    public var manifestJSON: String?
    public var trainedChunks: Int64?
    public var trainedAt: String?
    public var evalReportJSON: String?
}

/// Reads and writes chunk rows. One connection, used from this actor only.
public actor ChunkStore {
    private let db: Database
    public nonisolated let path: String

    public init(path: String = Schema.defaultPath) throws {
        self.path = path
        db = try Schema.open(path: path)
    }

    /// Saves the audio as a pending row. This is the first thing that
    /// happens when a thought ends, before recognition can fail.
    public func insertPending(meta: ChunkMeta, audio: EncodedAudio, durationMs: Int64) throws -> Int64 {
        let now = Timestamps.string(Date())
        let offsetMinutes = meta.timeZone.secondsFromGMT(for: meta.startedAt) / 60
        try db.query("""
            INSERT INTO chunks (uuid, status, started_at, signal_at, ended_at, local_day, utc_offset_minutes,
                duration_ms, start_reason, end_reason, mic_uid, mic_name, mic_model_uid, audio, audio_format,
                audio_sample_rate, audio_bytes, target_app_bundle_id, target_app_name, schema_version,
                app_version, created_at, updated_at)
            VALUES (?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .text(meta.uuid.uuidString.lowercased()),
                .text(Timestamps.string(meta.startedAt)),
                .text(Timestamps.string(meta.signalAt)),
                .text(Timestamps.string(meta.endedAt)),
                .text(Timestamps.localDay(meta.startedAt, timeZone: meta.timeZone)),
                .int(Int64(offsetMinutes)),
                .int(durationMs),
                .text(meta.startReason.rawValue),
                .text(meta.endReason.rawValue),
                .text(meta.micUID),
                .optional(meta.micName),
                .optional(meta.micModelUID),
                .blob(audio.data),
                .text(audio.format),
                .int(Int64(audio.sampleRate)),
                .int(Int64(audio.data.count)),
                .optional(meta.targetAppBundleID),
                .optional(meta.targetAppName),
                .int(Int64(Schema.currentVersion)),
                .text(meta.appVersion),
                .text(now),
                .text(now),
            ])
        return db.lastInsertRowID
    }

    public func markTranscribed(id: Int64, text: String, recognizer: String) throws {
        let now = Timestamps.string(Date())
        try db.query("""
            UPDATE chunks SET status = 'transcribed', raw_text = ?, recognizer = ?, transcribed_at = ?,
                error = NULL, updated_at = ? WHERE id = ?
            """, [.text(text), .text(recognizer), .text(now), .text(now), .int(id)])
    }

    /// Records what happened to the text: pasted, waiting, copied, discarded, empty.
    public func markPaste(id: Int64, status: String, text: String?) throws {
        let now = Timestamps.string(Date())
        try db.query("""
            UPDATE chunks SET paste_status = ?, pasted_text = COALESCE(?, pasted_text),
                pasted_at = CASE WHEN ? = 'pasted' THEN ? ELSE pasted_at END, updated_at = ? WHERE id = ?
            """, [.text(status), .optional(text), .text(status), .text(now), .text(now), .int(id)])
    }

    /// Thrown away: keeps the audio and text, but it's never pasted.
    public func markDiscarded(id: Int64) throws {
        try db.query("UPDATE chunks SET status = 'discarded', paste_status = 'discarded', updated_at = ? WHERE id = ?",
                     [.text(Timestamps.string(Date())), .int(id)])
    }

    public func markError(id: Int64, message: String) throws {
        try db.query("UPDATE chunks SET status = 'error', error = ?, updated_at = ? WHERE id = ?",
                     [.text(message), .text(Timestamps.string(Date())), .int(id)])
    }

    /// Records how cleanup went for a row (docs/database.md, `cleanup_status`).
    public func markCleanup(id: Int64, _ record: CleanupRecord) throws {
        try db.query("""
            UPDATE chunks SET cleaned_text = ?, cleanup_model_id = ?, cleanup_status = ?, cleanup_ms = ?,
                prompt_version = ?, updated_at = ? WHERE id = ?
            """, [.optional(record.cleanedText), .optional(record.modelID), .text(record.status),
                  .int(record.milliseconds), .optional(record.promptVersion), .text(Timestamps.string(Date())),
                  .int(id)])
    }

    public func cleanupRecord(id: Int64) throws -> CleanupRecord? {
        guard let row = try db.query("""
            SELECT cleanup_status, cleaned_text, cleanup_model_id, cleanup_ms, prompt_version FROM chunks WHERE id = ?
            """, [.int(id)]).first, let status = row[0].text else { return nil }
        return CleanupRecord(status: status, cleanedText: row[1].text, modelID: row[2].text,
                             milliseconds: row[3].int ?? 0, promptVersion: row[4].text)
    }

    public func pastedText(id: Int64) throws -> String? {
        try db.query("SELECT pasted_text FROM chunks WHERE id = ?", [.int(id)]).first?[0].text
    }

    // MARK: App state shared with the CLI (shared/app-state.md)

    public func appState(_ key: String) throws -> String? {
        try db.query("SELECT value FROM app_state WHERE key = ?", [.text(key)]).first?[0].text
    }

    public func setAppState(_ key: String, _ value: String, at date: Date = Date()) throws {
        try db.query("""
            INSERT INTO app_state (key, value, updated_at) VALUES (?, ?, ?)
            ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            """, [.text(key), .text(value), .text(Timestamps.string(date))])
    }

    public func deleteAppState(_ key: String) throws {
        try db.query("DELETE FROM app_state WHERE key = ?", [.text(key)])
    }

    /// The `active_model` row: nil model ID means the default base model.
    public func activeModel() throws -> (modelID: String?, previousID: String?) {
        guard let row = try db.query("SELECT model_id, previous_model_id FROM active_model WHERE slot = 1").first
        else { return (nil, nil) }
        let id = row[0].text.flatMap { $0.isEmpty ? nil : $0 }
        return (id, row[1].text.flatMap { $0.isEmpty ? nil : $0 })
    }

    public func modelRow(id: String) throws -> ModelRow? {
        guard let row = try db.query("""
            SELECT id, manifest_json, trained_chunks, trained_at, eval_report_json FROM models WHERE id = ?
            """, [.text(id)]).first else { return nil }
        return ModelRow(id: row[0].text ?? id, manifestJSON: row[1].text, trainedChunks: row[2].int,
                        trainedAt: row[3].text, evalReportJSON: row[4].text)
    }

    public func chunk(id: Int64) throws -> ChunkSummary? {
        try summaries(where: "id = ?", [.int(id)]).first
    }

    public func latest() throws -> ChunkSummary? {
        try summaries(where: "1 = 1 ORDER BY id DESC LIMIT 1", []).first
    }

    public func audio(id: Int64) throws -> (data: Data, format: String, sampleRate: Int)? {
        guard let row = try db.query("SELECT audio, audio_format, audio_sample_rate FROM chunks WHERE id = ?",
                                     [.int(id)]).first else { return nil }
        return (row[0].blob ?? Data(), row[1].text ?? "", Int(row[2].int ?? 0))
    }

    /// Bytes recorded per local day for the last `days` days, oldest first.
    /// Days without recordings are included with 0.
    public func dailyBytes(days: Int, now: Date = Date(), timeZone: TimeZone = .current) throws -> [(day: String, bytes: Int64)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let wanted = (0..<days).reversed().map { offset in
            Timestamps.localDay(calendar.date(byAdding: .day, value: -offset, to: now)!, timeZone: timeZone)
        }
        let rows = try db.query("""
            SELECT local_day, SUM(audio_bytes + LENGTH(COALESCE(raw_text, ''))) FROM chunks
            WHERE local_day >= ? GROUP BY local_day
            """, [.text(wanted.first!)])
        var byDay: [String: Int64] = [:]
        for row in rows {
            if let day = row[0].text { byDay[day] = row[1].int ?? 0 }
        }
        return wanted.map { ($0, byDay[$0] ?? 0) }
    }

    /// Rows still waiting for text, for example because the app quit
    /// before recognition finished.
    public func pendingIDs() throws -> [Int64] {
        try db.query("SELECT id FROM chunks WHERE status = 'pending' ORDER BY id").compactMap { $0[0].int }
    }

    /// Writes a line to the `events` table. Never throws: logging must not
    /// break the thing being logged.
    public func log(_ level: LogLevel, _ category: String, _ message: String, chunkID: Int64? = nil) {
        _ = try? db.query("INSERT INTO events (at, level, category, message, chunk_id) VALUES (?, ?, ?, ?, ?)", [
            .text(Timestamps.string(Date())), .text(level.rawValue), .text(category), .text(message),
            .optional(chunkID),
        ])
    }

    public func count() throws -> Int {
        Int(try db.query("SELECT COUNT(*) FROM chunks").first?.first?.int ?? 0)
    }

    /// Deletes every recording, transcript and label, then shrinks the file.
    /// Trained models are kept.
    public func deleteAllRecordings() throws {
        try db.transaction {
            try db.execute("DELETE FROM events")
            try db.execute("DELETE FROM labels")
            try db.execute("DELETE FROM dataset_days")
            try db.execute("DELETE FROM chunks")
        }
        try db.execute("VACUUM")
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Size on disk: the database file plus its write-ahead log.
    public nonisolated func sizeOnDisk() -> Int64 {
        [path, path + "-wal"].reduce(0) { total, file in
            let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }

    private func summaries(where clause: String, _ values: [SQLValue]) throws -> [ChunkSummary] {
        try db.query("""
            SELECT id, status, error, raw_text, duration_ms, end_reason, ended_at, audio_format,
                audio_sample_rate, audio_bytes FROM chunks WHERE \(clause)
            """, values).map { row in
            ChunkSummary(
                id: row[0].int ?? 0, status: row[1].text ?? "", error: row[2].text, rawText: row[3].text,
                durationMs: row[4].int ?? 0, endReason: row[5].text ?? "",
                endedAt: Timestamps.date(row[6].text ?? "") ?? .distantPast, audioFormat: row[7].text ?? "",
                audioSampleRate: Int(row[8].int ?? 0), audioBytes: row[9].int ?? 0)
        }
    }
}

/// Times are stored as UTC ISO 8601 with milliseconds; days as the local
/// calendar date of the recording.
public enum Timestamps {
    public static func string(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    public static func date(_ string: String) -> Date? {
        try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
    }

    public static func localDay(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

/// Turns a thought into text. One per thought: it's fed audio while the
/// thought is in progress, then asked for the final text.
public protocol ThoughtTranscription: Sendable {
    /// Which engine produced the text, stored with the row.
    var recognizer: String { get }
    /// The final text for the audio up to `seconds` from the thought's
    /// first sample (the pre-roll included).
    func finish(through seconds: Double) async throws -> String
    /// Stops recognition that has taken too long.
    func cancel()
}

extension ThoughtTranscription {
    public func cancel() {}
}

public enum LogLevel: String, Sendable {
    case info, warning, error
}

/// Runs `operation`, but gives up after `limit` seconds even if the
/// operation ignores cancellation (a task group would wait for it).
func firstOf<T: Sendable>(limit: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = ResumeOnce<T>()
    return try await withCheckedThrowingContinuation { continuation in
        once.attach(continuation)
        let work = Task {
            do { once.resume(.success(try await operation())) } catch { once.resume(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: .seconds(limit))
            if once.resume(.failure(TranscriptionTimeout(seconds: limit))) { work.cancel() }
        }
    }
}

final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    /// Returns true if this call was the one that resumed.
    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        let taken: CheckedContinuation<T, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(with: result)
        return taken != nil
    }
}

struct TranscriptionTimeout: Error, CustomStringConvertible {
    let seconds: Double
    var description: String {
        "Speech recognition didn't finish within \(Int(seconds)) s, so it was stopped. The audio is kept."
    }
}

/// The production save path: audio first, then text.
/// Recognition of audio that's already saved: decodes the row's audio and
/// runs it through a fresh transcription.
public struct SavedAudioTranscription: ThoughtTranscription {
    public let recognizer: String
    let make: @Sendable (Double) -> SpeechSession
    let samples: [Float]
    let sampleRate: Double

    public init(samples: [Float], sampleRate: Double, recognizer: String,
                make: @escaping @Sendable (Double) -> SpeechSession) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.recognizer = recognizer
        self.make = make
    }

    public func finish(through seconds: Double) async throws -> String {
        let session = make(sampleRate)
        session.append(samples)
        return try await withTaskCancellationHandler {
            try await session.finish(through: seconds)
        } onCancel: {
            session.cancel()
        }
    }
}

public struct ChunkRecorder: Sendable {
    public let store: ChunkStore
    /// How long recognition may take after the audio is in: a fixed part
    /// plus one second per second of audio. Nothing stays pending forever.
    public var timeLimit: @Sendable (_ audioSeconds: Double) -> Double = { 20 + $0 }

    public init(store: ChunkStore) {
        self.store = store
    }

    /// Encodes and saves the audio as a pending row, then waits for the text
    /// and marks the row transcribed or error. Returns the row ID, or nil if
    /// even the pending row couldn't be written.
    @discardableResult
    public func record(_ thought: CapturedThought, meta: ChunkMeta, transcription: (any ThoughtTranscription)?,
                       saved: (@Sendable (Int64) -> Void)? = nil) async -> Int64? {
        let audio = AudioEncoding.encode(samples: thought.samples, sampleRate: thought.sampleRate)
        let durationMs = Int64((thought.duration * 1000).rounded())
        let id: Int64
        do {
            id = try await store.insertPending(meta: meta, audio: audio, durationMs: durationMs)
        } catch {
            await store.log(.error, "save", "Couldn't save a \(durationMs) ms thought: \(error)")
            return nil
        }
        await store.log(.info, "save", "Saved \(durationMs) ms of audio (\(audio.data.count) bytes \(audio.format)), "
            + "started by \(thought.startReason.rawValue), ended by \(thought.endReason.rawValue)", chunkID: id)
        saved?(id)
        guard let transcription else {
            try? await store.markError(id: id, message: "No speech recognizer was running for this thought.")
            await store.log(.warning, "speech", "No recognizer for this thought", chunkID: id)
            return id
        }
        await transcribe(id: id, transcription: transcription, through: thought.duration)
        return id
    }

    /// Finishes a pending row: waits for the text, up to the time limit,
    /// and marks it transcribed or error.
    public func transcribe(id: Int64, transcription: any ThoughtTranscription, through seconds: Double) async {
        let limit = timeLimit(seconds)
        let started = ContinuousClock.now
        do {
            let text = try await firstOf(limit: limit) {
                try await transcription.finish(through: seconds)
            }
            try await store.markTranscribed(id: id, text: text, recognizer: transcription.recognizer)
            let took = (ContinuousClock.now - started).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
            await store.log(.info, "speech", "Transcribed \(text.count) characters in \(took)", chunkID: id)
        } catch let timeout as TranscriptionTimeout {
            transcription.cancel()
            try? await store.markError(id: id, message: timeout.description)
            await store.log(.error, "speech", timeout.description, chunkID: id)
        } catch {
            try? await store.markError(id: id, message: "Speech recognition failed: \(error)")
            await store.log(.error, "speech", "Recognition failed: \(error)", chunkID: id)
        }
    }

    /// Rows left pending by a quit or crash: recognise their saved audio
    /// again. Rows whose audio can't be read are marked error.
    public func finishPending(locale: Locale) async {
        let ids: [Int64]
        do {
            ids = try await store.pendingIDs()
        } catch {
            await store.log(.error, "recovery", "Couldn't look for pending thoughts: \(error)")
            return
        }
        await store.log(.info, "recovery", "Found \(ids.count) thought(s) left pending")
        for id in ids {
            guard let audio = try? await store.audio(id: id),
                  let samples = try? AudioEncoding.decode(audio.data, format: audio.format, sampleRate: audio.sampleRate)
            else {
                try? await store.markError(id: id, message: "The app stopped before recognition finished, and the audio couldn't be read.")
                await store.log(.error, "recovery", "Couldn't read the saved audio", chunkID: id)
                continue
            }
            await store.log(.info, "recovery", "Recognising \(samples.count) saved samples at \(audio.sampleRate) Hz", chunkID: id)
            let rate = Double(audio.sampleRate)
            let transcription = SavedAudioTranscription(
                samples: samples, sampleRate: rate,
                recognizer: "SpeechTranscriber \(locale.identifier) (after restart)",
                make: { SpeechSession(locale: locale, sampleRate: $0, onText: { _ in }) })
            await transcribe(id: id, transcription: transcription, through: Double(samples.count) / rate)
        }
    }
}
