//
//  SharedFridgeManager.swift
//  FrydgeRecipes
//
//  Created by Josh on 20/11/2025.
//

import Foundation
import CloudKit
import Combine
import UserNotifications

/// Manages all CloudKit work for shared fridges.
/// - Custom zone: "FrydgeFridgeZone"
/// - Anchor type: "ShareAnchor"
/// - Item type: "StoredIngredient"
@MainActor
final class SharedFridgeManager: ObservableObject {

    enum ShareScope {
        case owned
        case incoming
    }

    @Published var owned: [CKRecord] = []          // anchors owned by me
    @Published var incoming: [CKRecord] = []       // anchors shared with me
    @Published var itemsByFridge: [CKRecord.ID: [CKRecord]] = [:]
    @Published var namesByFridge: [CKRecord.ID: String] = [:]
    @Published var emojiByFridge: [CKRecord.ID: String] = [:]
    @Published var sharesByFridge: [CKRecord.ID: CKShare] = [:] // cached shares for faster UI
    @Published var errorMessage: String?

    // Invite/UI coordination
    @Published var hasPendingInvites: Bool = false

    // MARK: - Compatibility / UI aliases

    /// Combined list used by pickers (owned + incoming).
    var sharedFrydgeAnchors: [CKRecord] { owned + incoming }

    /// Alias used by some UI code.
    var emojisByFridge: [CKRecord.ID: String] { emojiByFridge }

    /// Convenience alias matching ShoppingList move flow naming.
    func refreshSharedFrydges() async {
        await reloadFridges()
    }

    // MARK: - Structured anchor payload (itemsJSON)

    struct SharedFrydgeItem: Codable, Hashable {
        var id: UUID
        var name: String
        var quantity: String
        var unit: String
        var location: String
        var dietaryTags: [String]
        var expirationDate: Date
        /// StoredIngredient.ItemLifecycle raw value ("fridge"/"leftover").
        /// Optional so itemsJSON written before this field existed still decodes.
        var lifecycle: String?

        init(
            id: UUID = UUID(),
            name: String,
            quantity: String,
            unit: String,
            location: String,
            dietaryTags: [String],
            expirationDate: Date,
            lifecycle: String? = nil
        ) {
            self.id = id
            self.name = name
            self.quantity = quantity
            self.unit = unit
            self.location = location
            self.dietaryTags = dietaryTags
            self.expirationDate = expirationDate
            self.lifecycle = lifecycle
        }
    }

    /// Returns decoded items stored in the anchor's `itemsJSON` field.
    func itemsDetailed(for anchor: CKRecord, scope: ShareScope) -> [SharedFrydgeItem] {
        if let json = anchor["itemsJSON"] as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([SharedFrydgeItem].self, from: data) {
            return decoded
        }
        return []
    }

    /// Persists the full structured list into the anchor's `itemsJSON` field.
    /// Uses the correct database for scope (owned=private, incoming=shared).
    /// IMPORTANT: Participants do nothing (owner-only writes).
    func setItemsDetailed(_ items: [SharedFrydgeItem], for anchor: CKRecord, scope: ShareScope) async {
        guard isOwnerScope(scope) else { return }

        let db = dbFor(scope: scope)
        do {
            // Always refetch so we don't overwrite newer server values.
            let fresh = try await db.record(for: anchor.recordID)
            let data = try JSONEncoder().encode(items)
            let json = String(data: data, encoding: .utf8) ?? "[]"
            fresh["itemsJSON"] = json as CKRecordValue
            _ = try await db.save(fresh)

            // Update caches for name/emoji immediately for snappy UI.
            if let name = fresh[fridgeNameKey] as? String {
                namesByFridge[fresh.recordID] = name
            }
            if let emoji = fresh[fridgeEmojiKey] as? String {
                emojiByFridge[fresh.recordID] = emoji
            }
        } catch {
            self.errorMessage = "Failed to save shared frydge items: \(error.localizedDescription)"
        }
    }

    // Keep Combine subscriptions alive
    private var cancellables: Set<AnyCancellable> = []

    let container: CKContainer
    let zoneID: CKRecordZone.ID

    // Zone readiness. The private "FrydgeFridgeZone" is created lazily on first
    // launch, and both `init` and the view's `.task` reload race to query it.
    // These coalesce every caller onto one in-flight creation attempt so no
    // query runs against a zone that doesn't exist yet.
    private var zoneReady = false
    private var zoneSetupTask: Task<Bool, Never>?

    // StoredIngredient linkage field (MUST be written when saving items)
    private let itemFridgeRefKey = "fridge"

    // ShareAnchor display fields
    private let fridgeNameKey = "name"
    private let fridgeEmojiKey = "emoji"

    // MARK: - Owner gating (critical)

    private func isOwnerScope(_ scope: ShareScope) -> Bool {
        scope == .owned
    }

    // MARK: - De-dupe support (prevents repeats when saving/moving)

    private struct ItemFingerprint: Hashable {
        let name: String
        let quantity: String
        let unit: String
        let location: String
        let dietaryTags: [String]
        let expirationDay: Date // normalised to start-of-day
    }

    private func normalizeStorageLocation(_ raw: String) -> String {
        FoodStorageClassifier.normalize(raw)
    }

    // MARK: - Expiry rule (match FrydgeManager behaviour)

