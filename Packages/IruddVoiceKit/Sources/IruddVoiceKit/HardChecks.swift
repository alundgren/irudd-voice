import Foundation

/// A parsed model reply: the cleaned text, or why it can't be used.
public struct CleanupReply: Equatable, Sendable {
    public enum Failure: String, Codable, Sendable {
        case thinkTags = "think_tags"
        case cutOff = "cut_off"
        case malformed
    }

    public var cleaned: String?
    public var failure: Failure?

    /// Reads the model's raw reply (shared/README.md "Reading the reply").
    /// `hitLimit` is true when generation stopped because it reached max_tokens.
    public static func parse(_ text: String, hitLimit: Bool = false, key: String = "cleaned") -> CleanupReply {
        // Searched as UTF-8 bytes: String.contains compares whole characters,
        // so it would miss "<think>" followed by a combining mark.
        let bytes = Array(text.utf8)
        if HardChecks.thinkTags.contains(where: { bytes.contains(subsequence: Array($0.utf8)) }) {
            return CleanupReply(cleaned: nil, failure: .thinkTags)
        }
        var stripped = HardChecks.strip(text)
        // Some models wrap JSON in a ``` fence; accept that, nothing else.
        if let fence = HardChecks.fence.firstMatch(in: stripped) {
            stripped = HardChecks.strip(fence[1])
        }
        guard let value = StrictJSON.parse(stripped) else {
            return CleanupReply(cleaned: nil, failure: hitLimit ? .cutOff : .malformed)
        }
        guard case .object(let object) = value, case .string(let cleaned)? = object[key] else {
            return CleanupReply(cleaned: nil, failure: .malformed)
        }
        return CleanupReply(cleaned: HardChecks.strip(cleaned), failure: nil)
    }
}

/// Hard checks: does a cleaned text keep what the speaker said?
///
/// A port of cli/src/irudd_voice/hardchecks.py. Both must agree on every case
/// in shared/fixtures/hard-checks.json; the exact rules are in shared/README.md
/// ("Hard checks"). A failing check means the raw transcript is pasted instead.
public enum HardChecks {
    /// The order failures are reported in. Fixtures compare lists exactly.
    public static let checkOrder = ["dropped", "answers", "question", "numbers", "negation", "identifiers", "new_words"]

    // The word lists below are copied from hardchecks.py; keep them identical.

    static let answerOpeners = [
        "sure", "certainly", "of course", "absolutely", "here is", "here's", "here are",
        "i'd be happy", "i would be happy", "i can help", "as an ai", "great question",
        "the answer is", "to do this", "you can",
    ]

