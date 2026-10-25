import AVFoundation
import CoreMedia
import Foundation
import os
import Speech

public enum SpeechSetupError: Error, CustomStringConvertible {
    case assetsMissing
    case unsupportedLocale

    public var description: String {
        switch self {
        case .assetsMissing: "Apple's English speech files aren't installed. Install them in setup."
        case .unsupportedLocale: "English speech recognition isn't available on this Mac."
        }
    }
}

/// Apple's English speech files (SpeechTranscriber assets).
public enum SpeechAssets {
    /// English only. Uses your English variant if you have one, else US English.
    public static func locale() async -> Locale? {
        let current = Locale.current
        if current.language.languageCode == .english,
           let match = await SpeechTranscriber.supportedLocale(equivalentTo: current) {
            return match
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
    }

    public static func isInstalled() async -> Bool {
        guard let locale = await locale() else { return false }
        return await AssetInventory.status(forModules: [SpeechSession.makeTranscriber(locale: locale)]) == .installed
    }

    /// Downloads and installs the files, reporting progress from 0 to 1.
    public static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let locale = await locale() else { throw SpeechSetupError.unsupportedLocale }
        let transcriber = SpeechSession.makeTranscriber(locale: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            progress(1)
            return
        }
        let watcher = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }
}

/// Live recognition of one thought with SpeechAnalyzer and SpeechTranscriber.
/// Feed it audio while the thought is in progress; volatile (changing) text
/// is reported for the preview. `finish(through:)` returns the final text.
public final class SpeechSession: ThoughtTranscription, @unchecked Sendable {
    public let recognizer: String
    private let continuation: AsyncStream<[Float]>.Continuation
    private let work: Task<String, Error>
    private let endTime = OSAllocatedUnfairLock<Double?>(initialState: nil)

    /// - Parameters:
    ///   - sampleRate: rate of the samples passed to `append`.
    ///   - onText: the text so far (final plus volatile), whenever it changes.
    public init(locale: Locale, sampleRate: Double, onText: @escaping @Sendable (String) -> Void) {
        recognizer = "SpeechTranscriber \(locale.identifier) macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        let (samples, continuation) = AsyncStream<[Float]>.makeStream()
        self.continuation = continuation
        let endTime = self.endTime
        work = Task {
            try await Self.run(samples: samples, locale: locale, sampleRate: sampleRate, endTime: endTime, onText: onText)
        }
    }

    /// Audio for this thought, in order, starting with the pre-roll.
    public func append(_ samples: [Float]) {
        continuation.yield(samples)
    }

    public func finish(through seconds: Double) async throws -> String {
        endTime.withLock { $0 = seconds }
        continuation.finish()
        return try await work.value
    }

    /// Stops without waiting for text.
    public func cancel() {
        continuation.finish()
        work.cancel()
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        // No etiquette replacements: keep exactly what was said.
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                          attributeOptions: [])
    }

    private static func run(samples: AsyncStream<[Float]>, locale: Locale, sampleRate: Double,
                            endTime: OSAllocatedUnfairLock<Double?>,
                            onText: @escaping @Sendable (String) -> Void) async throws -> String {
        let transcriber = makeTranscriber(locale: locale)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw SpeechSetupError.assetsMissing
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
        let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputs)

        let results = Task {
            var final = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    final += text
                    onText(final)
                } else {
                    onText(final + text)
                }
            }
            return final
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        var total = 0
        do {
            for await chunk in samples where !chunk.isEmpty {
                for input in try converter.convert(AudioEncoding.buffer(chunk, format: format), at: nil) {
                    inputContinuation.yield(input)
                }
                total += chunk.count
            }
            for input in try converter.flush() {
                inputContinuation.yield(input)
            }
            inputContinuation.finish()

            // Final results only for the thought's own audio; anything streamed
            // after its end (the mute's own silence) is dropped.
            let through = min(endTime.withLock { $0 } ?? .infinity, Double(total) / sampleRate)
            try await analyzer.finalizeAndFinish(through: CMTime(seconds: through, preferredTimescale: 48_000))
        } catch {
            inputContinuation.finish()
            await analyzer.cancelAndFinishNow()
            results.cancel()
            throw error
        }
        return try await results.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