    private func fingerprint(for record: CKRecord) -> ItemFingerprint {
        let name = ((record["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let qty = (record["quantity"] as? String)
            ?? (record["quantity"] as? NSNumber)?.stringValue
            ?? ""
        let unit = ((record["unit"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let loc = normalizeStorageLocation((record["location"] as? String) ?? "Dry")
        let tags = ((record["dietaryTags"] as? [String]) ?? []).sorted()
        let exp = (record["expirationDate"] as? Date) ?? Date()
        let day = Calendar.current.startOfDay(for: exp)

        return ItemFingerprint(
            name: name.lowercased(),
            quantity: qty.trimmingCharacters(in: .whitespacesAndNewlines),
            unit: unit.lowercased(),
            location: loc,
            dietaryTags: tags,
            expirationDay: day
        )
    }

    private func fingerprint(for item: SharedFrydgeItem) -> ItemFingerprint {
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let qty = item.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = item.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let loc = normalizeStorageLocation(item.location)
        let tags = item.dietaryTags.sorted()
        let day = Calendar.current.startOfDay(for: item.expirationDate)

        return ItemFingerprint(
            name: name.lowercased(),
            quantity: qty,
            unit: unit.lowercased(),
            location: loc,
            dietaryTags: tags,
            expirationDay: day
        )
    }

    private func existingFingerprints(for anchor: CKRecord, scope: ShareScope) async -> Set<ItemFingerprint> {
        // Prefer cache if already loaded
        if let cached = itemsByFridge[anchor.recordID], !cached.isEmpty {
            return Set(cached.map { fingerprint(for: $0) })
        }

        // Otherwise query once, then cache it
        await loadItems(for: anchor, scope: scope)
        let recs = itemsByFridge[anchor.recordID] ?? []
        return Set(recs.map { fingerprint(for: $0) })
    }

    init(containerID: String) {
        self.container = CKContainer(identifier: containerID)
        self.zoneID = CKRecordZone.ID(
            zoneName: "FrydgeFridgeZone",
            ownerName: CKCurrentUserDefaultName
        )

        // Keep manager in sync with incoming share links + acceptance events
        setupInviteObservers()
        refreshInviteState()

        Task {
            // Passive startup work. This runs at app launch, often before the
            // user has finished signing in, so any CloudKit failure here is
            // logged rather than stored in `errorMessage`: that slot drives the
            // "Sharing Error" alert, and a stale launch-time error used to pop
            // the moment the fridge screen first appeared.
            await reloadFridges()

            // ✅ best-effort: make sure subscriptions exist (idempotent)
            await configureSharedFrydgeNotificationsIfNeeded()
        }
    }

    // MARK: - Invite handling (keeps SharedFridgeView responsive)

    /// Updates `hasPendingInvites` from the shared PendingInvites singleton.
    func refreshInviteState() {
        self.hasPendingInvites = !PendingInvites.shared.metas.isEmpty
    }

    private func setupInviteObservers() {
        // Share metadata received (invite link opened)
        NotificationCenter.default.publisher(for: .cloudShareMetadataReceived)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.refreshInviteState()
                    await self.reloadFridges()
                }
            }
            .store(in: &cancellables)

        // Share accepted (either auto-accept or user accepted in UI)
        NotificationCenter.default.publisher(for: .cloudShareAccepted)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.refreshInviteState()
                    await self.reloadFridges()
                }
            }
            .store(in: &cancellables)

        // Share accept failed
        NotificationCenter.default.publisher(for: .cloudShareAcceptFailed)
            .sink { [weak self] note in
                guard let self else { return }
                Task { @MainActor in
                    self.refreshInviteState()
                    // Accepting already retries transient CloudKit hiccups (see
                    // PendingInvites.accept), so anything that reaches here is a
                    // real failure worth a plain-English message instead of a raw
                    // "CKErrorDomain error 3" dump.
                    if let err = note.userInfo?["error"] as? Error {
                        let ckError = err as? CKError
                        self.errorMessage = "Invite acceptance failed: \(ckError?.friendlyMessage ?? err.localizedDescription)"
                    }
                }
            }
            .store(in: &cancellables)

        // ✅ If AppDelegate posts this on push, reload
        NotificationCenter.default.publisher(for: Notification.Name("SharedFrydgeChanged"))
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.reloadFridges()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Reload both owned and incoming shared fridges.
    func reloadFridges() async {
        // Owned anchors live in our private zone, so that zone has to exist
        // before the query runs. Incoming shares live in other people's zones
        // and don't depend on it.
        let privateZoneReady = await ensureZoneReady()

        await withTaskGroup(of: Void.self) { group in
            if privateZoneReady {
                group.addTask { await self.loadOwned() }
            }
            group.addTask { await self.loadIncoming() }
        }

        // Warm the share cache so opening the management UI is instant.
        await withTaskGroup(of: Void.self) { group in
            let ownedAnchors = self.owned
            let incomingAnchors = self.incoming

            group.addTask { await self.prefetchShares(for: ownedAnchors, scope: .owned) }
            group.addTask { await self.prefetchShares(for: incomingAnchors, scope: .incoming) }
        }
    }

    /// Load items for a single shared fridge anchor (ONLY items linked to that anchor).
    func loadItems(for anchor: CKRecord, scope: ShareScope) async {
        let db = dbFor(scope: scope)

        let fridgeID = anchor.recordID
        let zid = fridgeID.zoneID

        // Filter by fridge reference (instead of TRUEPREDICATE)
        let anchorRef = CKRecord.Reference(recordID: fridgeID, action: .none)
        let pred = NSPredicate(format: "%K == %@", itemFridgeRefKey, anchorRef)
        let query = CKQuery(recordType: "StoredIngredient", predicate: pred)

        do {
            // Follow the query cursor: a shared fridge with more than one page
            // of items previously rendered only the first page.
            var recs = try await db.allRecords(matching: query, inZoneWith: zid)

            // Stable order (prevents UI jumpiness)
            recs.sort {
                let d0 = ($0.modificationDate ?? $0.creationDate ?? .distantPast)
                let d1 = ($1.modificationDate ?? $1.creationDate ?? .distantPast)
                if d0 != d1 { return d0 > d1 }
                let n0 = (($0["name"] as? String) ?? "").lowercased()
                let n1 = (($1["name"] as? String) ?? "").lowercased()
                return n0 < n1
            }

            self.itemsByFridge[fridgeID] = recs
        } catch {
            self.itemsByFridge[fridgeID] = []
            self.errorMessage = "Failed to load items: \(error.localizedDescription)"
        }
    }

    // MARK: - Move / Import (FridgeView -> SharedFrydge)

    /// Imports local items into a shared frydge by creating `StoredIngredient` records linked to the anchor.
    /// IMPORTANT: SharedFridgeView renders items by querying `StoredIngredient` where `fridge == anchor`.
    /// So moving items must create `StoredIngredient` records (not only update itemsJSON).
    ///
    /// Creates items in a shared frydge. Works for owned frydges and for incoming
    /// (participant) frydges when the share grants write access — so people can drop
    /// food into a frydge shared with them. Read-only shares throw, surfaced by callers.
    func importItemsIntoSharedFrydge(
        _ items: [SharedFrydgeItem],
        into anchor: CKRecord,
        scope: ShareScope,
        lifecycle: String = "fridge"
    ) async throws -> [CKRecord] {
        guard !items.isEmpty else { return [] }

        let db = dbFor(scope: scope)
        let zid = anchor.recordID.zoneID
        let anchorRef = CKRecord.Reference(recordID: anchor.recordID, action: .none)

        // Build de-dupe set once
        var seen = await existingFingerprints(for: anchor, scope: scope)

        var recordsToSave: [CKRecord] = []
        recordsToSave.reserveCapacity(items.count)

        for item in items {
            let fp = fingerprint(for: item)
            if seen.contains(fp) { continue }
            seen.insert(fp)

            let recID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zid)
            let rec = CKRecord(recordType: "StoredIngredient", recordID: recID)

            // Parent + linkage field used by SharedFridgeView query
            rec.parent = anchorRef
            rec[itemFridgeRefKey] = anchorRef

            let locationNormalized = normalizeStorageLocation(item.location)

            rec["name"] = item.name as CKRecordValue
            rec["quantity"] = item.quantity as CKRecordValue
            rec["unit"] = item.unit as CKRecordValue
            rec["location"] = locationNormalized as CKRecordValue
            rec["expirationDate"] = item.expirationDate as CKRecordValue
            rec["lifecycle"] = (item.lifecycle ?? lifecycle) as CKRecordValue
            if !item.dietaryTags.isEmpty {
                rec["dietaryTags"] = item.dietaryTags as CKRecordValue
            }

            recordsToSave.append(rec)
        }

        guard !recordsToSave.isEmpty else { return [] }

        // Batch save for performance.
        let saved: [CKRecord] = try await withCheckedThrowingContinuation { cont in
            let op = CKModifyRecordsOperation(recordsToSave: recordsToSave, recordIDsToDelete: nil)
            op.savePolicy = .allKeys
            // Atomic: with a non-atomic op a rejected record (e.g. a read-only
            // participant) still reports overall success, so callers would delete
            // the local copy of items that never reached the shared frydge.
            op.isAtomic = true

            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    cont.resume(returning: recordsToSave)
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }

            db.add(op)
        }

        // Update local cache immediately (prevents "duplicate render" feeling from async reload timing)
        let fid = anchor.recordID
        var current = itemsByFridge[fid] ?? []
        let existingIDs = Set(current.map { $0.recordID })
        for r in saved where !existingIDs.contains(r.recordID) {
            current.append(r)
        }
        itemsByFridge[fid] = current

        return saved
    }

    /// Which database an anchor lives in: owned anchors are in our private DB,
    /// everything else arrived via a share.
    func scope(for anchor: CKRecord) -> ShareScope {
        anchor.recordID.zoneID.ownerName == CKCurrentUserDefaultName ? .owned : .incoming
    }

    /// Anchor field the owner toggles in Manage Sharing to let participants scan
    /// receipts into the frydge (stored as 0/1; absent means not approved).
    static let memberReceiptScanKey = "allowMemberReceiptScan"

    /// Whether the owner has approved participants scanning receipts into this frydge.
    func membersMayScanReceipts(_ anchor: CKRecord) -> Bool {
        ((anchor[Self.memberReceiptScanKey] as? Int64) ?? 0) == 1
    }

    /// The owner can always scan into their own frydge; a participant only once
    /// the owner has approved it (and the share still has to grant them edit access).
    func canScanReceipts(into anchor: CKRecord) -> Bool {
        scope(for: anchor) == .owned || membersMayScanReceipts(anchor)
    }

    /// Convenience: imports and then refreshes the destination list cache by loading items.
    /// Works for owned and (write-access) incoming frydges. Returns false if the
    /// import failed, so callers moving items don't delete their local copies.
    @discardableResult
    func importItemsAndReload(
        _ items: [SharedFrydgeItem],
        into anchor: CKRecord,
        scope: ShareScope,
        lifecycle: String = "fridge"
    ) async -> Bool {
        do {
            _ = try await importItemsIntoSharedFrydge(items, into: anchor, scope: scope, lifecycle: lifecycle)
            await loadItems(for: anchor, scope: scope)
            return true
        } catch {
            let message = (error as? CKError)?.code == .permissionFailure
                ? "You only have read access to this shared frydge."
                : error.localizedDescription
            self.errorMessage = "Failed to move items into shared frydge: \(message)"
            return false
        }
    }

    /// Helper to build a SharedFrydgeItem from raw fields (useful if FridgeView doesn't already have SharedFrydgeItem).
    func makeSharedFrydgeItem(
        name: String,
        quantity: String,
        unit: String,
        location: String,
        dietaryTags: [String],
        expirationDate: Date,
        lifecycle: String? = nil
    ) -> SharedFrydgeItem {
        SharedFrydgeItem(
            name: name,
            quantity: quantity,
            unit: unit,
            location: location,
            dietaryTags: dietaryTags,
            expirationDate: expirationDate,
            lifecycle: lifecycle
        )
    }

    // MARK: - Create / Delete

    /// Create a new shared fridge with a given name.
    /// Returns (share, anchor) so UI can present UICloudSharingController.
    func createSharedFridge(named name: String) async throws -> (CKShare, CKRecord) {
        let db = container.privateCloudDatabase

        try await ensureZone()

        // Anchor in custom zone
        let rid = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        let anchor = CKRecord(recordType: "ShareAnchor", recordID: rid)
        anchor["category"] = "Fridge" as CKRecordValue
        anchor[fridgeNameKey] = name as CKRecordValue
        // Default emoji (can be changed later)
        anchor[fridgeEmojiKey] = "🧊" as CKRecordValue

        // Share rooted at anchor
        let share = CKShare(rootRecord: anchor)
        share[CKShare.SystemFieldKey.title] = name as CKRecordValue
        share["frydgeKind"] = "fridge" as CKRecordValue
        share.publicPermission = .none

        // Transient network/service hiccups retry automatically rather than
        // surfacing a raw CKErrorDomain error on the first blip. A fresh
        // CKModifyRecordsOperation is built per attempt since a CKOperation
        // can't be re-added once it's run; `anchor`/`share` are untouched by a
        // failed attempt so reusing them across retries is safe.
        return try await withCloudKitRetry {
            try await withCheckedThrowingContinuation { cont in
                let op = CKModifyRecordsOperation(recordsToSave: [anchor, share], recordIDsToDelete: nil)
                op.savePolicy = .allKeys
                op.isAtomic = true

                op.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        // Re-fetch anchor so `anchor.share` is populated when you reload lists
                        Task {
                            do {
                                let fresh = try await db.record(for: rid)
                                cont.resume(returning: (share, fresh))
                            } catch {
                                // If refetch fails, fall back so flow still continues
                                cont.resume(returning: (share, anchor))
                            }
                        }

                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                }

                db.add(op)
            }
        }
    }

