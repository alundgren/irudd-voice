import Foundation
import SQLite3

public struct DatabaseError: Error, CustomStringConvertible {
    public let message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}

/// A small wrapper around one SQLite connection. Not thread-safe: each
/// owner keeps it on one queue or actor.
public final class Database {
    private var handle: OpaquePointer?
    public let path: String

    /// Opens (or creates) the file with WAL and a busy timeout, the same
    /// settings the CLI uses, so app and CLI can read and write together.
    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw DatabaseError(message: "Can't open \(path): \(message)")
        }
        sqlite3_busy_timeout(handle, 10_000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastError
            sqlite3_free(error)
            throw DatabaseError(message: message)
        }
    }

    /// Runs a statement with `?` parameters and returns the rows.
    @discardableResult
    public func query(_ sql: String, _ values: [SQLValue] = []) throws -> [[SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError(message: "\(lastError) in: \(sql)")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            try bind(value, at: Int32(index + 1), to: statement)
        }
        var rows: [[SQLValue]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append((0..<sqlite3_column_count(statement)).map { column(statement, $0) })
            case SQLITE_DONE:
                return rows
            default:
                throw DatabaseError(message: "\(lastError) in: \(sql)")
            }
        }
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Runs `body` in a write transaction (BEGIN IMMEDIATE, so a busy
    /// database is waited for up front instead of failing halfway).
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var userVersion: Int {
        get throws { try query("PRAGMA user_version").first?.first?.int.map(Int.init) ?? 0 }
    }

    private var lastError: String {
        String(cString: sqlite3_errmsg(handle))
    }

    private func bind(_ value: SQLValue, at index: Int32, to statement: OpaquePointer?) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status: Int32
        switch value {
        case .null: status = sqlite3_bind_null(statement, index)
        case .int(let v): status = sqlite3_bind_int64(statement, index, v)
        case .double(let v): status = sqlite3_bind_double(statement, index, v)
        case .text(let v): status = sqlite3_bind_text(statement, index, v, -1, transient)
        case .blob(let v):
            status = v.withUnsafeBytes { sqlite3_bind_blob64(statement, index, $0.baseAddress, sqlite3_uint64(v.count), transient) }
        }
        guard status == SQLITE_OK else { throw DatabaseError(message: lastError) }
    }

    private func column(_ statement: OpaquePointer?, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .int(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default: return .null
        }
    }
}

public enum SQLValue: Equatable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public var int: Int64? { if case .int(let v) = self { v } else { nil } }
    public var double: Double? {
        switch self {
        case .double(let v): v
        case .int(let v): Double(v)
        default: nil
        }
    }
    public var text: String? { if case .text(let v) = self { v } else { nil } }
    public var blob: Data? { if case .blob(let v) = self { v } else { nil } }

    public static func optional(_ value: String?) -> SQLValue { value.map { .text($0) } ?? .null }
    public static func optional(_ value: Int64?) -> SQLValue { value.map { .int($0) } ?? .null }
}
