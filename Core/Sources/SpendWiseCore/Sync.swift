import Foundation

/// A row as the account has it: its fields, when each one last changed, and whether it was deleted.
public struct RemoteRow {
    public var values: Fields
    public var times: [String: Int64]
    public var deleted: Bool
    public var deletedAt: Int64 = 0
    public init(values: Fields, times: [String: Int64], deleted: Bool, deletedAt: Int64 = 0) {
        self.values = values; self.times = times; self.deleted = deleted; self.deletedAt = deletedAt
    }
}

/// The merge rules (Android sync/SyncMerge.kt), free of Firebase so they're unit-tested.
///
/// Each field merges on its own: the later change to that field wins, by the clock of the phone
/// that made it; on a tie the account's value wins. A delete wins over edits made at the same time
/// elsewhere; putting a row back (undo) is a newer change and brings it back everywhere.
public enum SyncMerge {
    static func number(_ v: Any?) -> Double? {
        switch v {
        case let n as Int64: return Double(n)
        case let n as Int: return Double(n)
        case let n as Int32: return Double(n)
        case let d as Double: return d
        case let f as Float: return Double(f)
        case let b as Bool: return b ? 1 : 0
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    static func isNil(_ v: Any?) -> Bool {
        guard let v else { return true }
        if case Optional<Any>.none = v { return true }
        return v is NSNull
    }

    /// Equal by value: 1, 1.0 and true are the same number.
    public static func same(_ a: Any?, _ b: Any?) -> Bool {
        if isNil(a) || isNil(b) { return isNil(a) && isNil(b) }
        if !(a is String), !(b is String), let x = number(a), let y = number(b) { return x == y }
        if let x = a as? String, let y = b as? String { return x == y }
        return false
    }

    static func value(_ f: Fields?, _ c: String) -> Any? { f?[c] ?? nil }

    /// Fields this phone changed that the account doesn't have yet (all of them for a new row).
    public static func localChanges(_ local: Fields, base: Fields?, columns: [String]) -> Set<String> {
        guard let base else { return Set(columns) }
        return Set(columns.filter { !same(value(local, $0), value(base, $0)) })
    }

    /// Of [changed] (made at [changedAt]), the fields an upload may write: those the account changed earlier.
    public static func writable(_ changed: Set<String>, changedAt: Int64, remote: RemoteRow?) -> Set<String> {
        guard let remote else { return changed }
        return changed.filter { (remote.times[$0] ?? Int64.min) < changedAt }
    }

    /// This phone's row after hearing the account's version of it. [pendingAt] is when this phone
    /// last changed the row, if that change hasn't gone up yet: those fields stay when newer.
    public static func merge(local: Fields?, base: Fields?, pendingAt: Int64?, remote: RemoteRow, columns: [String]) -> Fields {
        var out: Fields = [:]
        for c in columns {
            let editedHere = local != nil && pendingAt != nil && (base == nil || !same(value(local, c), value(base, c)))
            let remoteAt = remote.times[c] ?? Int64.min
            if editedHere && pendingAt! > remoteAt {
                out[c] = value(local, c)
            } else if remote.values.keys.contains(c) {
                out[c] = value(remote.values, c)
            } else {
                out[c] = value(local, c)
            }
        }
        return out
    }

    /// What makes two rows "the same" when a phone first joins an account that already has data.
    public static func naturalKey(_ table: String, _ f: Fields) -> String? {
        func text(_ c: String) -> String? { (value(f, c) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func num(_ c: String) -> Int64? { number(value(f, c)).map { Int64($0) } }
        switch table {
        case "stores", "categories", "master_items": return text("name")
        case "shopping_lists": return text("name").map { "\($0)|\(num("createdDate").map(String.init) ?? "null")" }
        case "shopping_items":
            guard let list = value(f, "listId") as? String else { return nil }
            return "\(list)|\(text("itemName") ?? "null")|\(num("orderIndex").map(String.init) ?? "null")"
        case "ai_reports": return num("createdAt").map(String.init)
        default: return nil
        }
    }

    // MARK: Base rows, stored as JSON

    public static func encode(_ fields: Fields) -> String {
        JSON.object(fields.keys.sorted().map { k in
            let v = value(fields, k)
            let j: JSON
            switch v {
            case nil: j = .null
            case let s as String: j = .string(s)
            case let b as Bool: j = .bool(b)
            case let i as Int64: j = .integer(i)
            case let i as Int: j = .integer(Int64(i))
            case let d as Double: j = .number(d)
            default: j = number(v).map(JSON.number) ?? .string("\(v!)")
            }
            return (k, j)
        }).text
    }

    public static func decode(_ json: String) -> Fields {
        guard let o = (try? JSON.parse(json))?.object else { return [:] }
        var out: Fields = [:]
        for (k, v) in o {
            switch v {
            case .null: out[k] = .some(nil)
            case .string(let s): out[k] = s
            case .bool(let b): out[k] = b
            case .integer(let i): out[k] = i
            case .number(let d): out[k] = d
            default: out[k] = .some(nil)
            }
        }
        return out
    }
}

/// A local row: where it is, its uid and its synced fields with references as uids.
public struct LocalRow {
    public let rid: Int64
    public let uid: String
    public let fields: Fields
}

public struct Pending: Equatable, Sendable { public let table: String; public let rid: Int64; public let changedAt: Int64 }
public struct Tombstone: Equatable, Sendable { public let table: String; public let uid: String; public let deletedAt: Int64 }

/// The database side of sync (Android sync/SyncStore.kt), over plain SQL so one piece of code serves
/// every table in SyncSchema.
public final class SyncStore {
    let db: SQLiteDB
    public init(_ database: AppDatabase) { db = database.db }

    public func transaction<T>(_ body: () throws -> T) throws -> T { try db.transaction(body) }

    /// Writes the account's changes without recording them as this phone's own.
    public func applying<T>(_ body: () throws -> T) throws -> T {
        try db.transaction {
            try SyncSchema.setMode(db, SyncSchema.modeApplying)
            defer { try? SyncSchema.setMode(db, SyncSchema.modeRecording) }
            return try body()
        }
    }

    public func mode() throws -> Int { Int(try db.scalar("SELECT mode FROM sync_flags WHERE id = 0")?.int64 ?? 0) }

    public func setMode(_ mode: Int) throws { try SyncSchema.setMode(db, mode) }

    public func heard(_ time: Int64) throws { try SyncSchema.heard(db, time) }

    // MARK: Rows

    private func cols(_ t: SyncTable) -> String { t.columns.joined(separator: ", ") }

    private func read(_ t: SyncTable, _ r: SQLRow) throws -> LocalRow {
        var fields: Fields = [:]
        for (i, col) in t.columns.enumerated() {
            let raw = r[i + 2]
            if let parent = t.refs[col] {
                fields[col] = try raw.int64.flatMap { try uidOf(parent, $0) } as Any?
            } else {
                fields[col] = raw.any
            }
        }
        return LocalRow(rid: r[0].int64 ?? 0, uid: r[1].string ?? "", fields: fields)
    }

    public func row(_ t: SyncTable, rid: Int64) throws -> LocalRow? {
        try db.query("SELECT rowid, uid, \(cols(t)) FROM \(t.name) WHERE rowid = ?", [rid]).first.map { try read(t, $0) }
    }

    public func row(_ t: SyncTable, uid: String) throws -> LocalRow? {
        try db.query("SELECT rowid, uid, \(cols(t)) FROM \(t.name) WHERE uid = ?", [uid]).first.map { try read(t, $0) }
    }

    public func allRows(_ t: SyncTable) throws -> [LocalRow] {
        try db.query("SELECT rowid, uid, \(cols(t)) FROM \(t.name) WHERE uid IS NOT NULL").map { try read(t, $0) }
    }

    public func setUid(_ t: SyncTable, rid: Int64, _ uid: String) throws {
        try db.run("UPDATE \(t.name) SET uid = ? WHERE rowid = ?", [uid, rid])
    }

    /// Recomputes derived uids (store prices) after their parents' uids changed.
    public func refreshDerivedUids() throws { try SyncSchema.fillMissingUids(db) }

    func uidOf(_ table: String, _ id: Int64) throws -> String? {
        try db.scalar("SELECT uid FROM \(table) WHERE id = ?", [id])?.string
    }

    func idOf(_ table: String, _ uid: String) throws -> Int64? {
        try db.scalar("SELECT id FROM \(table) WHERE uid = ?", [uid])?.int64
    }

    /// Writes the account's version of a row (insert or update by uid). Returns false when a
    /// reference isn't here yet, so the caller can retry once it arrives.
    public func write(_ t: SyncTable, uid: String, fields: Fields, existing: LocalRow?) throws -> Bool {
        var names: [String] = []
        var values: [Any?] = []
        for col in t.columns where fields.keys.contains(col) {
            let v = SyncMerge.value(fields, col)
            var local: Any? = v
            if let parent = t.refs[col], let ref = v as? String {
                guard let id = try idOf(parent, ref) else { return false }
                local = id
            }
            if let b = local as? Bool { local = b ? Int64(1) : Int64(0) }
            names.append(col)
            values.append(local)
        }
        if existing == nil {
            if !t.derivedUid { names.append("uid"); values.append(uid) }
            let conflict: String
            if let id = t.fixedId {
                names.append("id"); values.append(id)
                conflict = "OR REPLACE"
            } else {
                conflict = t.derivedUid ? "OR REPLACE" : "OR ABORT"
            }
            let marks = Array(repeating: "?", count: names.count).joined(separator: ", ")
            try db.run("INSERT \(conflict) INTO \(t.name) (\(names.joined(separator: ", "))) VALUES (\(marks))", values)
        } else {
            guard !names.isEmpty else { return true }
            let sets = names.map { "\($0) = ?" }.joined(separator: ", ")
            try db.run("UPDATE OR ABORT \(t.name) SET \(sets) WHERE rowid = ?", values + [existing!.rid])
        }
        return true
    }

    public func delete(_ t: SyncTable, uid: String) throws { try db.run("DELETE FROM \(t.name) WHERE uid = ?", [uid]) }

    // MARK: Bookkeeping

    public func pending() throws -> [Pending] {
        let order = Dictionary(uniqueKeysWithValues: SyncSchema.tables.enumerated().map { ($1.name, $0) })
        return try db.query("SELECT tbl, rid, changedAt FROM sync_outbox").map {
            Pending(table: $0.string("tbl"), rid: $0.int("rid"), changedAt: $0.int("changedAt"))
        }.enumerated().sorted { a, b in
            let x = order[a.element.table] ?? -1, y = order[b.element.table] ?? -1
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    public func pendingFor(_ t: SyncTable, rid: Int64) throws -> Int64? {
        try db.scalar("SELECT changedAt FROM sync_outbox WHERE tbl = ? AND rid = ?", [t.name, rid])?.int64
    }

    /// Done with an upload, unless the row changed again meanwhile.
    public func clearPending(_ p: Pending) throws {
        try db.run("DELETE FROM sync_outbox WHERE tbl = ? AND rid = ? AND changedAt = ?", [p.table, p.rid, p.changedAt])
    }

    public func clearPendingRow(_ t: SyncTable, rid: Int64) throws {
        try db.run("DELETE FROM sync_outbox WHERE tbl = ? AND rid = ?", [t.name, rid])
    }

    public func markPending(_ t: SyncTable, rid: Int64, at: Int64) throws {
        try db.run("INSERT OR REPLACE INTO sync_outbox (tbl, rid, changedAt) VALUES (?, ?, ?)", [t.name, rid, at])
    }

    public func tombstones() throws -> [Tombstone] {
        try db.query("SELECT tbl, uid, deletedAt FROM sync_tombstones").map {
            Tombstone(table: $0.string("tbl"), uid: $0.string("uid"), deletedAt: $0.int("deletedAt"))
        }
    }

    public func clearTombstone(_ s: Tombstone) throws {
        try db.run("DELETE FROM sync_tombstones WHERE tbl = ? AND uid = ? AND deletedAt = ?", [s.table, s.uid, s.deletedAt])
    }

    public func waitingCount() throws -> Int {
        Int(try db.scalar("SELECT (SELECT COUNT(*) FROM sync_outbox) + (SELECT COUNT(*) FROM sync_tombstones)")?.int64 ?? 0)
    }

    public func base(_ t: SyncTable, uid: String) throws -> Fields? {
        try db.scalar("SELECT data FROM sync_base WHERE tbl = ? AND uid = ?", [t.name, uid])?.string.map(SyncMerge.decode)
    }

    public func setBase(_ t: SyncTable, uid: String, _ fields: Fields) throws {
        try db.run("INSERT OR REPLACE INTO sync_base (tbl, uid, data) VALUES (?, ?, ?)", [t.name, uid, SyncMerge.encode(fields)])
    }

    public func clearBase(_ t: SyncTable, uid: String) throws {
        try db.run("DELETE FROM sync_base WHERE tbl = ? AND uid = ?", [t.name, uid])
    }

    /// Records what changed while nothing was recorded, by comparing every row with what the account had.
    public func catchUp(now: Int64) throws {
        for t in SyncSchema.tables {
            let rows = try allRows(t)
            for row in rows {
                let b = try base(t, uid: row.uid)
                if b == nil || !SyncMerge.localChanges(row.fields, base: b, columns: t.columns).isEmpty {
                    try markPending(t, rid: row.rid, at: now)
                }
            }
            let here = Set(rows.map(\.uid))
            for uid in try db.query("SELECT uid FROM sync_base WHERE tbl = ?", [t.name]).map({ $0.string("uid") }) where !here.contains(uid) {
                try db.run("INSERT OR REPLACE INTO sync_tombstones (tbl, uid, deletedAt) VALUES (?, ?, ?)", [t.name, uid, now])
            }
        }
    }

    /// Forgets what was synced with an earlier account or family, keeping the mode.
    public func clearBookkeeping() throws {
        try db.execute("DELETE FROM sync_outbox; DELETE FROM sync_tombstones; DELETE FROM sync_base")
    }

    /// Forgets everything sync knew (signing out): the rows themselves stay.
    public func reset() throws {
        try db.transaction {
            try clearBookkeeping()
            try SyncSchema.setMode(db, SyncSchema.modeOff)
        }
    }
}

/// Family invite codes (Android sync/Family.kt's companion).
public enum FamilyCodes {
    public static let length = 8
    /** No 0/O, 1/I/L: codes are read out and typed. */
    public static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    public static func newCode() -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int(rng.next(upperBound: UInt64(alphabet.count)))] })
    }

    public static func normalize(_ input: String) -> String { String(input.uppercased().filter { alphabet.contains($0) }) }

    /// "XXXX XXXX".
    public static func display(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { i in
            String(code.dropFirst(i).prefix(4))
        }.joined(separator: " ")
    }
}

/// The sync status shown in Settings and next to Home's title.
public struct SyncStatus: Equatable, Sendable {
    public enum State: Sendable { case off, joining, syncing, synced, offline, error }
    public var state: State = .off
    /** Changes on this phone not yet in the account. */
    public var waiting = 0
    public var lastSyncedAt: Millis? = nil
    public var error: String? = nil
    public init(state: State = .off, waiting: Int = 0, lastSyncedAt: Millis? = nil, error: String? = nil) {
        self.state = state; self.waiting = waiting; self.lastSyncedAt = lastSyncedAt; self.error = error
    }
}
