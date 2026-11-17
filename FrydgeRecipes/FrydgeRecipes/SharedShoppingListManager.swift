//
//  SharedShoppingListManager.swift
//  FrydgeRecipes
//
//  Created by Josh on 02/01/2026.
//

import Foundation
import Combine
import CloudKit
import UserNotifications
import WidgetKit

@MainActor
final class SharedShoppingListManager: ObservableObject {

    // MARK: - Published

    @Published var sharedAnchors: [CKRecord] = []
    @Published var itemsByAnchorID: [CKRecord.ID: [String]] = [:]
    @Published var displayNameByAnchorID: [CKRecord.ID: String] = [:]
    @Published var emojiByAnchorID: [CKRecord.ID: String] = [:]
    @Published var isLoading: Bool = false
    @Published var lastError: String? = nil

    private let appGroupName = "group.Clark-Online.FrydgeRecipeAPN"
    private let widgetStructuredSharedShoppingListKey = "sharedShoppingListItemsJSON"
    private let widgetLegacySharedShoppingListKey = "sharedShoppingList"
    private var cancellables = Set<AnyCancellable>()

    private struct WidgetShoppingListItem: Codable, Hashable, Identifiable {
        let id: String
        let name: String
        let quantity: String
        let unit: String

        var displayString: String {
            let name = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let qty  = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
            let unit = self.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            if unit.lowercased() == "ea", !qty.isEmpty {
                return name.isEmpty ? "x\(qty)" : "\(name) x\(qty)"
            }
            var parts = [name]
            if !qty.isEmpty { parts.append(qty) }
            if !unit.isEmpty { parts.append(unit) }
            return parts.filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    // MARK: - Compatibility aliases (used by ShoppingListView / sheets)

    var anchors: [CKRecord] { sharedAnchors }
    var namesByAnchorID: [CKRecord.ID: String] { displayNameByAnchorID }
    var emojisByAnchorID: [CKRecord.ID: String] { emojiByAnchorID }

    private func refreshWidgetSnapshots() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func saveSharedShoppingListSnapshotToAppGroup() {
        guard let ud = UserDefaults(suiteName: appGroupName) else { return }

        let allItems: [SharedShoppingListItem] = sharedAnchors.flatMap { anchor in
            itemsDetailed(for: anchor)
        }

        let widgetItems = allItems.map {
            WidgetShoppingListItem(
                id: $0.id.uuidString,
                name: $0.name,
                quantity: $0.quantity,
                unit: $0.unit
            )
        }

        if let data = try? JSONEncoder().encode(widgetItems),
           let json = String(data: data, encoding: .utf8) {
            ud.set(json, forKey: widgetStructuredSharedShoppingListKey)
        } else {
            ud.removeObject(forKey: widgetStructuredSharedShoppingListKey)
        }

        let legacy = widgetItems.map { $0.displayString }
        ud.set(legacy, forKey: widgetLegacySharedShoppingListKey)
        ud.synchronize()
    }

    private func publishSharedShoppingListSnapshot() {
        saveSharedShoppingListSnapshotToAppGroup()
        refreshWidgetSnapshots()
    }

    // MARK: - CloudKit

    let container: CKContainer
    private var privateDB: CKDatabase { container.privateCloudDatabase }
    private var sharedDB: CKDatabase { container.sharedCloudDatabase }

    // MARK: - Schema constants

    private let anchorRecordType = "ShareAnchor"
    private let anchorCategoryKey = "category"
    private let anchorCategoryShoppingRoot = "ShoppingListRoot"

    private let anchorTitleKey = "name"              // String
    private let anchorEmojiKey = "emoji"             // String
    private let anchorItemsKey = "items"             // [String]
    private let anchorItemsJSONKey = "itemsJSON"     // String (JSON encoded [SharedShoppingListItem])
    
    // Add these near the top of SharedShoppingListManager
    private let sharedShoppingListUpdatedCategory = "SHARED_SHOPPING_LIST_UPDATED"
    private let sharedShoppingListSubscriptionPrefix = "SharedShoppingList_"

    // ✅ Stable list identifier (shared across owner/participants)
    private let anchorListUUIDKey = "listUUID"       // String (UUID string)

    // ✅ Per-anchor permissions cache
    // Owner is determined by the *share participant role* when available; otherwise fallback to zone ownership.
    @Published var isOwnerByAnchorID: [CKRecord.ID: Bool] = [:]

    /// When subscriptions were last (re)configured from a refresh.
    private var lastSubscriptionConfigure: Date = .distantPast
    private var lastConfiguredIncomingCount = -1

    // MARK: - Zone (private DB)

    private let zoneName = "ShoppingListZone"

    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private func ensurePrivateZoneExists() async throws {
        do {
            _ = try await privateDB.recordZone(for: zoneID)
        } catch let ck as CKError where ck.code == .zoneNotFound || ck.code == .unknownItem {
            let zone = CKRecordZone(zoneID: zoneID)
            do {
                _ = try await privateDB.save(zone)
            } catch let saveError as CKError where saveError.code == .serverRecordChanged {
                return
            }
        } catch {
            throw error
        }
    }

    // MARK: - Init

    init(container: CKContainer = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")) {
        self.container = container
        // When NSPersistentCloudKitContainer receives a CloudKit push (any family member
        // updates the shared list), fire .NSPersistentStoreRemoteChange. We debounce and
        // refresh so every user's view updates without manual pull-to-refresh.
        NotificationCenter.default
            .publisher(for: .NSPersistentStoreRemoteChange)
            .debounce(for: .milliseconds(800), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isLoading else { return }
                Task { await self.refreshSharedLists() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Refresh shared vs private anchors separately so a "Leave" (which deletes a shared zone)
    /// actually disappears immediately on refresh.
    func refreshSharedLists() async {
        // Coalesce: many screens and push notifications ask for a refresh at once. If one is
        // already running, wait for it instead of starting a second overlapping fetch.
        if let inflight = refreshTask {
            await inflight.value
            return
        }
        let task = Task { await self.performRefreshSharedLists() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private var refreshTask: Task<Void, Never>?

    private func performRefreshSharedLists() async {
        print("[SharedShoppingListManager] 🔄 Starting refreshSharedLists...")
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        // ✅ FIX: Always ensure subscriptions are up-to-date after refresh
        // This catches new shared zones that appeared after accepting shares
        // Throttled: every remote-change push refreshes, and subscription setup is
        // several server round trips that only matter when a new zone appears.
        defer {
            // A changed number of incoming lists means a new shared zone to subscribe to.
            let incomingCount = sharedAnchors.filter { !isOwnerByZone($0) }.count
            if incomingCount != lastConfiguredIncomingCount
                || Date().timeIntervalSince(lastSubscriptionConfigure) > 60 {
                lastSubscriptionConfigure = Date()
                lastConfiguredIncomingCount = incomingCount
                Task.detached {
                    await self.configureSharedShoppingListNotificationsIfNeeded()
                }
            }
        }

        do { 
            try await ensurePrivateZoneExists()
            print("[SharedShoppingListManager] ✅ Private zone exists")
        } catch { 
            print("[SharedShoppingListManager] ⚠️ Failed to ensure private zone: \(error)")
        }

        // 1) Fetch incoming anchors from shared DB
        // A failed fetch (offline, throttled) must not read as "no lists": that wiped
        // every shared list from the screen until the next successful refresh. Keep
        // what we already have for a group whose fetch failed.
        let fetchedIncoming = try? await fetchIncomingAnchorsFromSharedDB()
        let incomingAnchors = fetchedIncoming ?? sharedAnchors.filter { !isOwnerByZone($0) }
        print("[SharedShoppingListManager] 📥 Found \(incomingAnchors.count) incoming anchors from shared DB\(fetchedIncoming == nil ? " (fetch failed, kept previous)" : "")")

        // 2) Fetch my anchors from private DB
        let fetchedMine = try? await fetchAnchors(in: privateDB, zoneID: zoneID)
        let myAnchors = fetchedMine ?? sharedAnchors.filter { isOwnerByZone($0) }
        print("[SharedShoppingListManager] 📤 Found \(myAnchors.count) my anchors from private DB\(fetchedMine == nil ? " (fetch failed, kept previous)" : "")")

        // 3) Refresh each group against the DB it actually lives in
        let refreshedIncoming = await refresh(records: incomingAnchors, in: sharedDB)
        let refreshedMine = await refresh(records: myAnchors, in: privateDB)

        // 4) Combine & de-dupe
        let combined = dedupeByFullRecordIdentity(refreshedIncoming + refreshedMine)
        print("[SharedShoppingListManager] 🔗 Combined and deduped: \(combined.count) total anchors")

        // ✅ FIXED: Removed preservation logic - it was causing flickering
        // Just use what CloudKit returns - if it's not there, it doesn't exist
        let sortedAnchors = combined.sorted { lhs, rhs in
            recordSortKey(lhs.recordID) < recordSortKey(rhs.recordID)
        }
        print("[SharedShoppingListManager] ✅ Final anchor count: \(sortedAnchors.count)")

        // 5) Do all the awaiting first (listUUID backfill, owner lookup) without touching
        // published state, so the view isn't re-rendered between every suspension.
        var owners: [CKRecord.ID: Bool] = [:]
        for a in sortedAnchors {
            // Backfill listUUID if missing (best-effort)
            await ensureListUUIDIfNeeded(on: a)
            // ✅ permissions (owner vs participant)
            owners[a.recordID] = await resolveIsOwner(for: a)
        }

        // 6) Publish everything in one synchronous burst (no suspension points), so SwiftUI
        // coalesces it into a single update.
        self.sharedAnchors = sortedAnchors
        for a in sortedAnchors {
            // Always update cache with latest data (don't preserve stale data)
            cacheFields(from: a)
            itemsByAnchorID[a.recordID] = readItems(from: a)
        }
        for (id, owner) in owners {
            isOwnerByAnchorID[id] = owner
        }

        publishSharedShoppingListSnapshot()
        print("[SharedShoppingListManager] ✅ refreshSharedLists complete - \(self.sharedAnchors.count) anchors ready")
    }

    /// Owner flow: ensures you have a single root anchor for your shopping list (legacy default list).
    /// IMPORTANT: must live in the PRIVATE database to support CloudKit sharing.
    func ensureMyShoppingListAnchor() async throws -> CKRecord {
        try await ensurePrivateZoneExists()

        let recordID = CKRecord.ID(recordName: "ShoppingListRootAnchor", zoneID: zoneID)

        do {
            let existing = try await privateDB.record(for: recordID)

            // Ensure listUUID exists for legacy anchors
            if !hasListUUID(existing) {
                existing[anchorListUUIDKey] = UUID().uuidString as CKRecordValue
                let saved = try await privateDB.save(existing)
                cacheFields(from: saved)
                if itemsByAnchorID[saved.recordID] == nil {
                    itemsByAnchorID[saved.recordID] = readItems(from: saved)
                }
                upsertAnchorInList(saved)
                isOwnerByAnchorID[saved.recordID] = true
                publishSharedShoppingListSnapshot()
                return saved
            }

            cacheFields(from: existing)
            if itemsByAnchorID[existing.recordID] == nil {
                itemsByAnchorID[existing.recordID] = readItems(from: existing)
            }
            isOwnerByAnchorID[existing.recordID] = true
            publishSharedShoppingListSnapshot()
            return existing
        } catch let error as CKError where error.code == .unknownItem {
            // create below
        } catch {
            throw error
        }

        let anchor = CKRecord(recordType: anchorRecordType, recordID: recordID)
        anchor[anchorCategoryKey] = anchorCategoryShoppingRoot as CKRecordValue
        anchor[anchorTitleKey] = "Frydge – Shopping List" as CKRecordValue
        anchor[anchorEmojiKey] = "🛒" as CKRecordValue
        anchor[anchorItemsKey] = [] as CKRecordValue
        anchor[anchorItemsJSONKey] = "[]" as CKRecordValue
        anchor[anchorListUUIDKey] = UUID().uuidString as CKRecordValue

        let saved = try await privateDB.save(anchor)
        cacheFields(from: saved)
        itemsByAnchorID[saved.recordID] = readItems(from: saved)
        upsertAnchorInList(saved)
        isOwnerByAnchorID[saved.recordID] = true
        publishSharedShoppingListSnapshot()
        return saved
    }

    /// Creates a brand new shopping list anchor (ShareAnchor) in the private DB custom zone.
    func createShoppingListAnchor(named name: String, emoji: String = "🛒") async throws -> CKRecord {
        print("[SharedShoppingListManager] 🆕 Creating new shopping list: '\(name)' \(emoji)")
        try await ensurePrivateZoneExists()

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "Frydge – Shopping List" : trimmedName

        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalEmoji = trimmedEmoji.isEmpty ? "🛒" : String(trimmedEmoji.prefix(1))

        let rid = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        let anchor = CKRecord(recordType: anchorRecordType, recordID: rid)
        anchor[anchorCategoryKey] = anchorCategoryShoppingRoot as CKRecordValue
        anchor[anchorTitleKey] = finalName as CKRecordValue
        anchor[anchorEmojiKey] = finalEmoji as CKRecordValue
        anchor[anchorItemsKey] = [] as CKRecordValue
        anchor[anchorItemsJSONKey] = "[]" as CKRecordValue
        anchor[anchorListUUIDKey] = UUID().uuidString as CKRecordValue

        print("[SharedShoppingListManager] 💾 Saving anchor to CloudKit...")
        let saved = try await privateDB.save(anchor)
        print("[SharedShoppingListManager] ✅ Anchor saved successfully: \(saved.recordID.recordName)")
        
        cacheFields(from: saved)
        itemsByAnchorID[saved.recordID] = readItems(from: saved)
        upsertAnchorInList(saved)
        isOwnerByAnchorID[saved.recordID] = true
        publishSharedShoppingListSnapshot()
        
        print("[SharedShoppingListManager] ✅ Local state updated, anchor count: \(sharedAnchors.count)")
        return saved
    }

    func createSharePairForNewShoppingList(named name: String, emoji: String = "🛒") async throws -> (CKShare, CKRecord) {
        let anchor = try await createShoppingListAnchor(named: name, emoji: emoji)
        return try await ensureSharePair(for: anchor)
    }

    /// Returns a (share, freshRoot) pair for any shopping list anchor.
    ///
    /// If root.share exists but the Share record is missing:
    /// - Owner: recreate share (self-heal)
    /// - Participant: throw .unknownItem so caller can purge / show message
    func ensureSharePair(for anchor: CKRecord) async throws -> (CKShare, CKRecord) {
        let db = databaseForAnchor(anchor)
        let freshRoot = try await db.record(for: anchor.recordID)

        await ensureListUUIDIfNeeded(on: freshRoot)

        if let ref = freshRoot.share {
            do {
                let shareRecord = try await db.record(for: ref.recordID)
                guard let share = shareRecord as? CKShare else {
                    throw NSError(domain: "SharedShoppingListManager", code: -2, userInfo: [
                        NSLocalizedDescriptionKey: "Share reference did not resolve to CKShare."
                    ])
                }
                isOwnerByAnchorID[freshRoot.recordID] = resolveIsOwnerFromShare(share, root: freshRoot)
                return (share, freshRoot)
            } catch let ck as CKError where ck.code == .unknownItem {
                if isOwnerByZone(freshRoot) {
                    let recreated = try await recreateSharePair(for: freshRoot, in: db)
                    isOwnerByAnchorID[recreated.1.recordID] = resolveIsOwnerFromShare(recreated.0, root: recreated.1)
                    return recreated
                } else {
                    throw ck
                }
            }
        }

        // ✅ IMPORTANT: participants must NOT create a share
        guard isOwnerByZone(freshRoot) else {
            throw CKError(.unknownItem)
        }

        let share = CKShare(rootRecord: freshRoot)
        share["frydgeKind"] = "shoppingList" as CKRecordValue
        share.publicPermission = .none

        let title = (freshRoot[anchorTitleKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = (title?.isEmpty == false) ? title! : "Frydge – Shopping List"
        share[CKShare.SystemFieldKey.title] = cleanTitle as CKRecordValue

        // Transient network/service hiccups retry automatically rather than
        // surfacing a raw CKErrorDomain error on the first blip. A fresh
        // CKModifyRecordsOperation is built per attempt since a CKOperation
        // can't be re-added once it's run.
        return try await withCloudKitRetry {
            try await withCheckedThrowingContinuation { cont in
                let op = CKModifyRecordsOperation(recordsToSave: [freshRoot, share], recordIDsToDelete: nil)
                op.savePolicy = .allKeys
                op.isAtomic = true

                op.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        Task {
                            do {
                                let refreshedRoot = try await db.record(for: freshRoot.recordID)
                                await MainActor.run { self.isOwnerByAnchorID[refreshedRoot.recordID] = true }
                                cont.resume(returning: (share, refreshedRoot))
                            } catch {
                                await MainActor.run { self.isOwnerByAnchorID[freshRoot.recordID] = true }
                                cont.resume(returning: (share, freshRoot))
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

    func ensureSharePairForMyShoppingList() async throws -> (CKShare, CKRecord) {
        let anchor = try await ensureMyShoppingListAnchor()
        return try await ensureSharePair(for: anchor)
    }

    func items(for anchor: CKRecord) -> [String] {
        itemsByAnchorID[anchor.recordID] ?? readItems(from: anchor)
    }

    func setItems(_ items: [String], for anchor: CKRecord) async {
        lastError = nil
        anchor[anchorItemsKey] = items as CKRecordValue
        await saveAnchorBestEffort(anchor)
    }

    func rename(_ name: String, emoji: String, for anchor: CKRecord) async {
        lastError = nil

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "Frydge – Shopping List" : trimmedName

        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalEmoji = trimmedEmoji.isEmpty ? "🛒" : String(trimmedEmoji.prefix(1))

        anchor[anchorTitleKey] = finalName as CKRecordValue
        anchor[anchorEmojiKey] = finalEmoji as CKRecordValue

        // Ensure listUUID exists too (best-effort)
        if !hasListUUID(anchor) {
            anchor[anchorListUUIDKey] = UUID().uuidString as CKRecordValue
        }

        await saveAnchorBestEffort(anchor)

        // Best-effort: keep the CKShare title in sync (owner path only makes sense in private DB).
        do {
            let db = databaseForAnchor(anchor)
            let fresh = try await db.record(for: anchor.recordID)
            if let shareRef = fresh.share {
                do {
                    let shareRecord = try await db.record(for: shareRef.recordID)
                    if let share = shareRecord as? CKShare {
                        share[CKShare.SystemFieldKey.title] = finalName as CKRecordValue
                        _ = try await db.save(share)
                        isOwnerByAnchorID[fresh.recordID] = resolveIsOwnerFromShare(share, root: fresh)
                    }
                } catch {
                    // best-effort
                }
            }
        } catch {
            // best-effort
        }
    }

    func itemsDetailed(for anchor: CKRecord) -> [SharedShoppingListItem] {
        if let json = anchor[anchorItemsJSONKey] as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([SharedShoppingListItem].self, from: data) {
            return decoded
        }

        if let legacy = anchor[anchorItemsKey] as? [String] {
            return legacy.map { SharedShoppingListItem(name: $0) }
        }
        return []
    }

    @discardableResult
    func setItemsDetailed(_ items: [SharedShoppingListItem], for anchor: CKRecord) async -> Bool {
        // Remember what was there so a rejected save doesn't leave the cached
        // record showing items the server never accepted.
        let id = anchor.recordID
        // Callers often hold the record from before the last save. Saving that
        // copy carries an old change tag, so every second edit would conflict
        // and cost an extra round trip. Save from the newest copy we have.
        let target = sharedAnchors.first(where: { $0.recordID == id }) ?? anchor
        let records = target === anchor ? [anchor] : [target, anchor]

        let previousJSON = target[anchorItemsJSONKey]
        let previousItems = target[anchorItemsKey]
        let previousCache = itemsByAnchorID[id]

        let legacy = items.map { $0.displayString }
        let json = (try? JSONEncoder().encode(items)).flatMap { String(data: $0, encoding: .utf8) }

        for record in records {
            if let json { record[anchorItemsJSONKey] = json as CKRecordValue }
            // keep old field updated
            record[anchorItemsKey] = legacy as CKRecordValue
        }

        // ensure list UUID exists
        if !hasListUUID(target) {
            let uuid = UUID().uuidString as CKRecordValue
            for record in records { record[anchorListUUIDKey] = uuid }
        }

        // Optimistic: show the change now instead of after the network round trip.
        itemsByAnchorID[id] = legacy
        upsertAnchorInList(target)

        let saved = await saveAnchorBestEffort(target)
        if !saved {
            for record in records {
                record[anchorItemsJSONKey] = previousJSON
                record[anchorItemsKey] = previousItems
            }
            itemsByAnchorID[id] = previousCache
            upsertAnchorInList(target)
        }
        return saved
    }

    // MARK: - Permissions

    /// Public helper for views: if we already know, return cached; otherwise return best-effort.
    func isOwnerCached(for anchor: CKRecord) -> Bool {
        if let cached = isOwnerByAnchorID[anchor.recordID] { return cached }
        return isOwnerByZone(anchor)
    }

    /// Fetch root & share if possible; derive owner from participant role.
    private func resolveIsOwner(for anchor: CKRecord) async -> Bool {
        let db = databaseForAnchor(anchor)
        do {
            let freshRoot = try await db.record(for: anchor.recordID)
            if let shareRef = freshRoot.share {
                do {
                    let shareRecord = try await db.record(for: shareRef.recordID)
                    if let share = shareRecord as? CKShare {
                        return resolveIsOwnerFromShare(share, root: freshRoot)
                    }
                } catch {
                    // ignore; fallback below
                }
            }
            return isOwnerByZone(freshRoot)
        } catch {
            return isOwnerByZone(anchor)
        }
    }

    private func resolveIsOwnerFromShare(_ share: CKShare, root: CKRecord) -> Bool {
        if let current = share.currentUserParticipant {
            return current.role == .owner
        }
        return isOwnerByZone(root)
    }

    private func isOwnerByZone(_ record: CKRecord) -> Bool {
        let zid = record.recordID.zoneID
        // Only treat "current user == zone owner" as owner if it's our private zone.
        return zid.ownerName == CKCurrentUserDefaultName && zid.zoneName == zoneName
    }

    // MARK: - Anchor save helper

    /// How many times a conflicting save is re-attempted against the server's
    /// current record before the error is surfaced.
    private let conflictRetryLimit = 3

    /// Returns true if the record reached CloudKit, so callers that moved items
    /// can roll back instead of silently losing them.
    @discardableResult
    private func saveAnchorBestEffort(_ anchor: CKRecord) async -> Bool {
        lastError = nil

        let db = databaseForAnchor(anchor)
        var candidate = anchor
        var conflictRetries = 0

        while true {
            do {
                let saved = try await db.save(candidate)
                upsertAnchorInList(saved)
                itemsByAnchorID[saved.recordID] = readItems(from: saved)
                cacheFields(from: saved)

                // owner cache best-effort
                isOwnerByAnchorID[saved.recordID] = isOwnerByZone(saved)
                publishSharedShoppingListSnapshot()
                return true
            } catch let ck as CKError where ck.code == .serverRecordChanged {
                // Another member saved first. Merge our change into the server's
                // record and try again instead of dropping it (plan workstream G).
                guard conflictRetries < conflictRetryLimit, let server = ck.serverRecord else {
                    lastError = ck.localizedDescription
                    return false
                }
                conflictRetries += 1
                candidate = mergeConflict(client: candidate, server: server, ancestor: ck.ancestorRecord)
            } catch let ck as CKError where ck.code == .permissionFailure {
                lastError = "You only have read access to this shared list."
                return false
            } catch {
                lastError = error.localizedDescription
                return false
            }
        }
    }

    // MARK: - Conflict merge

    /// Builds the record to retry with after `serverRecordChanged`: the server's
    /// record (so the save carries its current change tag) with the merged item
    /// list and any scalar fields this device deliberately changed.
    private func mergeConflict(client: CKRecord, server: CKRecord, ancestor: CKRecord?) -> CKRecord {
        let merged = SharedListMerge.merge(
            base: ancestor.map(keyedItems(from:)) ?? [],
            ours: keyedItems(from: client),
            theirs: keyedItems(from: server)
        )

        if let data = try? JSONEncoder().encode(merged),
           let json = String(data: data, encoding: .utf8) {
            server[anchorItemsJSONKey] = json as CKRecordValue
        }
        server[anchorItemsKey] = merged.map { $0.displayString } as CKRecordValue

        // Title and emoji: ours win only if we changed them since the ancestor;
        // otherwise a rename by the other member is kept.
        for key in [anchorTitleKey, anchorEmojiKey] {
            let ourValue = client[key] as? String
            let baseValue = ancestor?[key] as? String
            if let ourValue, ourValue != baseValue {
                server[key] = ourValue as CKRecordValue
            }
        }

        // The stable list id must never flip once the server has one.
        if !hasListUUID(server), let ours = client[anchorListUUIDKey] as? String, !ours.isEmpty {
            server[anchorListUUIDKey] = ours as CKRecordValue
        }

        return server
    }

    /// Items with a merge key. Lists written with `itemsJSON` carry stable ids;
    /// legacy `[String]` lists are decoded with fresh UUIDs on every read, so
    /// they are keyed by display text instead.
    private func keyedItems(from record: CKRecord) -> [SharedListMerge.Keyed] {
        let hasStableIDs = (record[anchorItemsJSONKey] as? String) != nil
        return itemsDetailed(for: record).map { item in
            SharedListMerge.Keyed(
                key: hasStableIDs ? item.id.uuidString : "legacy:" + item.displayString.lowercased(),
                item: item
            )
        }
    }

    // MARK: - Share self-heal

    private func recreateSharePair(for root: CKRecord, in db: CKDatabase) async throws -> (CKShare, CKRecord) {
        if !hasListUUID(root) {
            root[anchorListUUIDKey] = UUID().uuidString as CKRecordValue
        }

        let share = CKShare(rootRecord: root)
        share["frydgeKind"] = "shoppingList" as CKRecordValue
        share.publicPermission = .none

        let title = (root[anchorTitleKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = (title?.isEmpty == false) ? title! : "Frydge – Shopping List"
        share[CKShare.SystemFieldKey.title] = cleanTitle as CKRecordValue

        let op = CKModifyRecordsOperation(recordsToSave: [root, share], recordIDsToDelete: nil)
        op.savePolicy = .changedKeys
        op.isAtomic = true

        try await withCheckedThrowingContinuation { cont in
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    cont.resume()
                case .failure(let err):
                    cont.resume(throwing: err)
                }
            }
            db.add(op)
        }

        let refreshedRoot = try await db.record(for: root.recordID)

        if let ref = refreshedRoot.share {
            let shareRecord = try await db.record(for: ref.recordID)
            guard let s = shareRecord as? CKShare else { return (share, refreshedRoot) }
            return (s, refreshedRoot)
        }

        return (share, refreshedRoot)
    }

    // MARK: - Private helpers

    /// Safer routing:
    /// - If it’s *your* zone (ownerName == current) AND it’s your ShoppingListZone, it’s private.
    /// - Otherwise treat as shared DB.
    private func databaseForAnchor(_ anchor: CKRecord) -> CKDatabase {
        let zid = anchor.recordID.zoneID
        if zid.ownerName == CKCurrentUserDefaultName && zid.zoneName == zoneName {
            return privateDB
        }
        return sharedDB
    }

    private func fetchAnchors(in db: CKDatabase, zoneID: CKRecordZone.ID?) async throws -> [CKRecord] {
        let pred = NSPredicate(format: "\(anchorCategoryKey) == %@", anchorCategoryShoppingRoot)
        let query = CKQuery(recordType: anchorRecordType, predicate: pred)
        return try await runQuery(db, query: query, zoneID: zoneID)
    }

    private func cacheFields(from anchor: CKRecord) {
        let id = anchor.recordID

        let name = (anchor[anchorTitleKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        displayNameByAnchorID[id] = (name?.isEmpty == false) ? name! : "Frydge – Shopping List"

        let e = (anchor[anchorEmojiKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        emojiByAnchorID[id] = (e?.isEmpty == false) ? String(e!.prefix(1)) : "🛒"
    }

    private func readItems(from anchor: CKRecord) -> [String] {
        (anchor[anchorItemsKey] as? [String]) ?? []
    }

    private func upsertAnchorInList(_ anchor: CKRecord) {
        if let idx = sharedAnchors.firstIndex(where: { $0.recordID == anchor.recordID }) {
            sharedAnchors[idx] = anchor
        } else {
            sharedAnchors.append(anchor)
        }
    }

    private func recordSortKey(_ id: CKRecord.ID) -> String {
        "\(id.zoneID.ownerName)|\(id.zoneID.zoneName)|\(id.recordName)"
    }

    private func fullIdentityKey(_ id: CKRecord.ID) -> String {
        "\(id.recordName)|\(id.zoneID.zoneName)|\(id.zoneID.ownerName)"
    }

    private func dedupeByFullRecordIdentity(_ records: [CKRecord]) -> [CKRecord] {
        var seen: Set<String> = []
        var out: [CKRecord] = []
        out.reserveCapacity(records.count)
        for r in records {
            let key = fullIdentityKey(r.recordID)
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(r)
        }
        return out
    }

    // MARK: - listUUID helpers

    private func hasListUUID(_ anchor: CKRecord) -> Bool {
        if let s = anchor[anchorListUUIDKey] as? String {
            return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    private func ensureListUUIDIfNeeded(on anchor: CKRecord) async {
        guard !hasListUUID(anchor) else { return }

        // Only the owner (private zone) should ever write listUUID.
        guard isOwnerByZone(anchor) else { return }

        anchor[anchorListUUIDKey] = UUID().uuidString as CKRecordValue
        await saveAnchorBestEffort(anchor)
    }

    private func runQuery(_ db: CKDatabase, query: CKQuery, zoneID: CKRecordZone.ID?) async throws -> [CKRecord] {
        var out: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {
            let (batch, newCursor): ([CKRecord], CKQueryOperation.Cursor?) = try await withCheckedThrowingContinuation { cont in
                var batchOut: [CKRecord] = []
                let op: CKQueryOperation = (cursor != nil) ? CKQueryOperation(cursor: cursor!) : CKQueryOperation(query: query)
                op.resultsLimit = CKQueryOperation.maximumResults

                if let zid = zoneID {
                    op.zoneID = zid
                }

                op.recordMatchedBlock = { _, result in
                    if case .success(let record) = result { batchOut.append(record) }
                }

                op.queryResultBlock = { result in
                    switch result {
                    case .success(let cursorNext):
                        cont.resume(returning: (batchOut, cursorNext))
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                }

                db.add(op)
            }

            out.append(contentsOf: batch)
            cursor = newCursor
        } while cursor != nil

        return out
    }

    // MARK: - Shared DB incoming anchors (must enumerate zones)

    private func fetchIncomingAnchorsFromSharedDB() async throws -> [CKRecord] {
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
            sharedDB.add(op)
        }

        guard !zones.isEmpty else { return [] }

        var collected: [CKRecord] = []
        collected.reserveCapacity(zones.count * 2)

        for zid in zones {
            do {
                let batch = try await fetchAnchors(in: sharedDB, zoneID: zid)
                collected.append(contentsOf: batch)
            } catch {
                // best-effort per zone
            }
        }

        return collected
    }

    // MARK: - Refresh helper

    private func refresh(records: [CKRecord], in db: CKDatabase) async -> [CKRecord] {
        guard !records.isEmpty else { return [] }

        var fresh: [CKRecord] = []
        fresh.reserveCapacity(records.count)
        var droppedAny = false

        for r in records {
            do {
                let refreshed = try await db.record(for: r.recordID)
                fresh.append(refreshed)
            } catch let ck as CKError where ck.code == .unknownItem {
                droppedAny = true
                continue
            } catch {
                fresh.append(r)
            }
        }

        if droppedAny {
            Task { @MainActor in
                self.publishSharedShoppingListSnapshot()
            }
        }

        return fresh
    }
}

// MARK: - Shared shopping list notifications (CloudKit subscriptions)

// MARK: - Shared shopping list notifications (CloudKit subscriptions)

extension SharedShoppingListManager {
    /// Call this at app launch AND after accepting a share.
    public func configureSharedShoppingListNotificationsIfNeeded() async {
        print("[SharedShoppingListManager] 🔔 === CONFIGURE NOTIFICATIONS START ===")
        
        // 1) Ask permission (best-effort). Local permission is required for user-visible alerts.
        do {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            print("[SharedShoppingListManager] 🔔 Notification auth status: \(settings.authorizationStatus.rawValue)")
            if settings.authorizationStatus == .notDetermined {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                print("[SharedShoppingListManager] 🔔 Permission requested, granted: \(granted)")
            }
        } catch {
            print("[SharedShoppingListManager] 🔔 ❌ Permission request error: \(error)")
        }

        // 2) ✅ Clean up any broken subscriptions first (from previous bugs)
        do {
            try await ensurePrivateZoneExists()
            print("[SharedShoppingListManager] 🔔 Private zone ready for subscriptions")
        } catch {
            print("[SharedShoppingListManager] 🔔 ❌ Private zone unavailable; skipping subscription setup: \(error)")
            return
        }

        print("[SharedShoppingListManager] 🔔 Cleaning up old subscriptions...")
        await cleanupBrokenSubscriptions()

        // 3) ✅ Use ZONE subscriptions instead of query subscriptions
        // Zone subscriptions don't require queryable indexes and are more reliable
        print("[SharedShoppingListManager] 🔔 Setting up zone subscriptions...")
        
        // Private zone subscription (for owned lists)
        do {
            try await upsertPrivateZoneSubscription()
            print("[SharedShoppingListManager] 🔔 ✅ Private zone subscription created")
        } catch {
            print("[SharedShoppingListManager] 🔔 ❌ Failed to create private zone subscription: \(error)")
        }
        
        // Shared zone subscriptions (for lists shared with you)
        do {
            try await upsertSharedZoneSubscriptions()
            print("[SharedShoppingListManager] 🔔 ✅ Shared zone subscriptions created")
        } catch {
            print("[SharedShoppingListManager] 🔔 ❌ Failed to create shared zone subscriptions: \(error)")
        }

        print("[SharedShoppingListManager] 🔔 === CONFIGURE NOTIFICATIONS COMPLETE ===")
    }
    
    /// Delete all shopping list subscriptions (useful for fixing broken subscriptions from bugs)
    private func cleanupBrokenSubscriptions() async {
        do {
            let privateSubs = try await privateDB.allSubscriptions()
            let sharedSubs = try await sharedDB.allSubscriptions()
            
            // Only the legacy per-list query subscriptions are broken. The zone
            // subscriptions (PrivateZone / SharedZone_*) are the working ones, so
            // deleting them here just opens a gap in which pushes are missed.
            let legacyPrefix = "\(sharedShoppingListSubscriptionPrefix)List_"
            let isLegacy: (CKSubscription) -> Bool = { $0.subscriptionID.hasPrefix(legacyPrefix) }
            let legacyPrivate = privateSubs.filter(isLegacy)
            let legacyShared = sharedSubs.filter(isLegacy)

            if legacyPrivate.isEmpty && legacyShared.isEmpty {
                print("[SharedShoppingListManager] 🔔 No old subscriptions to clean up")
                return
            }

            for (db, subs) in [(privateDB, legacyPrivate), (sharedDB, legacyShared)] {
                for sub in subs {
                    do {
                        try await db.deleteSubscription(withID: sub.subscriptionID)
                        print("[SharedShoppingListManager] 🔔 🗑️ Deleted old subscription: \(sub.subscriptionID)")
                    } catch {
                        print("[SharedShoppingListManager] 🔔 ⚠️ Failed to delete \(sub.subscriptionID): \(error)")
                    }
                }
            }
        } catch {
            print("[SharedShoppingListManager] 🔔 ⚠️ Cleanup error (non-fatal): \(error)")
        }
    }
    
    /// Creates a zone subscription for the private ShoppingListZone
    /// This catches ALL changes to shopping lists you own
    private func upsertPrivateZoneSubscription() async throws {
        let subscriptionID = "\(sharedShoppingListSubscriptionPrefix)PrivateZone"
        try await ensurePrivateZoneExists()
        
        // Check if already exists
        do {
            let existing = try await privateDB.subscription(for: subscriptionID)
            print("[SharedShoppingListManager] 🔔   Private zone subscription already exists: \(existing.subscriptionID)")
            return
        } catch {
            print("[SharedShoppingListManager] 🔔   Private zone subscription doesn't exist, creating...")
        }
        
        // Create zone subscription
        let sub = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: subscriptionID)
        
        let info = CKSubscription.NotificationInfo()
        info.alertBody = "Shopping list updated"
        info.soundName = "default"
        info.shouldBadge = true
        info.shouldSendContentAvailable = true
        info.category = sharedShoppingListUpdatedCategory
        
        sub.notificationInfo = info
        
        let saved = try await privateDB.save(sub)
        print("[SharedShoppingListManager] 🔔   ✅ Private zone subscription saved: \(saved.subscriptionID)")
    }
    
    /// Creates zone subscriptions for all shared shopping list zones
    /// This catches ALL changes to shopping lists shared with you
    private func upsertSharedZoneSubscriptions() async throws {
        // Get all shared zones
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
            sharedDB.add(op)
        }
        
        guard !zones.isEmpty else {
            print("[SharedShoppingListManager] 🔔   No shared zones found (no shared lists yet)")
            return
        }
        
        print("[SharedShoppingListManager] 🔔   Found \(zones.count) shared zones")
        
        // Create subscription for each shared zone
        for zid in zones {
            let subscriptionID = "\(sharedShoppingListSubscriptionPrefix)SharedZone_\(zid.zoneName)_\(zid.ownerName)"
            
            // Check if already exists
            do {
                _ = try await sharedDB.subscription(for: subscriptionID)
                print("[SharedShoppingListManager] 🔔   Shared zone subscription already exists: \(zid.zoneName)")
                continue
            } catch {
                // Doesn't exist, create it
            }
            
            let sub = CKRecordZoneSubscription(zoneID: zid, subscriptionID: subscriptionID)
            
            let info = CKSubscription.NotificationInfo()
            info.alertBody = "Shopping list updated"
            info.soundName = "default"
            info.shouldBadge = true
            info.shouldSendContentAvailable = true
            info.category = sharedShoppingListUpdatedCategory
            
            sub.notificationInfo = info
            
            do {
                _ = try await sharedDB.save(sub)
                print("[SharedShoppingListManager] 🔔   ✅ Shared zone subscription saved: \(zid.zoneName)")
            } catch {
                print("[SharedShoppingListManager] 🔔   ⚠️ Failed to create subscription for \(zid.zoneName): \(error)")
            }
        }
    }

    /// Creates a per-list CKQuerySubscription scoped to ONE anchor recordID.
    ///
    /// This is the critical change: it avoids the "global all lists" subscription and makes
    /// notifications much more deterministic and less noisy.
    private func upsertPerListSubscription(for anchor: CKRecord, in db: CKDatabase) async throws {
        let listUUID = (anchor[anchorListUUIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        print("[SharedShoppingListManager] 🔔   Upserting subscription for listUUID: \(listUUID.isEmpty ? "EMPTY!" : listUUID)")

        guard !listUUID.isEmpty else {
            print("[SharedShoppingListManager] 🔔   ❌ MISSING listUUID - throwing error")
            throw NSError(domain: "SharedShoppingListManager", code: 1001, userInfo: [
                NSLocalizedDescriptionKey: "Missing listUUID on anchor; cannot create per-list subscription."
            ])
        }

        let subscriptionID = "\(sharedShoppingListSubscriptionPrefix)List_\(db.databaseScope.rawValue)_\(listUUID)"
        print("[SharedShoppingListManager] 🔔   Subscription ID: \(subscriptionID)")

        // idempotent: if it exists, leave it
        do {
            let existing = try await db.subscription(for: subscriptionID)
            print("[SharedShoppingListManager] 🔔   ✅ Subscription already exists: \(existing.subscriptionID)")
            return
        } catch {
            print("[SharedShoppingListManager] 🔔   Subscription doesn't exist yet (error: \(error)), creating new one...")
        }

        // ✅ listUUID is a real field -> queryable
        let predicate = NSPredicate(format: "%K == %@", anchorListUUIDKey, listUUID)

        let sub = CKQuerySubscription(
            recordType: anchorRecordType,
            predicate: predicate,
            subscriptionID: subscriptionID,
            options: [.firesOnRecordUpdate]
        )

        let info = CKSubscription.NotificationInfo()
        info.alertBody = "Shopping list updated"
        info.soundName = "default"
        info.shouldBadge = true
        info.shouldSendContentAvailable = true
        info.category = sharedShoppingListUpdatedCategory
        // ✅ FIX: Remove large fields (itemsJSON, items) to avoid "notification additional fields limit exceeded" error
        // We only need small metadata fields; the app will fetch the full list when notification arrives
        info.desiredKeys = [
            anchorTitleKey,      // "name" - needed for notification text
            anchorEmojiKey,      // "emoji" - small, safe to include
            anchorListUUIDKey,   // "listUUID" - needed to identify which list changed
            anchorCategoryKey    // "category" - needed to confirm it's a shopping list
            // ❌ Removed: anchorItemsKey (can be large array of strings)
            // ❌ Removed: anchorItemsJSONKey (can be huge JSON blob)
        ]

        sub.notificationInfo = info
        
        print("[SharedShoppingListManager] 🔔   Saving subscription to CloudKit...")
        let saved = try await db.save(sub)
        print("[SharedShoppingListManager] 🔔   ✅ Subscription saved successfully: \(saved.subscriptionID)")
    }

    // OPTIONAL: cleanup subscriptions for lists you no longer have (safe to omit)
    private func cleanupOrphanPerListSubscriptions(knownAnchors: [CKRecord]) async {
        let knownIDs: Set<String> = Set(knownAnchors.map { a in
            "\(a.recordID.zoneID.ownerName)|\(a.recordID.zoneID.zoneName)|\(a.recordID.recordName)"
        })

        // best-effort cleanup in both DBs
        await cleanupOrphans(in: privateDB, knownIDs: knownIDs)
        await cleanupOrphans(in: sharedDB, knownIDs: knownIDs)
    }

    private func cleanupOrphans(in db: CKDatabase, knownIDs: Set<String>) async {
        do {
            let subs = try await db.allSubscriptions()
            let toDelete = subs.compactMap { sub -> String? in
                guard sub.subscriptionID.hasPrefix("\(sharedShoppingListSubscriptionPrefix)List_") else { return nil }

                // Attempt to parse out record identity from subscriptionID
                // Format: SharedShoppingList_List_<scope>_<owner>_<zone>_<recordName>
                let parts = sub.subscriptionID.split(separator: "_", omittingEmptySubsequences: true)
                guard parts.count >= 6 else { return sub.subscriptionID }

                let owner = String(parts[3])
                let zone = String(parts[4])
                let recordName = String(parts[5])
                let key = "\(owner)|\(zone)|\(recordName)"

                return knownIDs.contains(key) ? nil : sub.subscriptionID
            }

            guard !toDelete.isEmpty else { return }
            _ = try await db.modifySubscriptions(saving: [], deleting: toDelete)
        } catch {
            // best-effort
        }
    }
}
