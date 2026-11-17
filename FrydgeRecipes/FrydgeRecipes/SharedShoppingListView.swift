//
//  SharedShoppingListView.swift
//  FrydgeRecipes
//
//  Created by Josh on 02/01/2026.
//

import SwiftUI
import CloudKit

struct SharedShoppingListView: View {

    @EnvironmentObject var frydgeManager: FrydgeManager
    @StateObject private var sharedManager = SharedShoppingListManager()

    private struct ShareSheetPayload: Identifiable {
        enum Kind { case invite, manage }
        let id = UUID()
        let kind: Kind
        let share: CKShare
        let root: CKRecord
    }

    @State private var activeSheet: ShareSheetPayload? = nil
    @State private var expandedListKeys: Set<String> = []

    @State private var showAddProductSheet = false
    @State private var addTargetAnchor: CKRecord?

    @State private var stockAvailability: [String: Bool?] = [:] // key = listKey|item
    @State private var queriedAvailabilityKeys: Set<String> = []
    @State private var tickedToFrydgeKeys: Set<String> = []

    // Prevent double-taps / cold-start grey sheet
    @State private var isPreparingInvite: Bool = false
    @State private var isPreparingShare: Bool = false
    @State private var preparingShareAnchorID: CKRecord.ID? = nil

    // Create multiple lists
    @State private var showCreateListSheet: Bool = false
    @State private var newListName: String = ""
    @State private var newListEmoji: String = "🛒"
    @State private var createInFlight: Bool = false

    // Must match SharedShoppingListManager.zoneName
    private let shoppingListZoneName = "ShoppingListZone"

    // Shared list identity field (stored on the anchor record)
    private let listUUIDKey = "listUUID"

    private func databaseForAnchor(_ anchor: CKRecord, container: CKContainer) -> CKDatabase {
        // IMPORTANT: Only treat it as PRIVATE if it’s your ShoppingListZone.
        // Everything else should be assumed SHARED.
        let zid = anchor.recordID.zoneID
        if zid.ownerName == CKCurrentUserDefaultName && zid.zoneName == shoppingListZoneName {
            return container.privateCloudDatabase
        }
        return container.sharedCloudDatabase
    }

    /// Optimistically drops a deleted/left list from local state, then refreshes
    /// from CloudKit. Used by both the manage sheet and the invite flow.
    private func forgetListLocally(rootID: CKRecord.ID, listKey: String) {
        Task { @MainActor in
            sharedManager.sharedAnchors.removeAll { $0.recordID == rootID }
            sharedManager.itemsByAnchorID.removeValue(forKey: rootID)
            sharedManager.displayNameByAnchorID.removeValue(forKey: rootID)
            sharedManager.emojiByAnchorID.removeValue(forKey: rootID)
            sharedManager.isOwnerByAnchorID.removeValue(forKey: rootID)
            expandedListKeys.remove(listKey)

            activeSheet = nil
        }
        Task { await sharedManager.refreshSharedLists() }
    }

