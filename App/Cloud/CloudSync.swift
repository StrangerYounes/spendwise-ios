import FirebaseFirestore
import Foundation
import UIKit
import SpendWiseCore

/// Keeps this phone's database and the signed-in account's copy in Firestore in step, for Premium
/// (Android sync/CloudSync.kt; the same layout, fields and merge rules, so an iPhone and an Android
/// phone share one account). The phone's database stays the one the app reads:
///
///  - Up: the database's triggers record every change (SyncSchema). Each changed row goes up in a
///    small Firestore transaction that writes only the fields this phone changed, and only those the
///    account hasn't changed more recently. Offline, changes wait on the phone.
///  - Down: a live listener per table applies the account's changes field by field (SyncMerge),
///    keeping this phone's newer edits that haven't gone up yet.
///  - Joining: the first time a phone syncs with an account, rows that are "the same" on both sides
///    are matched rather than doubled, the account's version wins for those, the rest goes up.
///
/// Firestore: `users/{account}/{table}/{row uid}` (or `spaces/{family}/…`) holds the row's fields,
/// `_t` (when each field last changed) and `_deleted`.
/// Firestore's names for sync (the same as Android's).
enum SyncNames {
    static let users = "users"
    static let spaces = "spaces"
    static let space = "space"
    static let invites = "invites"
    static let times = "_t"
    static let deleted = "_deleted"
    static let by = "_by"
}

@MainActor
final class CloudSync {
    static let users = SyncNames.users
    static let spaces = SyncNames.spaces
    static let space = SyncNames.space
    static let invites = SyncNames.invites

    private unowned let cloud: Cloud
    private unowned let model: AppModel
    private let store: SyncStore
    private let connectivity: Connectivity
    private let prefs = UserDefaults.standard

    /// Where a signed-in phone syncs: the account's own data, or its family's.
    struct Target: Equatable {
        let user: SignedIn
        let space: String?
        var key: String { space.map { "\(CloudSync.spaces)/\($0)" } ?? "\(CloudSync.users)/\(user.uid)" }
    }

    private var target: Target?
    private var spaceFor: String?
    private var knownSpace: String?
    private var spaceListener: ListenerRegistration?
    private var familyListener: ListenerRegistration?
    private var listeners: [ListenerRegistration] = []
    private var fresh: Set<String> = []
    private var running = false
    private var generation = 0
    private var pushing = false
    private var pushAgain = false
    private var pushTask: Task<Void, Never>?
    private var retryPause: Double = 5
    /// Rows heard about before what they point to (an item before its list).
    private var waitingRows: [String: (SyncTable, String, RemoteRow)] = [:]

    /// This install, written next to each change for troubleshooting.
    private lazy var deviceId: String = {
        if let id = prefs.string(forKey: "sync.device") { return id }
        let id = UUID().uuidString.lowercased()
        prefs.set(id, forKey: "sync.device")
        return id
    }()

    private var fs: Firestore { Cloud.firestore }

    init(cloud: Cloud, model: AppModel) {
        self.cloud = cloud
        self.model = model
        store = SyncStore(model.database)
        connectivity = Connectivity()
        connectivity.changed = { [weak self] online in
            guard let self else { return }
            if online { self.pushSoon() } else { self.refreshStatus() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finishInBackground() }
        }
    }

    // MARK: - What to sync with

    /// Re-evaluates the target when the account, the plan or the family may have changed.
    func update() {
        guard let user = cloud.user else {
            spaceListener?.remove(); spaceListener = nil; spaceFor = nil; knownSpace = nil
            setTarget(nil)
            return
        }
        if spaceFor != user.uid { watchSpace(user) }
        // A family's phones sync whatever their own plan: the family's owner has Premium
        setTarget(knownSpace != nil || cloud.tier.syncs ? Target(user: user, space: knownSpace) : nil)
    }

    /// The account's own document says which family (if any) its phones sync with.
    private func watchSpace(_ user: SignedIn) {
        spaceListener?.remove()
        spaceFor = user.uid
        let key = "sync.space_of_" + user.uid
        // Known before the network answers, so starting offline doesn't briefly sync the wrong place
        knownSpace = prefs.string(forKey: key)
        spaceListener = fs.collection(Self.users).document(user.uid).addSnapshotListener(includeMetadataChanges: true) { [weak self] d, _ in
            // Not this phone's own write before the server took it
            guard let d, !d.metadata.hasPendingWrites, d.exists || !d.metadata.isFromCache else { return }
            let space = d.get(SyncNames.space) as? String
            Task { @MainActor in
                guard let self, self.spaceFor == user.uid else { return }
                self.prefs.set(space, forKey: key)
                if self.knownSpace != space {
                    self.knownSpace = space
                    self.update()
                }
            }
        }
    }

