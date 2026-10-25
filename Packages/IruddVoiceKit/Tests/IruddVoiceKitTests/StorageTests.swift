import Foundation
import Testing
@testable import IruddVoiceKit

func temporaryDatabasePath() -> String {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("irudd-voice-tests-\(UUID().uuidString)")
    return folder.appendingPathComponent("voice.sqlite").path
}

/// A transcriber that answers late, like Apple's does after finalize.
final class SlowTranscription: ThoughtTranscription, @unchecked Sendable {
    let recognizer = "fake"
    let text: String
    let delay: Duration
    let fails: Bool
    init(text: String, delay: Duration = .milliseconds(300), fails: Bool = false) {
        self.text = text
        self.delay = delay
        self.fails = fails
    }
    func finish(through seconds: Double) async throws -> String {
        try await Task.sleep(for: delay)
        if fails { throw SpeechSetupError.assetsMissing }
        return text
    }
}

func tone(seconds: Double, rate: Double = 48_000) -> [Float] {
    (0..<Int(seconds * rate)).map { Float(sin(Double($0) * 2 * .pi * 220 / rate)) * 0.3 }
}

func thought(seconds: Double, rate: Double = 48_000) -> CapturedThought {
    CapturedThought(samples: tone(seconds: seconds, rate: rate), sampleRate: rate, firstSample: 0,
                    signalSample: Int64(2 * rate), startReason: .unmute, endReason: .muteButton)
}

func meta(for thought: CapturedThought) -> ChunkMeta {
    ChunkMeta(thought: thought, signalAt: Date(), micUID: "BOYA-1", micName: "BY-GM18CU",
              micModelUID: "BY-GM18CU:0002:0005", targetAppBundleID: "com.example.editor",
              targetAppName: "Editor", appVersion: "test")
}

struct StorageTests {
    @Test func schemaIsCreatedOnceWithEveryTable() throws {
        let path = temporaryDatabasePath()
        let db = try Schema.open(path: path)
        #expect(try db.userVersion == 1)
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").compactMap { $0[0].text }
        #expect(tables == ["active_model", "app_state", "chunks", "dataset_days", "events", "labels", "models"])
        #expect(try db.query("PRAGMA journal_mode").first?.first?.text == "wal")
        // Opening again doesn't migrate twice.
        _ = try Schema.open(path: path)
    }

    @Test func refusesANewerDatabase() throws {
        let path = temporaryDatabasePath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let db = try Database(path: path)
        try db.execute("PRAGMA user_version = 7")
        #expect(throws: DatabaseError.self) { try Schema.open(path: path) }
    }

    @Test func flacKeepsTheLength() throws {
        let samples = tone(seconds: 3.2)
        let encoded = AudioEncoding.encode(samples: samples, sampleRate: 48_000)
        #expect(encoded.format == "flac")
        #expect(encoded.sampleRate == 16_000)
        #expect(String(decoding: encoded.data.prefix(4), as: UTF8.self) == "fLaC")
        let decoded = try AudioEncoding.decode(encoded.data, format: encoded.format, sampleRate: encoded.sampleRate)
        #expect(abs(Double(decoded.count) / 16_000 - 3.2) < 0.05)
        // Much smaller than the raw floats.
        #expect(encoded.data.count < samples.count * 4 / 4)
    }

    @Test func audioIsSavedBeforeTheTextArrives() async throws {
        let store = try ChunkStore(path: temporaryDatabasePath())
        let recorder = ChunkRecorder(store: store)
        let captured = thought(seconds: 4)
        let savedID = OSAllocatedUnfairLockBox<Int64?>(nil)

        let task = Task {
            await recorder.record(captured, meta: meta(for: captured),
                                  transcription: SlowTranscription(text: "change the timeout", delay: .milliseconds(500)),
                                  saved: { savedID.set($0) })
        }
        // While the fake transcriber is still thinking, the row is pending with audio.
        try await Task.sleep(for: .milliseconds(250))
        let id = try #require(savedID.get())
        let pending = try #require(try await store.chunk(id: id))
        #expect(pending.status == "pending")
        #expect(pending.rawText == nil)
        #expect(pending.audioBytes > 0)

        _ = await task.value
        let done = try #require(try await store.chunk(id: id))
        #expect(done.status == "transcribed")
        #expect(done.rawText == "change the timeout")
        #expect(done.durationMs == 4000)
    }