    static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "er", "erm", "hmm", "so", "okay", "ok", "well", "like",
        "yeah", "alright", "basically", "just", "right", "actually", "you know", "i mean",
        "kind of", "sort of",
    ]

    static let correctionMarkers = ["no", "sorry", "i mean", "scratch that", "not that", "make that", "or rather"]

    static let negations: Set<String> = [
        "no", "not", "never", "cannot", "without", "nothing", "nobody", "none", "neither", "nor",
        "don't", "doesn't", "didn't", "isn't", "aren't", "wasn't", "weren't", "can't", "won't",
        "wouldn't", "shouldn't", "couldn't", "haven't", "hasn't", "hadn't", "mustn't",
        "needn't", "dont", "doesnt", "didnt", "isnt", "arent", "cant", "wont",
    ]

    static let functionWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "at", "for", "with",
        "is", "are", "be", "it", "its", "this", "that", "these", "those", "then", "so", "as",
        "if", "do", "does", "please", "also", "s", "i", "you", "we",
    ]

    static let helperVerbs: Set<String> = [
        "can", "could", "would", "should", "is", "are", "was", "were", "do", "does", "did",
        "have", "has", "will", "shall", "may",
    ]
    static let pronouns: Set<String> = ["you", "i", "we", "it", "this", "that", "there", "they", "he", "she"]
    // "do it now" and "have it run on CI" are commands; "do you…" is a question.
    static let persons: Set<String> = ["you", "i", "we", "they", "he", "she"]
    static let questionWords: Set<String> = ["what", "why", "how", "when", "where", "which", "who"]

    static let hedges: Set<String> = ["maybe", "probably", "perhaps", "wondering", "whether", "trying", "say", "saying", "guess", "really"]

    static let contractions: [String: String] = [
        "don't": "do not", "doesn't": "does not", "didn't": "did not", "isn't": "is not",
        "aren't": "are not", "wasn't": "was not", "weren't": "were not", "can't": "can not",
        "cannot": "can not", "won't": "will not", "wouldn't": "would not",
        "shouldn't": "should not", "couldn't": "could not", "haven't": "have not",
        "hasn't": "has not", "hadn't": "had not", "it's": "it is", "that's": "that is",
        "there's": "there is", "what's": "what is", "let's": "let us", "i'm": "i am",
        "you're": "you are", "we're": "we are", "they're": "they are", "i've": "i have",
        "we've": "we have", "you've": "you have", "i'll": "i will", "we'll": "we will",
        "you'll": "you will", "i'd": "i would", "we'd": "we would",
    ]

    static let numberWords: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let scales: [String: Int] = ["hundred": 100, "thousand": 1000, "million": 1_000_000]

    // Thinking markers: Qwen (<think>) and Gemma 4 (<|channel>thought … <channel|>, <|think|>).
    static let thinkTags = ["<think>", "</think>", "<|channel>", "<channel|>", "<|think|>"]

    static let stemSuffixes = ["ing", "ed", "es", "s"]

    // ---- Text helpers ----------------------------------------------------------

    /// The characters Python's `str.isspace()` accepts, which `str.strip()`
    /// removes (shared/README.md). Foundation's whitespace set differs
    /// (it lacks U+001C–U+001F, for one).
    static let pythonWhitespace: Set<UInt32> = [
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
    ]

    static func isPythonWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        pythonWhitespace.contains(scalar.value)
    }

    /// Python's `str.strip()`.
    static func strip(_ text: String) -> String {
        var scalars = text.unicodeScalars[...]
        while let first = scalars.first, isPythonWhitespace(first) { scalars = scalars.dropFirst() }
        while let last = scalars.last, isPythonWhitespace(last) { scalars = scalars.dropLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Python's `str.rstrip()`.
    static func rstrip(_ text: String) -> String {
        var scalars = text.unicodeScalars[...]
        while let last = scalars.last, isPythonWhitespace(last) { scalars = scalars.dropLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Python's `\s` (the same characters as `str.isspace()`); ICU's `\s` differs.
    static let pythonSpaceClass = "[" + pythonWhitespace.sorted().map { String(format: "\\x{%X}", $0) }.joined() + "]"
    static let fence = Pattern(#"\A```(?:json)?"# + pythonSpaceClass + "*(.*?)" + pythonSpaceClass + "*```\\z", dotAll: true)
    static let wordPattern = Pattern("[a-z0-9]+(?:'[a-z]+)?")
    static let identifierPattern = Pattern(
        "[A-Za-z_][A-Za-z0-9_]*(?:[._/-][A-Za-z0-9_]+)+"  // dotted, slashed, snake, kebab
            + "|[a-z]+[A-Z][A-Za-z0-9]*"  // camelCase
            + "|[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*"  // PascalCase with a hump
            + "|[A-Za-z]+[0-9]+[A-Za-z0-9]*"  // letters then digits
    )
    static let digitRun = Pattern("[0-9]+")

    static func isDigits(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    static func hasDigit(_ token: String) -> Bool {
        token.utf8.contains { $0 >= 48 && $0 <= 57 }
    }

    /// A digit string as Python's `str(int(token))` writes it: no leading zeros.
    static func decimal(_ digits: String) -> String {
        let trimmed = digits.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    // ---- Tokens ----------------------------------------------------------------

    /// Lowercase ASCII words; an apostrophe joins a following letter run
    /// ("don't"). Everything else (punctuation, symbols, non-ASCII letters)
    /// separates words.
    public static func words(_ text: String) -> [String] {
        wordPattern.matches(in: text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'"))
    }

    static func expand(_ tokens: [String]) -> [String] {
        tokens.flatMap { word in
            (contractions[word] ?? word).split(separator: " ").map(String.init)
        }
    }

    static func stem(_ word: String) -> String {
        for suffix in stemSuffixes where word.hasSuffix(suffix) && word.count > suffix.count + 2 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    /// Drops leading filler words and two-word fillers ("you know").
    static func stripFillers(_ tokens: [String]) -> [String] {
        var index = 0
        while index < tokens.count {
            if fillers.contains(tokens[index]) {
                index += 1
            } else if index + 1 < tokens.count && fillers.contains("\(tokens[index]) \(tokens[index + 1])") {
                index += 2
            } else {
                break
            }
        }
        return Array(tokens[index...])
    }

    // ---- Numbers ---------------------------------------------------------------

    /// A number found in a word list, as a decimal string, with its word span.
    /// `value` is nil for an unusable spelled-out number (over 2^53), which
    /// matches nothing.
    struct FoundNumber: Equatable {
        var value: String?
        var first: Int
        var last: Int
    }

    /// Spelled-out numbers above this are unusable (shared/README.md). Digit
    /// strings have no limit: they compare as decimal strings.
    static let spelledLimit = 1 << 53

    /// Every number written as digits, digits inside a word ("T3"), or spelled
    /// out ("one thousand two hundred", "a hundred", "twenty five").
    static func numbers(in tokens: [String]) -> [String?] {
        numbersWithPositions(tokens).map(\.value)
    }

    /// Like `numbers(in:)`, with each number's word span.
    static func numbersWithPositions(_ tokens: [String]) -> [FoundNumber] {
        var found: [FoundNumber] = []
        var total = 0  // completed thousands/millions
        var current: Int?  // the part under the current scale
        var unusable = false
        var first = -1
        var last = -1

        func flush() {
            if current != nil || total != 0 || unusable {
                let value = total + (current ?? 0)
                found.append(FoundNumber(value: unusable || value > spelledLimit ? nil : String(value), first: first, last: last))
            }
            total = 0
            current = nil
            unusable = false
            first = -1
            last = -1
        }

        func begin(_ index: Int) {
            if first < 0 { first = index }
            last = index
        }

        for (index, token) in tokens.enumerated() {
            if isDigits(token) {
                flush()
                found.append(FoundNumber(value: decimal(token), first: index, last: index))
            } else if hasDigit(token) {
                flush()
                for run in digitRun.matches(in: token) {
                    found.append(FoundNumber(value: decimal(run), first: index, last: index))
                }
            } else if let value = numberWords[token], !(token == "oh" && current == nil && total == 0) {
                if let c = current, c % 100 >= 20, c % 10 == 0, value < 10 {
                    current = c + value  // "twenty five", "two hundred twenty five"
                } else if let c = current, c % 100 == 0, c >= 100, value < 100 {
                    current = c + value  // "one hundred five"
                } else if current == nil, total != 0, value < 1000 {
                    current = value  // "one thousand two …"
                } else if current != nil {
                    flush()
                    current = value
                } else {
                    current = value
                }
                begin(index)
            } else if let scale = scales[token] {
                if current == nil && total == 0 && index > 0 && (tokens[index - 1] == "a" || tokens[index - 1] == "one") {
                    current = 1  // "a hundred"
                    begin(index - 1)
                }
                if current == nil && total == 0 {
                    continue
                }
                let base = current ?? 1  // a current of 0 stays 0
                let (product, overflow) = base.multipliedReportingOverflow(by: scale)
                let newCurrent: Int? = scale == 100 ? product : nil
                let newTotal = scale == 100 ? total : total + product
                if overflow || (newCurrent ?? 0) > spelledLimit || newTotal > spelledLimit {
                    // The number would pass 2^53: it ends here, unusable.
                    begin(index)
                    unusable = true
                    flush()
                    continue
                }
                current = newCurrent
                total = newTotal
                begin(index)
            } else if token == "and" && (current != nil || total != 0) {
                continue  // "one hundred and five"
            } else {
                flush()
            }
        }
        flush()
        return found
    }

    /// Pairs the speaker's kept numbers with the output's numbers (see
    /// `match_numbers` in hardchecks.py). Returns (kept numbers unmatched,
    /// output numbers unmatched). Unusable numbers (nil) never match.
    static func matchNumbers(_ kept: [FoundNumber], _ out: [String?]) -> (missing: [String?], extra: [String?]) {
        var left = out
        var used = [Bool](repeating: false, count: kept.count)
        func take(_ value: String) -> Bool {
            guard let index = left.firstIndex(of: value) else { return false }
            left.remove(at: index)
            return true
        }
        if kept.count >= 2 {
            for length in stride(from: min(6, kept.count), through: 2, by: -1) {
                for start in 0...(kept.count - length) {
                    let run = start..<(start + length)
                    if run.contains(where: { used[$0] || kept[$0].value == nil }) { continue }
                    if (start..<(start + length - 1)).contains(where: { kept[$0 + 1].first != kept[$0].last + 1 }) {
                        continue
                    }
                    let joined = run.compactMap { kept[$0].value }.joined()
                    if take(joined) {
                        for i in run { used[i] = true }
                    }
                }
            }
        }
        var unmatched: [String?] = []
        for (i, number) in kept.enumerated() where !used[i] {
            if let value = number.value, take(value) { continue }
            unmatched.append(number.value)
        }
        return (unmatched, left)
    }

    // ---- Corrections -----------------------------------------------------------

    static func isNumber(_ token: String) -> Bool {
        isDigits(token) || numberWords[token] != nil
    }

    /// Finds spoken corrections. Returns (replaced word indexes, marker word
    /// indexes). A marker counts only when the next word restates something
    /// from the three words before it: the same word, or a number after a number.
    /// The replaced words run from the earliest restated word up to the
    /// marker, so "don't run five no six tests" replaces only "five".
    static func correctedSpans(_ tokens: [String]) -> (replaced: Set<Int>, markers: Set<Int>) {
        var replaced: Set<Int> = []
        var markers: Set<Int> = []
        for index in tokens.indices {
            for marker in correctionMarkers {
                let parts = marker.split(separator: " ").map(String.init)
                guard Array(tokens[index..<min(tokens.count, index + parts.count)]) == parts else { continue }
                let first = max(0, index - 3)
                let before = Array(tokens[first..<index])
                let afterStart = index + parts.count
                let after = Array(tokens[min(tokens.count, afterStart)..<min(tokens.count, afterStart + 4)])
                if before.isEmpty || after.isEmpty { continue }
                var restated = before.indices.filter { !functionWords.contains(before[$0]) && after.contains(before[$0]) }
                if isNumber(after[0]), let number = before.firstIndex(where: isNumber) { restated.append(number) }
                if let start = restated.min() {
                    replaced.formUnion((first + start)..<index)
                    markers.formUnion(index..<(index + parts.count))
                }
            }
        }
        return (replaced, markers)
    }

    // ---- Identifiers -----------------------------------------------------------

    static func identifiers(_ text: String) -> [String] {
        identifierPattern.matches(in: text)
    }

    static func squash(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter {
            ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57)
        }))
    }

    // ---- The checks ------------------------------------------------------------

    /// Returns the names of the hard checks the cleaned text fails, in
    /// `checkOrder` (empty = passes). `vocabulary` is the terms the prompt used.
    public static func check(
        transcript: String,
        cleaned: String,
        vocabulary: [String] = [],
        maxWordsRatio: Double = 1.6,
        maxWordsSlack: Int = 8
    ) -> [String] {
        var failures: Set<String> = []
        let raw = words(transcript)
        let out = words(cleaned)
        let rawExpanded = expand(raw)
        let outExpanded = expand(out)
        let (replaced, markers) = correctedSpans(raw)
        let ignored = replaced.union(markers)

        // dropped: nothing (or too little) left of what the speaker kept.
        var fillerPairs: Set<Int> = []
        if raw.count >= 2 {
            for i in 0..<(raw.count - 1) where fillers.contains("\(raw[i]) \(raw[i + 1])") {
                fillerPairs.formUnion([i, i + 1])
            }
        }
        let content = raw.enumerated().filter { i, w in
            !ignored.contains(i) && !fillerPairs.contains(i) && !functionWords.contains(w)
                && !fillers.contains(w) && !hedges.contains(w)
                && !isNumber(w) && scales[w] == nil  // numbers are checked on their own
        }.map(\.element)
        let outStems = Set(outExpanded.map(stem))
        if !content.isEmpty && out.isEmpty {
            failures.insert("dropped")
        } else if content.count >= 4 {
            let squashedCleaned = squash(cleaned)
            let kept = content.filter { outStems.contains(stem($0)) || squashedCleaned.contains($0) }.count
            if Double(kept) / Double(content.count) < 0.5 {
                failures.insert("dropped")
            }
        }

        // answers: starts like a reply (not just echoing how the speaker began), or grew too much.
        let lead = stripFillers(out)
        let rawLead = Array(stripFillers(raw).prefix(4))
        for opener in answerOpeners {
            let openerWords = words(opener)
            if Array(lead.prefix(openerWords.count)) == openerWords {
                if !rawLead.joined(separator: " ").contains(openerWords.joined(separator: " ")) {
                    failures.insert("answers")
                }
                break
            }
        }
        if Double(out.count) > maxWordsRatio * Double(raw.count) + Double(maxWordsSlack) {
            failures.insert("answers")
        }

        // question: a spoken question must stay a question.
        let head = Array(stripFillers(raw).prefix(2))
        let asks = head.count == 2 && (
            (helperVerbs.contains(head[0])
                && (head[0] == "do" || head[0] == "have" ? persons : pronouns).contains(head[1]))
            || (questionWords.contains(head[0]) && helperVerbs.contains(head[1]))
        )
        if asks && !out.isEmpty && rstrip(cleaned).unicodeScalars.last != "?" {
            failures.insert("question")
        }

        // numbers: exactly the numbers the speaker kept (corrected-away ones don't count).
        // Ignored words are blanked rather than removed, so positions still show
        // which numbers were spoken back to back.
        let keptNumbers = numbersWithPositions(raw.enumerated().map { ignored.contains($0) ? "" : $1 })
        let (missing, extra) = matchNumbers(keptNumbers, numbers(in: out))
        if !missing.isEmpty || !extra.isEmpty {
            failures.insert("numbers")
        }

        // negation: the negations the speaker kept, no fewer and no more.
        let rawNegations = raw.enumerated().filter { negations.contains($1) && !ignored.contains($0) }.count
        let outNegations = out.filter { negations.contains($0) }.count
        if rawNegations != outNegations {
            failures.insert("negation")
        }

        // identifiers: each one written in the transcript survives (ignoring case and separators).
        let squashedOut = squash(cleaned)
        if identifiers(transcript).contains(where: { !squashedOut.contains(squash($0)) }) {
            failures.insert("identifiers")
        }

        // new_words: every word is from the transcript, the vocabulary, a small set of
        // joining words, or 2–3 consecutive transcript words joined ("read me" → "readme").
        var allowed = Set(rawExpanded).union(functionWords)
        for term in vocabulary {
            allowed.formUnion(words(term))
        }
        let allowedStems = Set(allowed.map(stem))
        var joins: Set<String> = []
        for n in [2, 3] where rawExpanded.count >= n {
            for i in 0...(rawExpanded.count - n) {
                joins.insert(rawExpanded[i..<(i + n)].joined())
            }
        }
        for word in outExpanded {
            if allowed.contains(word) || allowedStems.contains(stem(word)) || joins.contains(word) {
                continue
            }
            if isDigits(word) || numberWords[word] != nil || scales[word] != nil {
                continue  // numbers are checked above
            }
            failures.insert("new_words")
            break
        }

        return checkOrder.filter { failures.contains($0) }
    }
}

extension Array where Element == UInt8 {
    func contains(subsequence needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= count else { return needle.isEmpty }
        return (0...(count - needle.count)).contains { start in
            self[start..<(start + needle.count)].elementsEqual(needle)
        }
    }
}

/// A small wrapper over NSRegularExpression that returns matched strings.
struct Pattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String, dotAll: Bool = false) {
        // The patterns are constants; a bad one is a programming error.
        regex = try! NSRegularExpression(pattern: pattern, options: dotAll ? [.dotMatchesLineSeparators] : [])
    }

    /// Every match (group 0), left to right, like Python's `re.findall`.
    func matches(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// The first match's groups (0 = whole match).
    func firstMatch(in text: String) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