    private func setTarget(_ t: Target?) {
        guard t != target else { return }
        stopRun()
        target = t
        if let t { start(t) } else { stopped() }
    }

    private func stopRun() {
        generation += 1
        listeners.forEach { $0.remove() }
        listeners = []
        familyListener?.remove()
        familyListener = nil
        running = false
        fresh = []
        pushTask?.cancel()
    }

    /// Not syncing (signed out, or Free): nothing is recorded; what the account had stays on the phone.
    private func stopped() {
        if prefs.string(forKey: Keys.joined) != nil && cloud.user == nil {
            // Signed out: forget the account, so signing in again (or as someone else) joins afresh
            try? store.reset()
            prefs.removeObject(forKey: Keys.joined)
            Cloud.clearFirestoreLater()
        } else {
            try? store.setMode(SyncSchema.modeOff)
        }
        waitingRows = [:]
        cloud.family = nil
        cloud.syncStatus = SyncStatus()
    }

    private enum Keys { static let joined = "sync.joined_account" }

    // MARK: - Running

    private func start(_ t: Target) {
        let gen = generation
        if t.space != nil { watchFamily(t) } else { cloud.family = nil }
        Task { @MainActor in
            do {
                if self.prefs.string(forKey: Keys.joined) != t.key {
                    self.cloud.syncStatus = SyncStatus(state: .joining)
                    try await self.join(t)
                    guard gen == self.generation else { return }
                    self.prefs.set(t.key, forKey: Keys.joined)
                } else {
                    // Changes made while sync was off (Premium switched off and on) weren't recorded: find them
                    if try self.store.mode() != SyncSchema.modeRecording { try self.store.transaction { try self.store.catchUp(now: nowMillis()) } }
                    try self.store.setMode(SyncSchema.modeRecording)
                }
                guard gen == self.generation else { return }
                self.running = true
                self.retryPause = 5
                self.refreshStatus(.syncing)
                self.listen(t, gen)
                self.pushSoon()
            } catch {
                self.failed(error, gen)
            }
        }
    }

