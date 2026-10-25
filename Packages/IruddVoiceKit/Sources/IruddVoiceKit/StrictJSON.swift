import Foundation

/// A JSON value from `StrictJSON.parse`.
public enum JSONValue: Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number
    case bool(Bool)
    case null
}

/// Reads a model reply as JSON with the rules in shared/README.md ("Reading
/// the reply"), so Swift and Python (hardchecks.py) accept exactly the same
/// texts: RFC 8259 JSON like Python's `json.loads` (strict), plus these
/// refusals: a repeated key in any object, the `NaN`/`Infinity`/`-Infinity`
/// constants, a byte order mark, an escaped lone surrogate (`"\ud800"`), and
/// nesting deeper than `maxDepth`. Numbers are checked against the grammar
/// but not converted; only strings matter to the reply.
public enum StrictJSON {
    public static let maxDepth = 100

    public static func parse(_ text: String) -> JSONValue? {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        guard let value = parser.value(depth: 1) else { return nil }
        parser.skipWhitespace()
        return parser.index == parser.bytes.count ? value : nil
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipWhitespace() {
            // JSON whitespace only: space, tab, newline, carriage return.
            while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            }
        }

        mutating func literal(_ word: String) -> Bool {
            let utf8 = Array(word.utf8)
            guard index + utf8.count <= bytes.count, Array(bytes[index..<(index + utf8.count)]) == utf8 else { return false }
            index += utf8.count
            return true
        }

        mutating func value(depth: Int) -> JSONValue? {
            switch current {
            case UInt8(ascii: "{"): return depth > StrictJSON.maxDepth ? nil : object(depth: depth)
            case UInt8(ascii: "["): return depth > StrictJSON.maxDepth ? nil : array(depth: depth)
            case UInt8(ascii: "\""): return string().map(JSONValue.string)
            case UInt8(ascii: "t"): return literal("true") ? .bool(true) : nil
            case UInt8(ascii: "f"): return literal("false") ? .bool(false) : nil
            case UInt8(ascii: "n"): return literal("null") ? .null : nil
            default: return number() ? .number : nil
            }
        }

        mutating func object(depth: Int) -> JSONValue? {
            index += 1
            var members: [String: JSONValue] = [:]
            // Keys compare by code points, like Python; Swift's String equality
            // would treat "é" and "e\u{301}" as the same key.
            var seen: Set<[UInt8]> = []
            skipWhitespace()
            if current == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard current == UInt8(ascii: "\""), let key = string() else { return nil }
                guard seen.insert(Array(key.utf8)).inserted else { return nil }  // repeated key
                skipWhitespace()
                guard current == UInt8(ascii: ":") else { return nil }
                index += 1
                skipWhitespace()
                guard let member = value(depth: depth + 1) else { return nil }
                members[key] = member
                skipWhitespace()
                if current == UInt8(ascii: ",") {
                    index += 1
                } else if current == UInt8(ascii: "}") {
                    index += 1
                    return .object(members)
                } else {
                    return nil
                }
            }
        }

        mutating func array(depth: Int) -> JSONValue? {
            index += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if current == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                guard let item = value(depth: depth + 1) else { return nil }
                items.append(item)
                skipWhitespace()
                if current == UInt8(ascii: ",") {
                    index += 1
                } else if current == UInt8(ascii: "]") {
                    index += 1
                    return .array(items)
                } else {
                    return nil
                }
            }
        }

        /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?`
        mutating func number() -> Bool {
            func isDigit(_ byte: UInt8?) -> Bool { byte.map { $0 >= 0x30 && $0 <= 0x39 } ?? false }
            if current == UInt8(ascii: "-") { index += 1 }
            if current == UInt8(ascii: "0") {
                index += 1
            } else if isDigit(current) {
                while isDigit(current) { index += 1 }
            } else {
                return false
            }
            if current == UInt8(ascii: "."), index + 1 < bytes.count, isDigit(bytes[index + 1]) {
                index += 1
                while isDigit(current) { index += 1 }
            }
            if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
                var lookahead = index + 1
                if lookahead < bytes.count, bytes[lookahead] == UInt8(ascii: "+") || bytes[lookahead] == UInt8(ascii: "-") {
                    lookahead += 1
                }
                if lookahead < bytes.count, isDigit(bytes[lookahead]) {
                    index = lookahead
                    while isDigit(current) { index += 1 }
                }
            }
            return true
        }

        mutating func hex4() -> UInt32? {
            guard index + 4 <= bytes.count else { return nil }
            var value: UInt32 = 0
            for byte in bytes[index..<(index + 4)] {
                let digit: UInt8
                switch byte {
                case 0x30...0x39: digit = byte - 0x30
                case 0x41...0x46: digit = byte - 0x41 + 10
                case 0x61...0x66: digit = byte - 0x61 + 10
                default: return nil
                }
                value = value * 16 + UInt32(digit)
            }
            index += 4
            return value
        }

        mutating func string() -> String? {
            index += 1
            var out: [UInt8] = []
            while let byte = current {
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return String(decoding: out, as: UTF8.self)
                case 0x00..<0x20:
                    return nil  // raw control character
                case UInt8(ascii: "\\"):
                    guard let escape = current else { return nil }
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escape)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        guard var scalar = hex4() else { return nil }
                        if (0xD800...0xDBFF).contains(scalar) {
                            // A high surrogate must be followed by an escaped low one.
                            guard current == UInt8(ascii: "\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u")
                            else { return nil }
                            index += 2
                            guard let low = hex4(), (0xDC00...0xDFFF).contains(low) else { return nil }
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(scalar) {
                            return nil
                        }
                        guard let unicode = Unicode.Scalar(scalar) else { return nil }
                        out.append(contentsOf: Array(String(Character(unicode)).utf8))
                    default:
                        return nil
                    }
                default:
                    out.append(byte)
                }
            }
            return nil  // unterminated
        }
    }
}
