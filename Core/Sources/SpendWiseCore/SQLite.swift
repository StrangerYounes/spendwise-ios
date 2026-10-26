import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// A value as SQLite stores it.
public enum SQLValue: Equatable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    public var int64: Int64? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        case .text(let s): return Int64(s)
        case .null: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .text(let s): return Double(s)
        case .null: return nil
        }
    }

    public var string: String? {
        switch self {
        case .text(let s): return s
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .null: return nil
        }
    }

    public var isNull: Bool { self == .null }

    /// The value as sync's field maps hold it: Int64, Double, String or nil.
    public var any: Any? {
        switch self {
        case .int(let v): return v
        case .double(let v): return v
        case .text(let s): return s
        case .null: return nil
        }
    }
}

/// One result row, read by column name.
public struct SQLRow {
    public let columns: [String]
    public let values: [SQLValue]

    public subscript(_ name: String) -> SQLValue {
        guard let i = columns.firstIndex(of: name) else { return .null }
        return values[i]
    }

    public subscript(_ index: Int) -> SQLValue { values[index] }

    public func int(_ name: String) -> Int64 { self[name].int64 ?? 0 }
    public func intOrNil(_ name: String) -> Int64? { self[name].int64 }
    public func double(_ name: String) -> Double { self[name].double ?? 0 }
    public func doubleOrNil(_ name: String) -> Double? { self[name].double }
    public func string(_ name: String) -> String { self[name].string ?? "" }
    public func stringOrNil(_ name: String) -> String? { self[name].string }
    public func bool(_ name: String) -> Bool { (self[name].int64 ?? 0) != 0 }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
}

private let SQLITE_TRANSIENT_VALUE = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A small wrapper over one SQLite connection. Used from one thread at a time (the app's main actor).
public final class SQLiteDB {
    private var handle: OpaquePointer?
    private var depth = 0

    /// Called after every statement that may have changed rows (screens refresh from it).
    public var onChange: (() -> Void)?

    /// Opens (creating) a database file, or an in-memory one for ":memory:".
    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(handle)
            throw SQLiteError(code: SQLITE_CANTOPEN, message: message)
        }
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(handle) }

    private func error(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Runs one or more statements without arguments.
    public func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &message)
        if code != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? "error"
            sqlite3_free(message)
            throw SQLiteError(code: code, message: text)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard code == SQLITE_OK, let s = stmt else { throw error(code) }
        return s
    }

    private func bind(_ value: Any?, to stmt: OpaquePointer, at i: Int32) throws {
        let code: Int32
        switch value {
        case nil: code = sqlite3_bind_null(stmt, i)
        case let v as SQLValue:
            switch v {
            case .null: code = sqlite3_bind_null(stmt, i)
            case .int(let n): code = sqlite3_bind_int64(stmt, i, n)
            case .double(let d): code = sqlite3_bind_double(stmt, i, d)
            case .text(let s): code = sqlite3_bind_text(stmt, i, s, -1, SQLITE_TRANSIENT_VALUE)
            }
        case let v as Bool: code = sqlite3_bind_int64(stmt, i, v ? 1 : 0)
        case let v as Int: code = sqlite3_bind_int64(stmt, i, Int64(v))
        case let v as Int32: code = sqlite3_bind_int64(stmt, i, Int64(v))
        case let v as Int64: code = sqlite3_bind_int64(stmt, i, v)
        case let v as Double: code = sqlite3_bind_double(stmt, i, v)
        case let v as String: code = sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT_VALUE)
        default: code = sqlite3_bind_text(stmt, i, "\(value!)", -1, SQLITE_TRANSIENT_VALUE)
        }
        if code != SQLITE_OK { throw error(code) }
    }

    /// Binds positional (`?`) arguments, or named ones (`:name`) from [named].
    private func bindAll(_ stmt: OpaquePointer, _ args: [Any?], _ named: [String: Any?]) throws {
        let count = sqlite3_bind_parameter_count(stmt)
        guard count > 0 else { return }
        for i in 1...count {
            if let raw = sqlite3_bind_parameter_name(stmt, i) {
                let name = String(String(cString: raw).dropFirst())
                if let value = named[name] { try bind(value, to: stmt, at: i); continue }
                if Int(i) - 1 < args.count { try bind(args[Int(i) - 1], to: stmt, at: i); continue }
                throw SQLiteError(code: SQLITE_RANGE, message: "no value for :\(name)")
            } else {
                guard Int(i) - 1 < args.count else { throw SQLiteError(code: SQLITE_RANGE, message: "missing argument \(i)") }
                try bind(args[Int(i) - 1], to: stmt, at: i)
            }
        }
    }

    private func column(_ stmt: OpaquePointer, _ i: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return .int(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, i))
        case SQLITE_NULL: return .null
        default:
            guard let text = sqlite3_column_text(stmt, i) else { return .null }
            return .text(String(cString: text))
        }
    }

    /// Runs a statement that returns rows.
    public func query(_ sql: String, _ args: [Any?] = [], named: [String: Any?] = [:]) throws -> [SQLRow] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindAll(stmt, args, named)
        let n = sqlite3_column_count(stmt)
        let names = (0..<n).map { String(cString: sqlite3_column_name(stmt, $0)) }
        var rows: [SQLRow] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw error(code) }
            rows.append(SQLRow(columns: names, values: (0..<n).map { column(stmt, $0) }))
        }
        return rows
    }

    /// The first column of the first row, or nil.
    public func scalar(_ sql: String, _ args: [Any?] = [], named: [String: Any?] = [:]) throws -> SQLValue? {
        try query(sql, args, named: named).first.map { $0[0] }
    }

    /// Runs a statement that changes rows; returns how many changed.
    @discardableResult
    public func run(_ sql: String, _ args: [Any?] = [], named: [String: Any?] = [:]) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindAll(stmt, args, named)
        let code = sqlite3_step(stmt)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw error(code) }
        if depth == 0 { onChange?() }
        return Int(sqlite3_changes(handle))
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Runs [body] in a transaction (a savepoint when nested); rolls back if it throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        let name = "sp\(depth)"
        try execute(depth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(name)")
        depth += 1
        do {
            let result = try body()
            depth -= 1
            try execute(depth == 0 ? "COMMIT" : "RELEASE \(name)")
            if depth == 0 { onChange?() }
            return result
        } catch {
            depth -= 1
            if depth == 0 {
                try? execute("ROLLBACK")
            } else {
                try? execute("ROLLBACK TO \(name)")
                try? execute("RELEASE \(name)")
            }
            throw error
        }
    }

    public var userVersion: Int {
        get { Int((try? scalar("PRAGMA user_version"))??.int64 ?? 0) }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }
}