    private func failed(_ error: Error, _ gen: Int) {
        guard gen == generation, let t = target else { return }
        print("SpendWise: sync stopped, retrying: \(error)")
        cloud.syncStatus.state = connectivity.online ? .error : .offline
        cloud.syncStatus.error = UserErrors.message(error, L("sync_failed_short"))
        let pause = retryPause
        retryPause = min(retryPause * 2, 120)
        stopRun()
        let next = generation
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(pause))
            guard next == self.generation, self.target == t else { return }
            self.start(t)
        }
    }

    private func collection(_ t: Target, _ table: SyncTable) -> CollectionReference {
        fs.document(t.key).collection(table.name)
    }

    private func listen(_ t: Target, _ gen: Int) {
        for table in SyncSchema.tables {
            let reg = collection(t, table).addSnapshotListener(includeMetadataChanges: true) { [weak self] snap, error in
                Task { @MainActor in
                    guard let self, gen == self.generation else { return }
                    if let error {
                        if Cloud.isDenied(error), t.space != nil { self.removedFromFamily(t.user); return }
                        self.failed(error, gen)
                        return
                    }
                    guard let snap else { return }
                    self.apply(table, snap)
                    if !snap.metadata.isFromCache { self.fresh.insert(table.name) }
                    if self.fresh.count == SyncSchema.tables.count { self.refreshStatus() }
                }
            }
            listeners.append(reg)
        }
    }

    // MARK: - Family

    private func watchFamily(_ t: Target) {
        guard let space = t.space else { return }
        familyListener = fs.collection(Self.spaces).document(space).addSnapshotListener { [weak self] d, error in
            Task { @MainActor in
                guard let self, self.target == t else { return }
                if let error {
                    if Cloud.isDenied(error) { self.removedFromFamily(t.user) }
                    return
                }
                guard let d else { return }
                let f = d.exists ? Family.from(d, me: t.user.uid) : nil
                if let f, f.members.contains(where: { $0.uid == t.user.uid }) {
                    self.cloud.family = f
                } else if !d.metadata.isFromCache {
                    // Only conclude that from the server, not from a stale offline copy
                    self.removedFromFamily(t.user)
                }
            }
        }
    }

    /// Taken off the family (or it was closed): back to the account's own data; the lists stay.
    private func removedFromFamily(_ user: SignedIn) {
        prefs.removeObject(forKey: "sync.space_of_" + user.uid)
        cloud.family = nil
        knownSpace = nil
        fs.collection(Self.users).document(user.uid).setData([Self.space: NSNull()], merge: true)
        update()
    }

    // MARK: - Joining an account

    private func join(_ t: Target) async throws {
        var remote: [String: [String: RemoteRow]] = [:]
        for table in SyncSchema.tables {
            let docs = try await collection(t, table).getDocuments(source: .server).documents
            var rows: [String: RemoteRow] = [:]
            for d in docs { rows[d.documentID] = Self.remoteRow(d, table) }
            remote[table.name] = rows
        }
        try store.applying {
            // What the phone knew of another account or family doesn't apply here
            try store.clearBookkeeping()
            waitingRows = [:]
            // Rows that are the same on both sides take the account's uid
            for table in SyncSchema.tables {
                if table.derivedUid { try store.refreshDerivedUids(); continue }
                if table.fixedId != nil { continue }
                let rows = remote[table.name] ?? [:]
                var byKey: [String: [String]] = [:]
                for (uid, row) in rows where !row.deleted {
                    if let key = SyncMerge.naturalKey(table.name, row.values) { byKey[key, default: []].append(uid) }
                }
                for local in try store.allRows(table) {
                    if rows[local.uid] != nil {
                        for k in byKey.keys { byKey[k]?.removeAll { $0 == local.uid } }
                        continue
                    }
                    guard let key = SyncMerge.naturalKey(table.name, local.fields),
                          let match = try byKey[key]?.first(where: { try store.row(table, uid: $0) == nil }) else { continue }
                    byKey[key]?.removeAll { $0 == match }
                    try store.setUid(table, rid: local.rid, match)
                }
            }
            // The account's rows, then the phone's own ones go up
            for table in SyncSchema.tables {
                for (uid, row) in remote[table.name] ?? [:] { try applyRow(table, uid, row) }
            }
            try retryWaiting()
            let now = nowMillis()
            for table in SyncSchema.tables {
                let rows = remote[table.name] ?? [:]
                for local in try store.allRows(table) where rows[local.uid] == nil { try store.markPending(table, rid: local.rid, at: now) }
            }
        }
        model.refresh()
    }

    // MARK: - Down

    private func apply(_ table: SyncTable, _ snap: QuerySnapshot) {
        let changes = snap.documentChanges.filter { $0.type != .removed && !$0.document.metadata.hasPendingWrites }
        guard !changes.isEmpty else { return }
        do {
            try store.applying {
                for change in changes {
                    let d = change.document
                    do { try applyRow(table, d.documentID, Self.remoteRow(d, table)) } catch { print("SpendWise: couldn't apply \(table.name)/\(d.documentID): \(error)") }
                }
                try retryWaiting()
            }
        } catch {
            print("SpendWise: applying \(table.name) failed: \(error)")
        }
        model.refresh()
    }

    /// Applies the account's row; one that points at something not here yet waits for it.
    private func applyRow(_ table: SyncTable, _ uid: String, _ remote: RemoteRow) throws {
        if let latest = remote.times.values.max() { try store.heard(latest) }
        let local = try store.row(table, uid: uid)
        let key = "\(table.name)/\(uid)"
        if remote.deleted {
            if let local {
                try store.delete(table, uid: uid)
                try store.clearPendingRow(table, rid: local.rid)
            }
            try store.clearBase(table, uid: uid)
            waitingRows[key] = nil
            return
        }
        let base = try store.base(table, uid: uid)
        let pendingAt = try local.flatMap { try store.pendingFor(table, rid: $0.rid) }
        let merged = SyncMerge.merge(local: local?.fields, base: base, pendingAt: pendingAt, remote: remote, columns: table.columns)
        let unchanged = local != nil && table.columns.allSatisfy { SyncMerge.same(local!.fields[$0] ?? nil, merged[$0] ?? nil) }
        if !unchanged, !(try store.write(table, uid: uid, fields: merged, existing: local)) {
            waitingRows[key] = (table, uid, remote)
            return
        }
        waitingRows[key] = nil
        var known: Fields = [:]
        for c in table.columns { known[c] = remote.values.keys.contains(c) ? (remote.values[c] ?? nil) : (base?[c] ?? nil) }
        try store.setBase(table, uid: uid, known)
    }

    private func retryWaiting() throws {
        var progress = true
        while progress && !waitingRows.isEmpty {
            let before = waitingRows.count
            for (_, (table, uid, row)) in waitingRows { try? applyRow(table, uid, row) }
            progress = waitingRows.count < before
        }
    }

    // MARK: - Up

    /// After every change on the phone: upload soon (changes made together go up together).
    func localChanged() { if running { pushSoon() } }

    private func pushSoon() {
        guard running, let t = target else { return }
        pushTask?.cancel()
        let gen = generation
        pushTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, gen == self.generation else { return }
            await self.push(t, gen)
        }
    }

    private func push(_ t: Target, _ gen: Int) async {
        if pushing { pushAgain = true; return }
        guard connectivity.online else { refreshStatus(); return }
        pushing = true
        defer { pushing = false }
        repeat {
            pushAgain = false
            do {
                try await pushAll(t, gen)
                retryPause = 5
            } catch {
                print("SpendWise: upload failed: \(error)")
                refreshStatus()
                // Try again later (the connection may be half there)
                let pause = retryPause
                retryPause = min(retryPause * 2, 60)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(pause))
                    if gen == self.generation { self.pushSoon() }
                }
                return
            }
        } while pushAgain && gen == generation
        refreshStatus()
    }

    private func pushAll(_ t: Target, _ gen: Int) async throws {
        let tombstones = try store.tombstones()
        let pending = try store.pending()
        if tombstones.isEmpty && pending.isEmpty { return }
        refreshStatus(.syncing)
        var failure: Error?
        for s in tombstones where gen == generation {
            do { try await pushDelete(t, s) } catch { failure = error }
        }
        // Parents first (pending() is in table order), so another phone can place each row as it arrives
        for p in pending where gen == generation {
            do { try await pushRow(t, p) } catch { failure = error }
        }
        if let failure { throw failure }
    }

    /// The transaction's answer: what the account had, and what this phone wrote.
    private final class Written: @unchecked Sendable {
        var remote: RemoteRow?
        var fields: Set<String> = []
    }

    private func pushRow(_ t: Target, _ p: Pending) async throws {
        guard let table = SyncSchema.byName[p.table] else { try store.clearPending(p); return }
        guard let row = try store.row(table, rid: p.rid) else { try store.clearPending(p); return }
        let base = try store.base(table, uid: row.uid)
        // A reference that has no uid yet can't be described to another phone: wait for it
        if table.refs.keys.contains(where: { (row.fields[$0] ?? nil) == nil && table.required.contains($0) }) { return }
        let changed = SyncMerge.localChanges(row.fields, base: base, columns: table.columns)
        if changed.isEmpty { try store.clearPending(p); return }
        let ref = collection(t, table).document(row.uid)
        let fields = row.fields
        let device = deviceId
        let hadBase = base != nil
        let written = Written()
        _ = try await fs.runTransaction { tx, errorPointer -> Any? in
            let snap: DocumentSnapshot
            do { snap = try tx.getDocument(ref) } catch { errorPointer?.pointee = error as NSError; return nil }
            let remote = snap.exists ? CloudSync.remoteRow(snap, table) : nil
            written.remote = remote
            // Deleted on another phone: that wins, unless this is the row put back after the delete (undo)
            let revive = remote?.deleted == true && !hadBase && p.changedAt > (remote?.deletedAt ?? 0)
            if remote?.deleted == true && !revive { written.fields = []; return nil }
            let write = revive ? changed : SyncMerge.writable(changed, changedAt: p.changedAt, remote: remote)
            written.fields = write
            if !write.isEmpty {
                var data: [String: Any] = [:]
                var times: [String: Any] = [:]
                for c in write {
                    data[c] = CloudSync.firestoreValue(fields[c] ?? nil)
                    times[c] = p.changedAt
                }
                if remote == nil || revive {
                    data[SyncNames.deleted] = false
                    times[SyncNames.deleted] = p.changedAt
                }
                data[SyncNames.times] = times
                data[SyncNames.by] = device
                tx.setData(data, forDocument: ref, merge: true)
            }
            return nil
        }
        try store.transaction {
            if written.remote?.deleted == true && written.fields.isEmpty {
                // The listener removes it here; nothing to upload
                try store.clearPending(p)
                return
            }
            var known: Fields = [:]
            for c in table.columns {
                if written.fields.contains(c) { known[c] = fields[c] ?? nil }
                else if let r = written.remote, r.values.keys.contains(c) { known[c] = r.values[c] ?? nil }
                else { known[c] = base?[c] ?? nil }
            }
            try store.setBase(table, uid: row.uid, known)
            try store.clearPending(p)
        }
    }

    private func pushDelete(_ t: Target, _ s: Tombstone) async throws {
        let table = SyncSchema.byName[s.table]
        if let table {
            let ref = collection(t, table).document(s.uid)
            let device = deviceId
            _ = try await fs.runTransaction { tx, errorPointer -> Any? in
                let snap: DocumentSnapshot
                do { snap = try tx.getDocument(ref) } catch { errorPointer?.pointee = error as NSError; return nil }
                // Never uploaded: nothing to tell other phones
                guard snap.exists else { return nil }
                let remote = CloudSync.remoteRow(snap, table)
                if remote.deleted && remote.deletedAt >= s.deletedAt { return nil }
                tx.setData([SyncNames.deleted: true, SyncNames.times: [SyncNames.deleted: s.deletedAt], SyncNames.by: device], forDocument: ref, merge: true)
                return nil
            }
        }
        try store.transaction {
            if let table { try store.clearBase(table, uid: s.uid) }
            try store.clearTombstone(s)
        }
    }

    // MARK: - Status

    private func refreshStatus(_ state: SyncStatus.State? = nil) {
        guard target != nil else { return }
        let waiting = (try? store.waitingCount()) ?? 0
        var s = cloud.syncStatus
        let next: SyncStatus.State
        if !connectivity.online { next = .offline } else if let state { next = state } else if waiting > 0 { next = .syncing } else { next = .synced }
        s.state = next
        s.waiting = waiting
        s.error = nil
        if next == .synced { s.lastSyncedAt = nowMillis() }
        cloud.syncStatus = s
    }

    /// iOS keeps an app running only briefly in the background: finish waiting uploads in that time
    /// (Android's background job uploads later; here they go up when the app is next opened).
    private func finishInBackground() {
        guard running, let t = target, ((try? store.waitingCount()) ?? 0) > 0 else { return }
        var id: UIBackgroundTaskIdentifier = .invalid
        id = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(id) }
        let gen = generation
        Task { @MainActor in
            await self.push(t, gen)
            UIApplication.shared.endBackgroundTask(id)
        }
    }

    // MARK: - Firestore values

    nonisolated static func remoteRow(_ d: DocumentSnapshot, _ t: SyncTable) -> RemoteRow {
        let data = d.data() ?? [:]
        var times: [String: Int64] = [:]
        for (k, v) in data[SyncNames.times] as? [String: Any] ?? [:] {
            if let n = v as? NSNumber { times[k] = n.int64Value }
        }
        var values: Fields = [:]
        for c in t.columns where data.keys.contains(c) { values[c] = fieldValue(data[c]) }
        let deleted = (data[SyncNames.deleted] as? Bool) == true
        let deletedAt = times.removeValue(forKey: SyncNames.deleted) ?? 0
        return RemoteRow(values: values, times: times, deleted: deleted, deletedAt: deletedAt)
    }

    /// Firestore's numbers as the database's: booleans as 1/0, integers as Int64, the rest Double.
    nonisolated static func fieldValue(_ v: Any?) -> Any? {
        switch v {
        case nil: return nil
        case is NSNull: return nil
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? Int64(1) : Int64(0) }
            if CFNumberIsFloatType(n as CFNumber) { return n.doubleValue }
            return n.int64Value
        case let ts as Timestamp: return Int64((ts.dateValue().timeIntervalSince1970 * 1000).rounded())
        default: return "\(v!)"
        }
    }

    nonisolated static func firestoreValue(_ v: Any?) -> Any {
        switch v {
        case nil: return NSNull()
        case let i as Int64: return NSNumber(value: i)
        case let i as Int: return NSNumber(value: i)
        case let d as Double: return NSNumber(value: d)
        case let b as Bool: return NSNumber(value: b ? 1 : 0)
        case let s as String: return s
        default: return "\(v!)"
        }
    }
}