    /// Delete a whole shared fridge (anchor + items + share).
    /// Only used for `owned` fridges.
    func deleteFridge(_ anchor: CKRecord) async {
        let db = container.privateCloudDatabase
        let fridgeID = anchor.recordID
        var toDelete: [CKRecord.ID] = [fridgeID]

        if let shareRef = anchor.share {
            toDelete.append(shareRef.recordID)
        }

        // Items may not be cached if the fridge was never opened; load them so
        // they aren't orphaned in the zone after the anchor is gone.
        if itemsByFridge[fridgeID] == nil {
            await loadItems(for: anchor, scope: .owned)
        }
        if let items = itemsByFridge[fridgeID] {
            toDelete.append(contentsOf: items.map { $0.recordID })
        }

        do {
            // Chunked: CloudKit caps a single modify at 400 records.
            for start in stride(from: 0, to: toDelete.count, by: 300) {
                let chunk = Array(toDelete[start..<min(start + 300, toDelete.count)])
                _ = try await db.modifyRecords(saving: [], deleting: chunk)
            }
            owned.removeAll { $0.recordID == fridgeID }
            incoming.removeAll { $0.recordID == fridgeID }
            itemsByFridge[fridgeID] = nil
            namesByFridge[fridgeID] = nil
            emojiByFridge[fridgeID] = nil
            sharesByFridge[fridgeID] = nil
        } catch {
            self.errorMessage = "Failed to delete shared fridge: \(error.localizedDescription)"
        }
    }

