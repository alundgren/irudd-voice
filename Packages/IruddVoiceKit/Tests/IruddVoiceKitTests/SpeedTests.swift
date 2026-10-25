import Foundation
import Testing
@testable import IruddVoiceKit

/// The audio path has to keep up with a real 48 kHz mic, however long you
/// talk. These run at full rate, unlike the 1 kHz logic tests.
struct SpeedTests {
    func timeToProcess(seconds: Double) -> Duration {
        let rate = 48_000.0
        let d = ThoughtDetector(sampleRate: rate)
        let chunk = (0..<960).map { Float(sin(Double($0) * 0.05)) * 0.3 } // 20 ms, like the capture timer
        let muted = [Float](repeating: 0, count: 960)
        let clock = ContinuousClock()
        return clock.measure {
            for _ in 0..<100 { _ = d.process(chunk) }   // 2 s of sound
            for _ in 0..<50 { _ = d.process(muted) }    // mute
            for _ in 0..<Int(seconds * 50) { _ = d.process(chunk) } // unmute and talk
            _ = d.process([Float](repeating: 0, count: 24_000))     // mute again
        }
    }

    @Test func detectorKeepsUpWithALongThought() {
        let elapsed = timeToProcess(seconds: 60)
        // A minute of audio must take a small fraction of a minute.
        #expect(elapsed < .seconds(3), "processing 60 s of audio took \(elapsed)")
    }

    @Test func costGrowsLinearlyWithLength() {
        let short = timeToProcess(seconds: 5)
        let long = timeToProcess(seconds: 20)
        // 4x the audio should take about 4x the time, not 16x.
        #expect(long < short * 8, "5 s took \(short), 20 s took \(long)")
    }

    @Test func savingAMinuteIsQuick() {
        let rate = 48_000.0
        let samples = (0..<Int(60 * rate)).map { Float(sin(Double($0) * 0.05)) * 0.3 }
        let elapsed = ContinuousClock().measure {
            _ = AudioEncoding.encode(samples: samples, sampleRate: rate)
        }
        #expect(elapsed < .seconds(1), "encoding 60 s of audio took \(elapsed)")
    }
}