    @Test func failedRecognitionKeepsTheAudio() async throws {
        let store = try ChunkStore(path: temporaryDatabasePath())
        let recorder = ChunkRecorder(store: store)
        let captured = thought(seconds: 1.5)
        let id = try #require(await recorder.record(captured, meta: meta(for: captured),
                                                     transcription: SlowTranscription(text: "", fails: true)))
        let row = try #require(try await store.chunk(id: id))
        #expect(row.status == "error")
        #expect(row.error?.contains("speech files") == true)
        let audio = try #require(try await store.audio(id: id))
        let decoded = try AudioEncoding.decode(audio.data, format: audio.format, sampleRate: audio.sampleRate)
        #expect(abs(Double(decoded.count) / Double(audio.sampleRate) - 1.5) < 0.05)
    }

    @Test func recognitionThatNeverAnswersTimesOut() async throws {
        let path = temporaryDatabasePath()
        let store = try ChunkStore(path: path)
        var recorder = ChunkRecorder(store: store)
        recorder.timeLimit = { _ in 0.3 }
        let captured = thought(seconds: 1)
        let started = ContinuousClock.now
        let id = try #require(await recorder.record(captured, meta: meta(for: captured),
                                                     transcription: HangingTranscription()))
        #expect(ContinuousClock.now - started < .seconds(3))
        let row = try #require(try await store.chunk(id: id))
        #expect(row.status == "error")
        #expect(row.error?.contains("didn't finish") == true)
        #expect(try await store.audio(id: id)?.data.isEmpty == false)

        let events = try Database(path: path).query("SELECT level, category, message FROM events ORDER BY id")
        #expect(events.map { $0[1].text } == ["save", "speech"])
        #expect(events.last?[0].text == "error")
    }

    @Test func storesWhereAndWhen() async throws {
        let path = temporaryDatabasePath()
        let store = try ChunkStore(path: path)
        let captured = thought(seconds: 1)
        var info = meta(for: captured)
        info.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        info.startedAt = try Date("2026-10-24T22:30:00Z", strategy: .iso8601)
        _ = try await store.insertPending(meta: info, audio: AudioEncoding.encode(samples: captured.samples,
                                                                                    sampleRate: 48_000), durationMs: 1000)
        let db = try Database(path: path)
        let row = try #require(try db.query("""
            SELECT local_day, utc_offset_minutes, mic_uid, target_app_bundle_id, schema_version, app_version
            FROM chunks
            """).first)
        // 22:30 UTC is already the next day in Stockholm.
        #expect(row[0].text == "2026-10-25")
        #expect(row[1].int == 120)
        #expect(row[2].text == "BOYA-1")
        #expect(row[3].text == "com.example.editor")
        #expect(row[4].int == 1)
        #expect(row[5].text == "test")
    }

    @Test func dailyBytesCoverSevenDays() async throws {
        let store = try ChunkStore(path: temporaryDatabasePath())
        let captured = thought(seconds: 1)
        _ = try await store.insertPending(meta: meta(for: captured),
                                          audio: AudioEncoding.encode(samples: captured.samples, sampleRate: 48_000),
                                          durationMs: 1000)
        let days = try await store.dailyBytes(days: 7)
        #expect(days.count == 7)
        #expect(days.last!.bytes > 0)
        #expect(days.dropLast().allSatisfy { $0.bytes == 0 })
    }

    @Test func deleteAllEmptiesTheTables() async throws {
        let store = try ChunkStore(path: temporaryDatabasePath())
        let recorder = ChunkRecorder(store: store)
        let captured = thought(seconds: 1)
        _ = await recorder.record(captured, meta: meta(for: captured), transcription: nil)
        #expect(try await store.count() == 1)
        try await store.deleteAllRecordings()
        #expect(try await store.count() == 0)
    }
}

/// Never answers and ignores cancellation, like a stuck recognizer.
struct HangingTranscription: ThoughtTranscription {
    let recognizer = "hangs"
    func finish(through seconds: Double) async throws -> String {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        return ""
    }
}

/// Tiny thread-safe box for test callbacks.
final class OSAllocatedUnfairLockBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ newValue: T) { lock.withLock { value = newValue } }
    func get() -> T { lock.withLock { value } }
}