    /// Delete a single item from a shared fridge.
    /// Works for owned frydges and for participants whose share grants write access
    /// (CloudKit rejects read-only participants, surfaced via `errorMessage`).
    func deleteItem(_ record: CKRecord, in anchor: CKRecord, scope: ShareScope) async {
        let db = dbFor(scope: scope)
        do {
            _ = try await db.deleteRecord(withID: record.recordID)
            let fid = anchor.recordID
            if var items = self.itemsByFridge[fid] {
                items.removeAll { $0.recordID == record.recordID }
                self.itemsByFridge[fid] = items
            }
        } catch {
            self.errorMessage = "Couldn't delete item: \(error.localizedDescription)"
        }
    }

    /// Deletes a shared item by its record name (used when dragging an item out to
    /// the personal fridge, where we only have the record name, not the CKRecord).
    /// Owned items live in the manager's custom zone; incoming ones are resolved
    /// from the cache so they delete from the owner's shared zone.
    func deleteItem(recordName: String, anchorRecordName: String, scope: ShareScope) async {
        if scope == .incoming {
            await removeSharedItemAnywhere(recordName: recordName)
            return
        }
        let db = dbFor(scope: scope)
        let recID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do {
            _ = try await db.deleteRecord(withID: recID)
            let anchorID = CKRecord.ID(recordName: anchorRecordName, zoneID: zoneID)
            if var items = itemsByFridge[anchorID] {
                items.removeAll { $0.recordID.recordName == recordName }
                itemsByFridge[anchorID] = items
            }
        } catch {
            self.errorMessage = "Couldn't remove item: \(error.localizedDescription)"
        }
    }

