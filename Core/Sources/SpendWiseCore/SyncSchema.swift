import Foundation

/// A row's synced fields: Int64, Double, String or nil; references as the other row's uid.
public typealias Fields = [String: Any?]

/// One synced table (Android's sync/SyncSchema.kt, unchanged): every synced table has a `uid`
/// column, the row's permanent id on every device and its document id in Firestore
/// (`users/{account}/{table}/{uid}`). References travel as the other row's uid.
public struct SyncTable: Sendable {
    public let name: String
    /// Columns that sync, references included.
    public let columns: [String]
    /// Reference columns and the table they point to.
    public let refs: [String: String]
    /// References that must resolve before the row can exist (NOT NULL foreign keys).
    public let required: Set<String>
    /// How a new uid is made, as SQL over NEW; random unless devices must agree on it.
    public let uidSql: String
    /// Derived uids are recomputed when their parents' uids change.
    public let derivedUid: Bool
    /// A fixed local id (the one-row settings table).
    public let fixedId: Int64?

    init(_ name: String, _ columns: [String], refs: [String: String] = [:], required: Set<String> = [],
         uidSql: String = SyncSchema.randomUid, derivedUid: Bool = false, fixedId: Int64? = nil) {
        self.name = name; self.columns = columns; self.refs = refs; self.required = required
        self.uidSql = uidSql; self.derivedUid = derivedUid; self.fixedId = fixedId
    }
}

public enum SyncSchema {
    static let randomUid = "lower(hex(randomblob(16)))"
    /// The epoch milliseconds in SQL.
    static let nowMs = "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)"

    /// Parents before children: a row is applied once what it points to exists.
    public static let tables: [SyncTable] = [
        SyncTable("stores", ["name"]),
        SyncTable("categories", ["name", "color"]),
        SyncTable("master_items", ["name", "averagePrice", "lastPrice", "lowestPrice", "highestPrice", "purchaseCount", "lastPurchaseDate", "totalQuantity"]),
        SyncTable("shopping_lists", ["name", "createdDate", "completedDate", "isCompleted", "storeId", "categoryId"],
                  refs: ["storeId": "stores", "categoryId": "categories"]),
        SyncTable("shopping_items", ["listId", "itemName", "estimatedPrice", "actualPrice", "quantity", "unit", "purchased", "orderIndex", "notes", "storeId", "isTracked"],
                  refs: ["listId": "shopping_lists", "storeId": "stores"], required: ["listId"]),
        SyncTable("store_item_prices", ["masterItemId", "storeId", "lastPrice", "lowestPrice", "highestPrice", "lastUpdated"],
                  refs: ["masterItemId": "master_items", "storeId": "stores"], required: ["masterItemId", "storeId"],
                  // One price per item and store, so both devices must name it the same way
                  uidSql: "(SELECT uid FROM master_items WHERE id = NEW.masterItemId) || '_' || (SELECT uid FROM stores WHERE id = NEW.storeId)",
                  derivedUid: true),
        SyncTable("ai_reports", ["createdAt", "request", "periodStart", "periodEnd", "title", "content"]),
        SyncTable("app_settings", ["currencySymbol", "lastConversionRate"], uidSql: "'settings'", fixedId: 0),
    ]