    // Stable key for UI state + availability/tick caches
    private func listKey(for anchor: CKRecord) -> String {
        if let v = anchor[listUUIDKey] as? String {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        // fallback for older lists before migration
        return "\(anchor.recordID.recordName)|\(anchor.recordID.zoneID.zoneName)|\(anchor.recordID.zoneID.ownerName)"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {

                header

                if let err = sharedManager.lastError, !err.isEmpty {
                    Text(err)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                if sharedManager.isLoading {
                    ProgressView()
                        .padding(.horizontal)
                }

                List {
                    if sharedManager.sharedAnchors.isEmpty && !sharedManager.isLoading {
                        emptyStateRow
                    } else {
                        ForEach(sharedManager.sharedAnchors, id: \.recordID) { anchor in
                            sharedAnchorDisclosureRow(anchor)
                        }
                    }
                }
                .listStyle(.plain)
                .transaction { txn in txn.disablesAnimations = true }
                .refreshable {
                    await sharedManager.refreshSharedLists()
                }
            }
            .task {
                if !sharedManager.isLoading {
                    await sharedManager.refreshSharedLists()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cloudShareAcceptedMetadata)) { _ in
                Task { @MainActor in
                    if !sharedManager.isLoading {
                        await sharedManager.refreshSharedLists()
                    }
                }
            }

            // MARK: - Create list sheet
            .sheet(isPresented: $showCreateListSheet) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("New shopping list")
                                .font(.headline)
                                .padding(.top, 8)

                            Text("Everyone you invite sees the same list, updated live as items are added or ticked off.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Name")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            TextField("e.g. Weekly shop", text: $newListName)
                                .textFieldStyle(.roundedBorder)

                            Text("Emoji")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 6)

                            TextField("e.g. 🛒", text: $newListEmoji)
                                .textFieldStyle(.roundedBorder)
                        }

                        Spacer(minLength: 0)

                        HStack(spacing: 12) {
                            Button("Cancel") { showCreateListSheet = false }
                                .buttonStyle(.bordered)

                            Spacer()

                            Button {
                                Task {
                                    if createInFlight { return }
                                    createInFlight = true
                                    defer { createInFlight = false }
                                    await prepareInviteShare(named: newListName, emoji: newListEmoji)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    if isPreparingInvite {
                                        ProgressView().progressViewStyle(.circular)
                                    }
                                    Text("Create & Share")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isPreparingInvite || createInFlight || newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(.bottom, 8)
                    }
                    .padding(16)
                    .navigationTitle("Shopping List")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }

            // MARK: - Cloud share sheet
            .sheet(item: $activeSheet) { payload in
                let ckContainer = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
                let db = databaseForAnchor(payload.root, container: ckContainer)

                let leavingRootID = payload.root.recordID
                let leavingListKey = listKey(for: payload.root)

                // Uses share-derived owner when available, otherwise falls back to zone ownership.
                let isOwnerNow = sharedManager.isOwnerCached(for: payload.root)

                if payload.kind == .manage {
                    // Native management sheet: members, permissions, rename,
                    // stop sharing / delete / leave. Inviting still goes through
                    // the system controller from inside this sheet.
                    ShareManagementSheet(
                        container: ckContainer,
                        database: db,
                        kind: .shoppingList,
                        share: payload.share,
                        rootRecord: payload.root,
                        initialName: sharedManager.displayNameByAnchorID[leavingRootID],
                        onChanged: {
                            Task { await sharedManager.refreshSharedLists() }
                        },
                        onDeleted: {
                            forgetListLocally(rootID: leavingRootID, listKey: leavingListKey)
                        },
                        onLeft: {
                            forgetListLocally(rootID: leavingRootID, listKey: leavingListKey)
                        },
                        onStoppedSharing: {
                            Task { await sharedManager.refreshSharedLists() }
                        }
                    )
                } else {
                    CloudSharingView(
                        container: ckContainer,
                        share: payload.share,
                        rootRecord: payload.root,
                        initialTitle: "Default – Shopping List",
                        logoImageName: "AppIcon",
                        defaultTitle: "Frydge – Shopping List",
                        rootNameKey: "name",
                        rootEmojiKey: "emoji",
                        shareKind: "shoppingList",
                        rootDatabase: db,

                        onShareSaved: { _, _ in
                            Task { await sharedManager.refreshSharedLists() }
                        },
                        onStopSharing: { _, _ in
                            Task { await sharedManager.refreshSharedLists() }
                        },
                        onShareSaveFailed: { err in
                            sharedManager.lastError = err.localizedDescription
                        },
                        onDeleted: { _, _ in
                            forgetListLocally(rootID: leavingRootID, listKey: leavingListKey)
                        },
                        onLeftShare: { _, _ in
                            forgetListLocally(rootID: leavingRootID, listKey: leavingListKey)
                        },
                        // ✅ Owners can delete; participants cannot.
                        allowDelete: isOwnerNow,

                        // ✅ Participants can leave; owners cannot.
                        allowLeaveForParticipants: !isOwnerNow
                    )
                }
            }

            // MARK: - Add item sheet
            .sheet(isPresented: $showAddProductSheet) {
                ProductDetailsView(
                    isShowing: $showAddProductSheet,
                    productDetails: nil,
                    context: .shopping,
                    onSaveStructuredItem: { name, qty, unit, location, tags in
                        guard let anchor = addTargetAnchor else { return }
                        let cleanedName = name
                            .replacingOccurrences(of: "-", with: " ")
                            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleanedName.isEmpty else { return }

                        let item = SharedShoppingListItem(
                            name: cleanedName,
                            quantity: qty,
                            unit: unit,
                            location: location,
                            dietaryTags: tags
                        )
                        Task { await addItem(item, to: anchor) }
                    }
                )
                .environmentObject(frydgeManager)
            }
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                Text("Shared shopping lists")
                    .font(.headline)
            }
            .foregroundColor(.blue)

            Spacer()

            Button {
                newListName = ""
                newListEmoji = "🛒"
                showCreateListSheet = true
                sharedManager.lastError = nil
            } label: {
                if isPreparingInvite {
                    ProgressView()
                        .progressViewStyle(.circular)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                }
            }
            .disabled(isPreparingInvite)
            .accessibilityLabel("Invite to shared shopping list")
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var emptyStateRow: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: "tray.full")
            Text("No shared lists yet")
                .font(.callout)
                .foregroundColor(.secondary)
            Text("Use the + button to invite someone, or accept an invite to see it here.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .listRowSeparator(.hidden)
    }