    /// Removes a shared-frydge item by its record name, searching both owned and
    /// incoming caches and deleting from the correct database using the record's
    /// *real* zone. Unlike `deleteItem(recordName:anchorRecordName:scope:)` this
    /// also works for participant (incoming) frydges — as long as the share grants
    /// write access — which is what lets a participant drag an item out into their
    /// own ("Mine") fridge. Returns true only if a record was actually deleted.
    @discardableResult
    func removeSharedItemAnywhere(recordName: String) async -> Bool {
        for (anchorID, records) in itemsByFridge {
            guard let rec = records.first(where: { $0.recordID.recordName == recordName }) else { continue }

            // Owned anchors live in our private DB; everything else is incoming.
            let scope: ShareScope = owned.contains(where: { $0.recordID == anchorID }) ? .owned : .incoming
            let db = dbFor(scope: scope)

            do {
                // Use the record's own recordID so incoming items delete from the
                // owner's shared zone (not our FrydgeFridgeZone).
                _ = try await db.deleteRecord(withID: rec.recordID)
                var remaining = records
                remaining.removeAll { $0.recordID.recordName == recordName }
                itemsByFridge[anchorID] = remaining
                return true
            } catch {
                self.errorMessage = "Couldn't remove item: \(error.localizedDescription)"
                return false
            }
        }
        return false
    }

    /// Updates an item's usage percentage (0–100), searching both owned and incoming
    /// caches and writing to the record's real DB/zone. Works for participants with
    /// write access; read-only shares fail gracefully via `errorMessage`.
    func updateSharedItemUsage(recordName: String, quantityUsed: Double) async {
        let clamped = max(0, min(100, quantityUsed))

        for (anchorID, records) in itemsByFridge {
            guard let rec = records.first(where: { $0.recordID.recordName == recordName }) else { continue }

            let scope: ShareScope = owned.contains(where: { $0.recordID == anchorID }) ? .owned : .incoming
            let db = dbFor(scope: scope)

            do {
                let fresh = try await db.record(for: rec.recordID)
                fresh["quantityUsed"] = clamped as CKRecordValue
                _ = try await db.save(fresh)

                if var items = itemsByFridge[anchorID],
                   let idx = items.firstIndex(where: { $0.recordID == fresh.recordID }) {
                    items[idx] = fresh
                    itemsByFridge[anchorID] = items
                }
            } catch {
                self.errorMessage = "Couldn't update item: \(error.localizedDescription)"
            }
            return
        }
    }

    // MARK: - Item updates (Shared)

    /// Updates an item's location and/or expiry. Works for owned frydges and for
    /// incoming (participant) frydges when the share grants write access — CloudKit
    /// rejects the save for read-only participants, which surfaces via `errorMessage`.
    func updateSharedItem(
        _ record: CKRecord,
        in anchor: CKRecord,
        scope: ShareScope,
        newLocationRaw: String? = nil,
        newExpirationDate: Date? = nil
    ) async {
        let db = dbFor(scope: scope)

        do {
            // Always refetch to avoid overwriting newer server data
            let fresh = try await db.record(for: record.recordID)

            let oldExp = (fresh["expirationDate"] as? Date) ?? Date()
            let oldLoc = (fresh["location"] as? String) ?? "Dry"

            var finalLoc = oldLoc
            if let newLocationRaw {
                finalLoc = normalizeStorageLocation(newLocationRaw)
                fresh["location"] = finalLoc as CKRecordValue
            }

            let finalExp: Date
            if let newExpirationDate {
                finalExp = newExpirationDate
            } else if newLocationRaw != nil {
                // Location changed -> recompute expiry using same rules as local
                let itemName = (fresh["name"] as? String) ?? ""
                finalExp = FoodStorageClassifier.adjustedExpiryDate(currentExpiry: oldExp, name: itemName, forLocation: finalLoc)
            } else {
                finalExp = oldExp
            }

            fresh["expirationDate"] = finalExp as CKRecordValue

            _ = try await db.save(fresh)

            // Update local cache so UI refreshes instantly (no reload required)
            let fid = anchor.recordID
            if var items = itemsByFridge[fid],
               let idx = items.firstIndex(where: { $0.recordID == fresh.recordID }) {
                items[idx] = fresh
                itemsByFridge[fid] = items
            }

        } catch {
            self.errorMessage = "Couldn't update item: \(error.localizedDescription)"
        }
    }

