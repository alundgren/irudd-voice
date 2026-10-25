import Foundation

/// Splits a long thought into pieces the cleanup model can finish within
/// its deadline (`generation.timeout_seconds`, 5 s per piece). Each piece is
/// cleaned on its own, in order, and the cleaned pieces are joined with a
/// space and pasted once.
///
/// Pieces end at sentence ends where possible. A sentence longer than a
/// piece is split after a comma, semicolon, colon or dash, and a clause
/// that's still too long is cut at the word limit.
public enum ThoughtPieces {
    /// The most words in one piece. Gemma 4 E2B (the default model) cleans a
    /// 50-word thought warm in 1.22 s (p50) and 1.39 s (p90) on a MacBook Air
    /// M5 (docs/models/swift-bench.md). In `voice-model-tool thought-check`,
    /// pieces of 99 and 105 words took 1.92 s and 1.85 s, so a 120-word piece
    /// takes about 2.2 s: well inside 5 s, with room for a slower Mac. The
    /// prompt's own forward pass can't be stopped at the deadline, so pieces
    /// must stay small enough to finish anyway.
    public static let maxWords = 120

    /// The pieces of `text`, in order. A thought of `maxWords` words or fewer
    /// is one piece: the text as it is, trimmed.
    public static func split(_ text: String, maxWords: Int = maxWords) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > maxWords else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        // Units no longer than a piece: whole sentences, or the clauses (or
        // word-limit cuts) of a sentence that's too long.
        var units: [[String]] = []
        for sentence in runs(words, endingAt: endsSentence) {
            if sentence.count <= maxWords {
                units.append(sentence)
                continue
            }
            for clause in runs(sentence, endingAt: endsClause) {
                stride(from: 0, to: clause.count, by: maxWords).forEach {
                    units.append(Array(clause[$0..<min($0 + maxWords, clause.count)]))
                }
            }
        }
        // Fill each piece with as many whole units as fit.
        var pieces: [[String]] = []
        var current: [String] = []
        for unit in units {
            if !current.isEmpty && current.count + unit.count > maxWords {
                pieces.append(current)
                current = []
            }
            current += unit
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.map { $0.joined(separator: " ") }
    }

    /// Splits `words` after each word where `endsRun` is true.
    static func runs(_ words: [String], endingAt endsRun: (String) -> Bool) -> [[String]] {
        var runs: [[String]] = []
        var current: [String] = []
        for word in words {
            current.append(word)
            if endsRun(word) {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Closing quotes and brackets that can follow a sentence's last mark.
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]"]

    private static func lastMark(_ word: String) -> Character? {
        word.reversed().first { !closers.contains($0) }
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let mark = lastMark(word) else { return false }
        return mark == "." || mark == "?" || mark == "!" || mark == "…"
    }

    static func endsClause(_ word: String) -> Bool {
        if word == "-" || word == "–" || word == "—" { return true }
        guard let mark = lastMark(word) else { return false }
        return mark == "," || mark == ";" || mark == ":" || mark == "—" || mark == "–"
    }
}