    public static let byName: [String: SyncTable] = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0) })

    /// Sync's bookkeeping, next to the app's tables.
    static let bookkeeping = [
        // Rows changed since they were last uploaded. Keyed by rowid: a new row has no uid yet when the trigger runs.
        "CREATE TABLE IF NOT EXISTS sync_outbox (tbl TEXT NOT NULL, rid INTEGER NOT NULL, changedAt INTEGER NOT NULL, PRIMARY KEY(tbl, rid))",
        // Rows deleted since the last upload.
        "CREATE TABLE IF NOT EXISTS sync_tombstones (tbl TEXT NOT NULL, uid TEXT NOT NULL, deletedAt INTEGER NOT NULL, PRIMARY KEY(tbl, uid))",
        // Each row as the account last had it: what tells a local edit from an old value.
        "CREATE TABLE IF NOT EXISTS sync_base (tbl TEXT NOT NULL, uid TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(tbl, uid))",
        // clock: the latest change time heard from the account. mode 0 off, 1 recording, 2 applying.
        "CREATE TABLE IF NOT EXISTS sync_flags (id INTEGER PRIMARY KEY, mode INTEGER NOT NULL, clock INTEGER NOT NULL DEFAULT 0)",
        "INSERT OR IGNORE INTO sync_flags (id, mode, clock) VALUES (0, 0, 0)",
    ]

    static let recording = "(SELECT mode FROM sync_flags WHERE id = 0) = 1"

    /// A change's time: now, or just after the latest change heard from the account if this clock is behind.
    static let changeTime = "MAX(\(nowMs), (SELECT clock FROM sync_flags WHERE id = 0) + 1)"

    public static let modeOff = 0
    public static let modeRecording = 1
    public static let modeApplying = 2

    /// Recreated on every open, so a newer app version can change them without a migration.
    public static func installTriggers(_ db: SQLiteDB) throws {
        for sql in bookkeeping { try db.execute(sql) }
        for t in tables {
            let n = t.name
            for suffix in ["uid_new", "uid_keep", "uid_derive", "out_ins", "out_upd", "out_del"] {
                try db.execute("DROP TRIGGER IF EXISTS sync_\(n)_\(suffix)")
            }
            if t.derivedUid {
                try db.execute("CREATE TRIGGER sync_\(n)_uid_new AFTER INSERT ON \(n) WHEN NEW.uid IS NOT \(t.uidSql) " +
                               "BEGIN UPDATE \(n) SET uid = \(t.uidSql) WHERE rowid = NEW.rowid; END")
                try db.execute("CREATE TRIGGER sync_\(n)_uid_derive AFTER UPDATE ON \(n) WHEN NEW.uid IS NOT \(t.uidSql) " +
                               "BEGIN UPDATE \(n) SET uid = \(t.uidSql) WHERE rowid = NEW.rowid; END")
            } else {
                try db.execute("CREATE TRIGGER sync_\(n)_uid_new AFTER INSERT ON \(n) WHEN NEW.uid IS NULL " +
                               "BEGIN UPDATE \(n) SET uid = \(t.uidSql) WHERE rowid = NEW.rowid; END")
                // An update from an object built without its uid must not lose it
                try db.execute("CREATE TRIGGER sync_\(n)_uid_keep AFTER UPDATE ON \(n) WHEN NEW.uid IS NULL AND OLD.uid IS NOT NULL " +
                               "BEGIN UPDATE \(n) SET uid = OLD.uid WHERE rowid = NEW.rowid; END")
            }
            // Delete, then insert: never OR REPLACE (an outer statement's conflict clause applies to triggers too)
            let record = "DELETE FROM sync_outbox WHERE tbl = '\(n)' AND rid = NEW.rowid; " +
                "INSERT INTO sync_outbox (tbl, rid, changedAt) VALUES ('\(n)', NEW.rowid, \(changeTime));"
            // Putting a deleted row back (undo) cancels its pending delete
            let undelete = "DELETE FROM sync_tombstones WHERE tbl = '\(n)' AND uid = NEW.uid;"
            try db.execute("CREATE TRIGGER sync_\(n)_out_ins AFTER INSERT ON \(n) WHEN \(recording) BEGIN \(record) \(undelete) END")
            try db.execute("CREATE TRIGGER sync_\(n)_out_upd AFTER UPDATE ON \(n) WHEN \(recording) BEGIN \(record) \(undelete) END")
            try db.execute("CREATE TRIGGER sync_\(n)_out_del AFTER DELETE ON \(n) WHEN \(recording) AND OLD.uid IS NOT NULL BEGIN " +
                           "DELETE FROM sync_tombstones WHERE tbl = '\(n)' AND uid = OLD.uid; " +
                           "INSERT INTO sync_tombstones (tbl, uid, deletedAt) VALUES ('\(n)', OLD.uid, \(changeTime)); " +
                           "DELETE FROM sync_outbox WHERE tbl = '\(n)' AND rid = OLD.rowid; END")
        }
    }

    /// Rows written before the triggers existed (a fresh install's seeded category).
    public static func fillMissingUids(_ db: SQLiteDB) throws {
        for t in tables {
            if t.derivedUid {
                let value = t.uidSql.replacingOccurrences(of: "NEW.", with: "\(t.name).")
                try db.execute("UPDATE `\(t.name)` SET uid = \(value) WHERE uid IS NOT \(value)")
            } else {
                try db.execute("UPDATE `\(t.name)` SET uid = \(t.uidSql) WHERE uid IS NULL")
            }
        }
    }

    public static func heard(_ db: SQLiteDB, _ time: Int64) throws {
        try db.execute("UPDATE sync_flags SET clock = MAX(clock, \(time)) WHERE id = 0")
    }

    public static func setMode(_ db: SQLiteDB, _ mode: Int) throws {
        try db.execute("UPDATE sync_flags SET mode = \(mode) WHERE id = 0")
    }
}