    /// Update the fridge display name (updates CKShare title and anchor field).
    /// IMPORTANT: uses correct DB based on scope.
    /// Owner-only writes. Participants do nothing.
    func updateFridgeName(_ newName: String, for anchor: CKRecord, scope: ShareScope) async {
        guard isOwnerScope(scope) else { return }

        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let db = dbFor(scope: scope)

        do {
            anchor[fridgeNameKey] = trimmed as CKRecordValue

            var recordsToSave: [CKRecord] = [anchor]
            var renamedShare: CKShare?

            if let shareRef = anchor.share {
                let shareRecord = try await db.record(for: shareRef.recordID)
                if let share = shareRecord as? CKShare {
                    share[CKShare.SystemFieldKey.title] = trimmed as CKRecordValue
                    recordsToSave.append(share)
                    renamedShare = share
                }
            }

            _ = try await db.modifyRecords(saving: recordsToSave, deleting: [])

            // Keep the share cache in step — otherwise fetchShare() keeps handing
            // back the pre-rename title until something else happens to clear it.
            if let renamedShare {
                self.sharesByFridge[anchor.recordID] = renamedShare
            }

            self.namesByFridge[anchor.recordID] = trimmed
            if let idx = self.owned.firstIndex(where: { $0.recordID == anchor.recordID }) {
                self.owned[idx] = anchor
            }
            if let idx = self.incoming.firstIndex(where: { $0.recordID == anchor.recordID }) {
                self.incoming[idx] = anchor
            }
        } catch {
            self.errorMessage = "Failed to rename shared fridge: \(error.localizedDescription)"
        }
    }

    /// Fetch a CKShare for an anchor using the correct DB for scope.
    /// Uses an in-memory cache to make opening the sharing UI snappy.
    func fetchShare(for anchor: CKRecord, scope: ShareScope) async throws -> CKShare? {
        let fid = anchor.recordID
        if let cached = sharesByFridge[fid] {
            return cached
        }

        guard let shareRef = anchor.share else { return nil }
        let db = dbFor(scope: scope)
        let rec = try await db.record(for: shareRef.recordID)
        let share = rec as? CKShare
        if let share {
            sharesByFridge[fid] = share
        }
        return share
    }

    /// Re-fetches the anchor (so `anchor.share` is definitely populated) and returns a share + fresh anchor.
    /// Call this right before presenting the management UI to avoid the first-present blank/grey state.
    func warmManagement(for anchor: CKRecord, scope: ShareScope) async throws -> (CKShare, CKRecord) {
        let db = dbFor(scope: scope)

        // Refresh the anchor record from the correct database.
        let freshAnchor = try await db.record(for: anchor.recordID)

        // Fetch (or reuse cached) share.
        guard let share = try await fetchShare(for: freshAnchor, scope: scope) else {
            throw NSError(
                domain: "SharedFridgeManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No CKShare found for this fridge."]
            )
        }