    private func sharedAnchorDisclosureRow(_ anchor: CKRecord) -> some View {
        let id = anchor.recordID

        let rawName = (anchor["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = ((rawName?.isEmpty == false) ? rawName : nil)
            ?? sharedManager.displayNameByAnchorID[id]
            ?? "Frydge – Shopping List"

        let rawEmoji = (anchor["emoji"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let emoji = ((rawEmoji?.isEmpty == false) ? rawEmoji : nil)
            ?? sharedManager.emojiByAnchorID[id]
            ?? "🛒"

        let items = sharedManager.itemsDetailed(for: anchor)

        let listKeyValue = listKey(for: anchor)
        let isExpanded = expandedListKeys.contains(listKeyValue)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {

                Button {
                    guard !(isPreparingShare && preparingShareAnchorID == id) else { return }
                    Task { await openSharing(for: anchor) }
                } label: {
                    HStack(spacing: 12) {
                        Text(emoji)
                            .font(.title2)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(name)
                                    .font(.headline)
                                    .lineLimit(1)
                                    .foregroundColor(.primary)

                                if isPreparingShare, preparingShareAnchorID == id {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .scaleEffect(0.85)
                                }
                            }

                            Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1, height: 22)
                    .padding(.trailing, 5)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedListKeys.remove(listKeyValue)
                        } else {
                            expandedListKeys.insert(listKeyValue)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if isExpanded {
                Divider()
                    .opacity(0.25)
                    .padding(.horizontal, 12)
                    .task {
                        // Prime only the first 5 items when the list opens
                        let firstFive = Array(items.prefix(5))
                        for it in firstFive {
                            await primeAvailabilityIfNeeded(listKey: listKeyValue, item: it.displayString)
                        }
                    }

                VStack(alignment: .leading, spacing: 10) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                            .frame(height: 10)

                        Divider()
                            .opacity(0.25)
                            .padding(.horizontal, 12)

                        HStack {
                            Spacer()
                            Button {
                                addTargetAnchor = anchor
                                showAddProductSheet = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text("Item")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.blue)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add item")
                            Spacer()
                        }
                        .padding(.vertical, 12)

                        Divider()
                            .opacity(0.25)
                            .padding(.horizontal, 12)

                        if items.isEmpty {
                            Text("No items yet.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                        } else {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                let key = availabilityKey(listKey: listKeyValue, item: item.displayString) + "|\(item.id.uuidString)"

                                SwipeToDeleteRow(onDelete: {
                                    Task { await removeItem(at: idx, from: anchor, id: item.id) }
                                }) {
                                    sharedListRowContent(item: item, key: key, listKey: listKeyValue, index: idx, anchor: anchor)
                                }
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                            )
                    )
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 12)
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(
            VStack(spacing: 1) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                    )
                    .padding(.horizontal, 8)
                Color.clear.frame(height: 1)
            }
        )
    }

    // MARK: - Warm share before presenting

    private func prepareInviteShare(named name: String, emoji: String) async {
        if isPreparingInvite { return }
        await MainActor.run {
            isPreparingInvite = true
            sharedManager.lastError = nil
        }
        defer { Task { @MainActor in isPreparingInvite = false } }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let ckContainer = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")

        do {
            let (share, root) = try await sharedManager.createSharePairForNewShoppingList(
                named: trimmedName,
                emoji: trimmedEmoji.isEmpty ? "🛒" : trimmedEmoji
            )

            let db = ckContainer.privateCloudDatabase
            let (freshShare, freshRoot) = try await commitAndRefetchSharePair(share: share, root: root, db: db)

            await MainActor.run {
                showCreateListSheet = false
                newListName = ""
                newListEmoji = "🛒"
                activeSheet = ShareSheetPayload(kind: .invite, share: freshShare, root: freshRoot)
                Task { await sharedManager.refreshSharedLists() }
            }
        } catch {
            await MainActor.run {
                sharedManager.lastError = error.localizedDescription
            }
        }
    }

    private func prepareInviteShareForDefaultList() async {
        if isPreparingInvite { return }
        await MainActor.run {
            isPreparingInvite = true
            sharedManager.lastError = nil
        }
        defer { Task { @MainActor in isPreparingInvite = false } }

        let ckContainer = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")

        do {
            let (share, root) = try await sharedManager.ensureSharePairForMyShoppingList()
            let db = ckContainer.privateCloudDatabase
            let (freshShare, freshRoot) = try await commitAndRefetchSharePair(share: share, root: root, db: db)

            await MainActor.run {
                activeSheet = ShareSheetPayload(kind: .invite, share: freshShare, root: freshRoot)
            }
        } catch {
            await MainActor.run {
                sharedManager.lastError = error.localizedDescription
            }
        }
    }

    private func commitAndRefetchSharePair(share: CKShare, root: CKRecord, db: CKDatabase) async throws -> (CKShare, CKRecord) {
        try await withCheckedThrowingContinuation { cont in
            let op = CKModifyRecordsOperation(recordsToSave: [root, share], recordIDsToDelete: nil)
            op.savePolicy = .changedKeys
            op.isAtomic = true
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

        let freshRoot = try await db.record(for: root.recordID)

        if let shareRef = freshRoot.share {
            let shareRecord = try await db.record(for: shareRef.recordID)
            guard let freshShare = shareRecord as? CKShare else {
                throw NSError(domain: "CloudSharingView", code: -11)
            }
            return (freshShare, freshRoot)
        } else {
            let sr = try await db.record(for: share.recordID)
            guard let s = sr as? CKShare else {
                throw NSError(domain: "CloudSharingView", code: -10)
            }
            return (s, freshRoot)
        }
    }

    private func openSharing(for anchor: CKRecord) async {
        if isPreparingShare { return }

        await MainActor.run {
            isPreparingShare = true
            preparingShareAnchorID = anchor.recordID
            sharedManager.lastError = nil
        }
        defer {
            Task { @MainActor in
                isPreparingShare = false
                preparingShareAnchorID = nil
            }
        }

        do {
            guard let pair = try await resolveSharePair(for: anchor) else {
                await MainActor.run {
                    sharedManager.lastError = "This list can’t be opened yet."
                }
                return
            }

            await MainActor.run {
                activeSheet = ShareSheetPayload(kind: .manage, share: pair.0, root: pair.1)
            }
        } catch {
            await MainActor.run {
                if let ckErr = error as? CKError, ckErr.code == .unknownItem {
                    sharedManager.lastError = "This shared list can’t be opened (share no longer exists). Ask the owner to re-share it."
                } else {
                    sharedManager.lastError = error.localizedDescription
                }
            }
            Task { await sharedManager.refreshSharedLists() }
        }
    }

    // Self-heal missing shares for owners (recreate) and stop the “forever spinner”.
    private func resolveSharePair(for anchor: CKRecord) async throws -> (CKShare, CKRecord)? {
        let ckContainer = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        let db = databaseForAnchor(anchor, container: ckContainer)

        let freshRoot = try await db.record(for: anchor.recordID)
        let isOwnerNow = sharedManager.isOwnerCached(for: freshRoot) // ✅ better than zone-only checks

        guard let shareRef = freshRoot.share else {
            if isOwnerNow {
                let newShare = CKShare(rootRecord: freshRoot)
                newShare[CKShare.SystemFieldKey.title] = (freshRoot["name"] as? String ?? "Frydge – Shopping List") as CKRecordValue
                newShare.publicPermission = .none

                try await withCheckedThrowingContinuation { cont in
                    let op = CKModifyRecordsOperation(recordsToSave: [freshRoot, newShare], recordIDsToDelete: nil)
                    op.savePolicy = .changedKeys
                    op.isAtomic = true
                    op.modifyRecordsResultBlock = { result in
                        switch result {
                        case .success: cont.resume()
                        case .failure(let err): cont.resume(throwing: err)
                        }
                    }
                    db.add(op)
                }

                let refetchedRoot = try await db.record(for: freshRoot.recordID)
                guard let refetchedShareRef = refetchedRoot.share else { return nil }
                let shareRecord = try await db.record(for: refetchedShareRef.recordID)
                return (shareRecord as? CKShare).map { ($0, refetchedRoot) }
            }

            throw CKError(.unknownItem)
        }

        do {
            let shareRecord = try await db.record(for: shareRef.recordID)
            guard let share = shareRecord as? CKShare else { return nil }
            return (share, freshRoot)
        } catch {
            if let ckErr = error as? CKError, ckErr.code == .unknownItem {
                if isOwnerNow {
                    let newShare = CKShare(rootRecord: freshRoot)
                    let title = (freshRoot["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    newShare[CKShare.SystemFieldKey.title] = ((title?.isEmpty == false) ? title! : "Frydge – Shopping List") as CKRecordValue
                    newShare.publicPermission = .none

                    try await withCheckedThrowingContinuation { cont in
                        let op = CKModifyRecordsOperation(recordsToSave: [freshRoot, newShare], recordIDsToDelete: nil)
                        op.savePolicy = .changedKeys
                        op.isAtomic = true
                        op.modifyRecordsResultBlock = { result in
                            switch result {
                            case .success: cont.resume()
                            case .failure(let err): cont.resume(throwing: err)
                            }
                        }
                        db.add(op)
                    }

                    let refetchedRoot = try await db.record(for: freshRoot.recordID)
                    guard let refetchedShareRef = refetchedRoot.share else { return nil }
                    let shareRecord = try await db.record(for: refetchedShareRef.recordID)
                    guard let recreated = shareRecord as? CKShare else { return nil }
                    return (recreated, refetchedRoot)
                } else {
                    throw ckErr
                }
            }
            throw error
        }
    }

    // MARK: - Shared shopping items persistence

    private func addItem(_ item: SharedShoppingListItem, to anchor: CKRecord) async {
        let cleanedName = item.name
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { return }

        var items = sharedManager.itemsDetailed(for: anchor)

        let newSig = (
            cleanedName.lowercased(),
            item.quantity.trimmingCharacters(in: .whitespacesAndNewlines),
            item.unit.trimmingCharacters(in: .whitespacesAndNewlines),
            item.location.trimmingCharacters(in: .whitespacesAndNewlines),
            Set(item.dietaryTags.map { $0.uppercased() })
        )

        let exists = items.contains { existing in
            let sig = (
                existing.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                existing.quantity.trimmingCharacters(in: .whitespacesAndNewlines),
                existing.unit.trimmingCharacters(in: .whitespacesAndNewlines),
                existing.location.trimmingCharacters(in: .whitespacesAndNewlines),
                Set(existing.dietaryTags.map { $0.uppercased() })
            )
            return sig.0 == newSig.0 && sig.1 == newSig.1 && sig.2 == newSig.2 && sig.3 == newSig.3 && sig.4 == newSig.4
        }

        if !exists {
            var toAdd = item
            toAdd.name = cleanedName
            items.append(toAdd)
            await sharedManager.setItemsDetailed(items, for: anchor)
        }
    }

    /// Removes an item and returns whether the shared list is now saved without it.
    /// Pass `id` whenever the row has one: another member's edit can shift indexes
    /// between render and tap, and an index-only removal then deletes the wrong item.
    @discardableResult
    private func removeItem(at index: Int, from anchor: CKRecord, id: UUID? = nil) async -> Bool {
        var items = sharedManager.itemsDetailed(for: anchor)
        if let id {
            // Already removed by someone else: nothing left to do.
            guard let current = items.firstIndex(where: { $0.id == id }) else { return true }
            items.remove(at: current)
        } else {
            guard items.indices.contains(index) else { return false }
            items.remove(at: index)
        }
        return await sharedManager.setItemsDetailed(items, for: anchor)
    }

    @ViewBuilder
    private func sharedListRowContent(item: SharedShoppingListItem, key: String, listKey: String, index: Int, anchor: CKRecord) -> some View {
        Group {
            if let payload = item.recipeSuggestionPayload {
                recipeSuggestionRow(payload: payload, index: index, anchor: anchor)
            } else {
                sharedShoppingItemRow(item: item, key: key, listKey: listKey, index: index, anchor: anchor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func sharedShoppingItemRow(item: SharedShoppingListItem, key: String, listKey: String, index: Int, anchor: CKRecord) -> some View {
        let isTicked = tickedToFrydgeKeys.contains(key)
        let location = item.location.trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayString)
                    .font(.body)
                    .foregroundColor(.primary)

                HStack(spacing: 8) {
                    dietaryBadges(for: item)

                    if !location.isEmpty {
                        Text(location)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.secondary.opacity(0.12))
                            )
                    }
                }
            }

            Spacer()

            availabilityView(for: key)

            Button {
                Task { await tickIntoFrydgeAndRemove(listKey: listKey, index: index, item: item, anchor: anchor) }
            } label: {
                Image(systemName: isTicked ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isTicked ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add to Frydge")
        }
    }

    private func acceptRecipeSuggestion(_ payload: RecipeSuggestionPayload, at index: Int, from anchor: CKRecord) async {
        var items = sharedManager.itemsDetailed(for: anchor)
        guard items.indices.contains(index) else { return }
        items.remove(at: index)

        var existingNames = Set(items.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let tags = normalizedDietaryTagsForSuggestion(payload.dietaryTags)

        for rawIngredient in payload.ingredients {
            let name = rawIngredient
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            guard !existingNames.contains(name.lowercased()) else { continue }
            existingNames.insert(name.lowercased())

            items.append(
                SharedShoppingListItem(
                    name: name,
                    quantity: "",
                    unit: "",
                    location: "Shopping",
                    dietaryTags: tags
                )
            )
        }

        await sharedManager.setItemsDetailed(items, for: anchor)
    }

    private func normalizedDietaryTagsForSuggestion(_ recipeTags: [String]) -> [String] {
        let wanted: Set<String> = ["DF", "GF", "V", "VG", "DAIRY FREE", "GLUTEN FREE", "VEGETARIAN", "VEGAN"]
        return Array(Set(recipeTags.compactMap { tag in
            let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard wanted.contains(normalized) else { return nil }
            if normalized == "DAIRY FREE" { return "DF" }
            if normalized == "GLUTEN FREE" { return "GF" }
            if normalized == "VEGETARIAN" { return "V" }
            if normalized == "VEGAN" { return "VG" }
            return normalized
        })).sorted()
    }

    private func recipeSuggestionRow(payload: RecipeSuggestionPayload, index: Int, anchor: CKRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "fork.knife.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(payload.recipeName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text("\(payload.ingredients.count) ingredients")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await acceptRecipeSuggestion(payload, at: index, from: anchor) }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Accept recipe suggestion")

            Button {
                Task { await removeItem(at: index, from: anchor) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Decline recipe suggestion")
        }
    }

    // MARK: - Dietary badges

    @ViewBuilder
    private func dietaryBadges(for item: SharedShoppingListItem) -> some View {
        let tagsUpper = Set(item.dietaryTags.map { $0.uppercased() })
        HStack(spacing: 6) {
            if tagsUpper.contains("DF") { DietaryBadgeChip(tag: "DF", tone: .brand) }
            if tagsUpper.contains("GF") { DietaryBadgeChip(tag: "GF", tone: .brand) }
            if tagsUpper.contains("V")  { DietaryBadgeChip(tag: "V",  tone: .brand) }
        }
    }

    // MARK: - Availability + Tick helpers

    private func availabilityKey(listKey: String, item: String) -> String {
        "\(listKey)|\(stockNormalize(item))"
    }

    @ViewBuilder
    private func availabilityView(for key: String) -> some View {
        if let value = stockAvailability[key] {
            if let available = value {
                Circle()
                    .fill(available ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
            } else {
                ProgressView()
                    .frame(width: 14, height: 14)
            }
        } else {
            ProgressView()
                .frame(width: 14, height: 14)
        }
    }

    private func primeAvailabilityIfNeeded(listKey: String, item: String) async {
        let key = availabilityKey(listKey: listKey, item: item)
        guard !queriedAvailabilityKeys.contains(key) else { return }
        queriedAvailabilityKeys.insert(key)

        stockAvailability[key] = nil

        let available = await StockAvailability.checkAnyStoreAvailability(for: item)
        await MainActor.run {
            stockAvailability[key] = available
        }
    }
    
    private func normalizeFrydgeLocation(_ raw: String) -> String {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Make this strict: FrydgeView expects "Dry", "Fridge", "Freezer"
        if v.contains("freez") { return "Freezer" }
        if v.contains("dry") || v.contains("pantry") || v.contains("cupboard") { return "Dry" }

        // fallback
        return "Fridge"
    }

    private func computedExpiryDate(for item: SharedShoppingListItem) -> Date {
        StoredIngredient.defaultExpiry(for: item.name)
    }

    private func tickIntoFrydgeAndRemove(listKey: String, index: Int, item: SharedShoppingListItem, anchor: CKRecord) async {
        let key = availabilityKey(listKey: listKey, item: item.displayString) + "|\(item.id.uuidString)"
        if tickedToFrydgeKeys.contains(key) { return }
        tickedToFrydgeKeys.insert(key)

        let cleanedName = item.name
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { return }

        let exp = computedExpiryDate(for: item)

        let qty = item.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = item.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLoc = normalizeFrydgeLocation(item.location)

        // Take it off the shared list first. If that save fails (offline, read-only
        // share) nothing was added to the fridge, so the tick can simply be retried
        // instead of leaving the item both ticked-off here and duplicated in the fridge.
        guard await removeItem(at: index, from: anchor, id: item.id) else {
            tickedToFrydgeKeys.remove(key)
            return
        }

        await MainActor.run {
            frydgeManager.addProduct(
                name: cleanedName,
                quantity: qty.isEmpty ? "1" : qty,
                unit: unit,
                expirationDate: exp,
                location: normalizedLoc,
                dietaryTags: Set(item.dietaryTags),
                lifecycle: .fridge
            )
        }
    }

    private func stockNormalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let stripped = lowered
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        let cleaned = stripped.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                return Character(scalar)
            }
            return " "
        }

        let collapsed = String(cleaned)
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")

        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
