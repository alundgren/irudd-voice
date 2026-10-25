// Drives the app's database code for cross-language tests.
//
//   voice-db-tool create PATH
//   voice-db-tool record PATH COUNT SECONDS DELAY_MS   save thoughts through the
//                                                      app's save path with a fake
//                                                      transcriber that answers late
//   voice-db-tool write-state PATH COUNT              COUNT separate app_state writes
//   voice-db-tool set-version PATH VERSION

import Foundation
import IruddVoiceKit

struct LateTranscription: ThoughtTranscription {
    let recognizer = "voice-db-tool fake"
    let text: String
    let delayMs: Int
    func finish(through seconds: Double) async throws -> String {
        try await Task.sleep(for: .milliseconds(delayMs))
        return text
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("voice-db-tool: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments.dropFirst()
guard let command = args.first, args.count >= 2 else {
    fail("usage: voice-db-tool create|record|write-state|set-version PATH …")
}
let path = args[args.startIndex + 1]
let rest = Array(args.dropFirst(2))

do {
    switch command {
    case "create":
        _ = try Schema.open(path: path)

    case "record":
        guard rest.count == 3, let count = Int(rest[0]), let seconds = Double(rest[1]), let delay = Int(rest[2]) else {
            fail("record PATH COUNT SECONDS DELAY_MS")
        }
        let recorder = ChunkRecorder(store: try ChunkStore(path: path))
        let rate = 48_000.0
        for index in 0..<count {
            let samples = (0..<Int(seconds * rate)).map { Float(sin(Double($0) * 2 * .pi * 330 / rate)) * 0.25 }
            let thought = CapturedThought(samples: samples, sampleRate: rate, firstSample: 0,
                                          signalSample: Int64(2 * rate), startReason: .unmute, endReason: .muteButton)
            let meta = ChunkMeta(thought: thought, signalAt: Date(), micUID: "TEST-MIC", micName: "Test mic",
                                 micModelUID: nil, targetAppBundleID: nil, targetAppName: nil, appVersion: "voice-db-tool")
            let id = await recorder.record(thought, meta: meta,
                                           transcription: LateTranscription(text: "test thought \(index)", delayMs: delay),
                                           saved: { print("saved \($0)") })
            guard let id else { fail("couldn't save thought \(index)") }
            print("transcribed \(id)")
        }

    case "write-state":
        guard let count = rest.first.flatMap(Int.init) else { fail("write-state PATH COUNT") }
        let db = try Schema.open(path: path)
        for index in 0..<count {
            try db.transaction {
                try db.query("INSERT INTO app_state (key, value, updated_at) VALUES (?, ?, ?)",
                             [.text("app-\(index)"), .text("\(index)"), .text(Timestamps.string(Date()))])
            }
        }

    case "set-version":
        guard let version = rest.first.flatMap(Int.init) else { fail("set-version PATH VERSION") }
        let db = try Database(path: path)
        try db.execute("PRAGMA user_version = \(version)")

    default:
        fail("unknown command \(command)")
    }
} catch {
    fail("\(error)")
}