        return (share, freshAnchor)
    }

    // MARK: - Internal loading

    private func prefetchShares(for anchors: [CKRecord], scope: ShareScope) async {
        guard !anchors.isEmpty else { return }

        let db = dbFor(scope: scope)

        await withTaskGroup(of: Void.self) { group in
            for a in anchors {
                let fid = a.recordID
                if sharesByFridge[fid] != nil { continue }
                guard let shareRef = a.share else { continue }

                group.addTask { [weak self] in
                    guard let self else { return }
                    do {
                        let rec = try await db.record(for: shareRef.recordID)
                        if let share = rec as? CKShare {
                            await MainActor.run {
                                self.sharesByFridge[fid] = share
                            }
                        }
                    } catch {
                        // Silent: prefetch should never block UI.
                    }
                }
            }
        }
    }

    /// Optional: if you need to hard-reset cached shares (e.g. after stop-sharing).
    func clearShareCache() {
        sharesByFridge.removeAll()
    }

    private func dbFor(scope: ShareScope) -> CKDatabase {
        switch scope {
        case .owned:
            return container.privateCloudDatabase
        case .incoming:
            return container.sharedCloudDatabase
        }
    }

    private func loadOwned() async {
        let db = container.privateCloudDatabase
        let pred = NSPredicate(format: "category == %@", "Fridge")
        let query = CKQuery(recordType: "ShareAnchor", predicate: pred)

        do {
            let recsAll = try await db.allRecords(matching: query, inZoneWith: zoneID)

            // owned list shows *shared* anchors (share != nil)
            let recs = recsAll.filter { $0.share != nil }

            self.owned = recs
            for r in recs {
                let fid = r.recordID

                // 1) Fast path: use anchor fields immediately (no network wait)
                let nameField = r[fridgeNameKey] as? String
                let emojiField = r[fridgeEmojiKey] as? String

                let immediateName = (nameField?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    ? nameField!.trimmingCharacters(in: .whitespacesAndNewlines)
                    : "Frydge – Fridge"

                self.namesByFridge[fid] = immediateName
                self.emojiByFridge[fid] = (emojiField?.isEmpty == false) ? emojiField! : "🧊"

                // 2) Slow path: resolve share title and update if it improves the label
                Task { [weak self] in
                    guard let self else { return }
                    if let title = try? await self.resolveShareTitle(for: r, scope: .owned),
                       !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await MainActor.run {
                            if (nameField?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                                self.namesByFridge[fid] = title
                            }
                        }
                    }
                }
            }
        } catch {
            // Passive list refresh: an empty section is the right outcome for
            // "not signed in yet" or "offline", not a modal alert. Errors from
            // user-initiated actions (create, rename, move) still surface.
            self.owned = []
            print("[SharedFridgeManager] Owned shared fridges unavailable: \(error.localizedDescription)")
        }
    }

    private func loadIncoming() async {
        let db = container.sharedCloudDatabase

        do {
            let zones: [CKRecordZone.ID] = try await withCheckedThrowingContinuation { cont in
                let op = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
                var out: [CKRecordZone.ID] = []
                op.perRecordZoneResultBlock = { zid, result in
                    if case .success = result { out.append(zid) }
                }
                op.fetchRecordZonesResultBlock = { result in
                    switch result {
                    case .success:
                        cont.resume(returning: out)
                    case .failure(let e):
                        cont.resume(throwing: e)
                    }
                }
                db.add(op)
            }

            // One round trip per shared zone, run concurrently rather than
            // sequentially — a participant in many shared fridges was paying
            // zones-count × one-round-trip in serial before this.
            let collected: [CKRecord] = await withTaskGroup(of: [CKRecord].self) { group in
                for zid in zones {
                    group.addTask {
                        let pred = NSPredicate(format: "category == %@", "Fridge")
                        let query = CKQuery(recordType: "ShareAnchor", predicate: pred)
                        do {
                            return try await db.allRecords(matching: query, inZoneWith: zid)
                        } catch {
                            // best-effort per zone
                            return []
                        }
                    }
                }

                var out: [CKRecord] = []
                for await recs in group {
                    out.append(contentsOf: recs)
                }
                return out
            }

            // De-dupe incoming anchors by recordID defensively
            var seenIDs: Set<CKRecord.ID> = []
            let uniqueIncoming = collected.filter { seenIDs.insert($0.recordID).inserted }

            self.incoming = uniqueIncoming
            for r in uniqueIncoming {
                let fid = r.recordID

                // 1) Fast path: show anchor fields immediately
                let nameField = r[fridgeNameKey] as? String
                let emojiField = r[fridgeEmojiKey] as? String

                let immediateName = (nameField?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    ? nameField!.trimmingCharacters(in: .whitespacesAndNewlines)
                    : "Frydge – Fridge"

                self.namesByFridge[fid] = immediateName
                self.emojiByFridge[fid] = (emojiField?.isEmpty == false) ? emojiField! : "🧊"

                // 2) Slow path: resolve share title and update if it improves the label
                Task { [weak self] in
                    guard let self else { return }
                    if let title = try? await self.resolveShareTitle(for: r, scope: .incoming),
                       !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await MainActor.run {
                            if (nameField?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                                self.namesByFridge[fid] = title
                            }
                        }
                    }
                }
            }
        } catch {
            // See loadOwned(): passive refresh failures are logged, not alerted.
            self.incoming = []
            print("[SharedFridgeManager] Incoming shared fridges unavailable: \(error.localizedDescription)")
        }
    }

    private func resolveShareTitle(for anchor: CKRecord, scope: ShareScope) async throws -> String? {
        guard let share = try await fetchShare(for: anchor, scope: scope) else { return nil }
        if let rawTitle = share[CKShare.SystemFieldKey.title] as? String {
            let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    // MARK: - Zone

    /// Makes sure the private zone exists before anything queries it, coalescing
    /// concurrent callers onto a single in-flight attempt. Returns false (and
    /// leaves the next caller to retry) when CloudKit isn't reachable yet, which
    /// is normal on first launch while the iCloud account is still signing in.
    @discardableResult
    private func ensureZoneReady() async -> Bool {
        if zoneReady { return true }
        if let inflight = zoneSetupTask { return await inflight.value }

        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            do {
                try await self.ensureZone()
                return true
            } catch {
                print("[SharedFridgeManager] Zone setup deferred: \(error.localizedDescription)")
                return false
            }
        }
        zoneSetupTask = task
        let ready = await task.value
        zoneReady = ready
        zoneSetupTask = nil
        return ready
    }

    private func ensureZone() async throws {
        let db = container.privateCloudDatabase
        do {
            _ = try await db.recordZone(for: zoneID)
        } catch {
            try await withCheckedThrowingContinuation { cont in
                let op = CKModifyRecordZonesOperation(recordZonesToSave: [CKRecordZone(zoneID: zoneID)])
                op.modifyRecordZonesResultBlock = { result in
                    switch result {
                    case .success:
                        cont.resume()
                    case .failure(let e):
                        cont.resume(throwing: e)
                    }
                }
                db.add(op)
            }
        }
    }
}

// MARK: - Shared frydge notifications (CloudKit subscriptions)
extension SharedFridgeManager {

    /// Must match AppDelegateWrapper.swift
    static let sharedFrydgeUpdatedCategory = "SHARED_FRYDGE_UPDATED"

    /// Must match AppDelegateWrapper.swift routing prefix
    static let sharedFrydgeSubscriptionPrefix = "SharedFrydge_"

