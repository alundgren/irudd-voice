import Foundation

/// A word-by-word comparison of what was heard and what was pasted, for the
/// Transcript preview. Words match when they're the same after lowercasing
/// and dropping punctuation, so "um," and "Um" match, and "fifteen" and
/// "fifty" don't.
public enum WordDiff {
    public struct Word: Equatable, Sendable {
        public var text: String
        /// False: removed (in the heard text) or added (in the pasted text).
        public var kept: Bool

        public init(_ text: String, kept: Bool) {
            self.text = text
            self.kept = kept
        }
    }

    /// Each side's words, marked kept or not, using the longest common
    /// sequence of words. Punctuation-only words ("—") count as kept.
    public static func compare(heard: String, pasted: String) -> (heard: [Word], pasted: [Word]) {
        let a = heard.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = pasted.split(whereSeparator: \.isWhitespace).map(String.init)
        let keyA = a.map(key)
        let keyB = b.map(key)
        // A thought too long to compare quickly (over a million word pairs)
        // shows every word as kept.
        guard a.count * b.count <= 1_000_000 else {
            return (a.map { Word($0, kept: true) }, b.map { Word($0, kept: true) })
        }
        // lengths[i][j]: longest common sequence of keyA[i...] and keyB[j...].
        let width = b.count + 1
        var lengths = [Int32](repeating: 0, count: (a.count + 1) * width)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i * width + j] = keyA[i] == keyB[j]
                    ? lengths[(i + 1) * width + j + 1] + 1
                    : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }
        var keptA = [Bool](repeating: false, count: a.count)
        var keptB = [Bool](repeating: false, count: b.count)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if keyA[i] == keyB[j] {
                keptA[i] = true
                keptB[j] = true
                i += 1
                j += 1
            } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (zip(a, keptA).map { Word($0, kept: $1 || keyOf($0).isEmpty) },
                zip(b, keptB).map { Word($0, kept: $1 || keyOf($0).isEmpty) })
    }

    /// The comparison key. Punctuation-only words get a key that never
    /// matches, and are marked kept afterwards.
    private static func key(_ word: String) -> String {
        let key = keyOf(word)
        return key.isEmpty ? "\u{0}" + word : key
    }

    private static func keyOf(_ word: String) -> String {
        String(String.UnicodeScalarView(word.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }))
    }
}