    /// Call at launch and after accepting a share (idempotent).
    func configureSharedFrydgeNotificationsIfNeeded() async {
        // Best-effort: ensure permission so banners can show
        do {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
        } catch {
            // best-effort
        }

        // ✅ Owned (private DB): Query subscriptions are OK (single zone you own)
        do { try await upsertOwnedAnchorQuerySubscription(in: container.privateCloudDatabase) } catch { /* best-effort */ }
        do { try await upsertOwnedItemQuerySubscription(in: container.privateCloudDatabase) } catch { /* best-effort */ }

        // Household meal plan records. The owner's subscriptions above only watch
        // anchors and items, so without these the owner's device would never be
        // woken when a member plans a meal. Silent on purpose: SharedMealPlanStore
        // turns the change into a local notification with the real message.
        do {
            try await upsertSilentOwnedQuerySubscription(
                recordType: SharedMealPlanStore.mealRecordType,
                idSuffix: "Owned_PlannedMeals",
                in: container.privateCloudDatabase
            )
        } catch { /* best-effort */ }
        do {
            try await upsertSilentOwnedQuerySubscription(
                recordType: SharedMealPlanStore.noticeRecordType,
                idSuffix: "Owned_MealPlanNotices",
                in: container.privateCloudDatabase
            )
        } catch { /* best-effort */ }
        do {
            try await upsertSilentOwnedQuerySubscription(
                recordType: SharedMealPlanStore.stapleRecordType,
                idSuffix: "Owned_HouseholdStaples",
                in: container.privateCloudDatabase
            )
        } catch { /* best-effort */ }

        // ✅ Incoming (shared DB): MUST subscribe per shared record zone
        do { try await upsertIncomingZoneSubscriptions() } catch { /* best-effort */ }
    }

    // MARK: - Owned (private DB) subscriptions

    private func upsertOwnedAnchorQuerySubscription(in db: CKDatabase) async throws {
        let subscriptionID = "\(Self.sharedFrydgeSubscriptionPrefix)Owned_AnchorChanges"

        do {
            _ = try await db.subscription(for: subscriptionID)
            return
        } catch { }

        let predicate = NSPredicate(format: "category == %@", "Fridge")
        let sub = CKQuerySubscription(
            recordType: "ShareAnchor",
            predicate: predicate,
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )

        let info = CKSubscription.NotificationInfo()
        info.alertBody = "Shared frydge updated"
        info.soundName = "default"
        info.shouldBadge = true
        info.shouldSendContentAvailable = true
        info.category = Self.sharedFrydgeUpdatedCategory
        info.desiredKeys = ["name", "emoji", "category"]

        sub.notificationInfo = info
        _ = try await db.save(sub)
    }

    private func upsertOwnedItemQuerySubscription(in db: CKDatabase) async throws {
        let subscriptionID = "\(Self.sharedFrydgeSubscriptionPrefix)Owned_ItemChanges"

        do {
            _ = try await db.subscription(for: subscriptionID)
            return
        } catch { }

        let predicate = NSPredicate(value: true)
        let sub = CKQuerySubscription(
            recordType: "StoredIngredient",
            predicate: predicate,
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )

        let info = CKSubscription.NotificationInfo()
        info.alertBody = "Shared frydge items updated"
        info.soundName = "default"
        info.shouldBadge = true
        info.shouldSendContentAvailable = true
        info.category = Self.sharedFrydgeUpdatedCategory
        info.desiredKeys = ["name", "quantity", "unit", "location", "expirationDate", "fridge"]

        sub.notificationInfo = info
        _ = try await db.save(sub)
    }

    /// Content-available-only query subscription on one record type in the
    /// owner's private zone. Wakes the app so it can fetch and decide what (if
    /// anything) to show the user.
    private func upsertSilentOwnedQuerySubscription(recordType: String, idSuffix: String, in db: CKDatabase) async throws {
        let subscriptionID = "\(Self.sharedFrydgeSubscriptionPrefix)\(idSuffix)"

        do {
            _ = try await db.subscription(for: subscriptionID)
            return
        } catch { }

        let sub = CKQuerySubscription(
            recordType: recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )

        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        info.category = Self.sharedFrydgeUpdatedCategory

        sub.notificationInfo = info
        _ = try await db.save(sub)
    }

    // MARK: - Incoming (shared DB) zone subscriptions

    /// For incoming shares, each share arrives as a *shared record zone*.
    /// Subscribing to the zone is the reliable way to receive push notifications.
    private func upsertIncomingZoneSubscriptions() async throws {
        let db = container.sharedCloudDatabase

        let zones: [CKRecordZone.ID] = try await withCheckedThrowingContinuation { cont in
            let op = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
            var out: [CKRecordZone.ID] = []
            op.perRecordZoneResultBlock = { zid, result in
                if case .success = result { out.append(zid) }
            }
            op.fetchRecordZonesResultBlock = { result in
                switch result {
                case .success:
                    cont.resume(returning: out)
                case .failure(let e):
                    cont.resume(throwing: e)
                }
            }
            db.add(op)
        }

        guard !zones.isEmpty else { return }

        for zid in zones {
            let subID = "\(Self.sharedFrydgeSubscriptionPrefix)Zone_\(zid.zoneName)_\(zid.ownerName)"

            // idempotent
            do {
                _ = try await db.subscription(for: subID)
                continue
            } catch { }

            let sub = CKRecordZoneSubscription(zoneID: zid, subscriptionID: subID)

            let info = CKSubscription.NotificationInfo()
            info.alertBody = "Shared frydge updated"
            info.soundName = "default"
            info.shouldBadge = true
            info.shouldSendContentAvailable = true
            info.category = Self.sharedFrydgeUpdatedCategory

            // NOTE: desiredKeys isn't supported the same way for zone subs; leave unset.
            sub.notificationInfo = info

            _ = try await db.save(sub)
        }
    }
}
