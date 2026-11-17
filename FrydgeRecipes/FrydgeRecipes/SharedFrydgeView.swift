//
//  SharedFrydgeView.swift
//  FrydgeRecipes
//
//  Created by Josh on 20/11/2025.
//

import SwiftUI
import CloudKit
import UIKit

// MARK: - CKShare Metadata Extensions

extension CKShare.Metadata {
    var displaySenderNamePublic: String {
        if let comps = self.ownerIdentity.nameComponents {
            return comps.formatted()
        }
        return "Shared with you"
    }

    var displayShareTitlePublic: String {
        if let raw = self.share[CKShare.SystemFieldKey.title] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let fallback = self.share.recordID.recordName
        return fallback.isEmpty ? "Shared Frydge" : fallback
    }
}

// MARK: - SharedFridgeView

struct SharedFridgeView: View {
    @EnvironmentObject var invites: PendingInvites
    @EnvironmentObject var frydgeManager: FrydgeManager

    // Use the single app-level manager (injected by FridgeView) so drop targets,
    // context menus and the item cache all operate on the same instance.
    @EnvironmentObject var sharedManager: SharedFridgeManager


    @State private var newFridgeName: String = ""
    @State private var renameText: String = ""

    // Per-fridge expand (NOT global)
    @State private var expandedIDs: Set<CKRecord.ID> = []


    // MARK: - Item detail (shared items open the same sheet as "Mine")

    private struct SharedItemSelection: Identifiable {
        let rec: CKRecord
        let anchor: CKRecord
        let scope: SharedFridgeManager.ShareScope
        var id: String { rec.recordID.recordName }
    }

    @State private var selectedSharedItem: SharedItemSelection? = nil

    // Which fridge row is currently a drag-drop target (for highlight).
    @State private var dropTargetedFridgeID: CKRecord.ID? = nil

    // One-time optional Sign in with Apple offer before the first sharing action.
    @State private var showSignInPrompt = false

    // MARK: - Single sheet router

    private enum ActiveSheet: Identifiable {
        case create
        case sharePending(share: CKShare, root: CKRecord)
        case invitations
        case rename(anchor: CKRecord, scope: SharedFridgeManager.ShareScope, title: String)
        case manageShare(share: CKShare, root: CKRecord, scope: SharedFridgeManager.ShareScope)
        case productDetails(anchor: CKRecord, scope: SharedFridgeManager.ShareScope)
        case receiptScan(anchor: CKRecord, scope: SharedFridgeManager.ShareScope)
        case moveToShared

        var id: String {
            switch self {
            case .create:
                return "create"
            case .sharePending(let share, _):
                return "sharePending_\(share.recordID.recordName)"
            case .invitations:
                return "invitations"
            case .rename(let anchor, let scope, _):
                return "rename_\(scope)_\(anchor.recordID.recordName)"
            case .manageShare(let share, _, let scope):
                return "manage_\(scope)_\(share.recordID.recordName)"
            case .productDetails(let anchor, let scope):
                return "productDetails_\(scope)_\(anchor.recordID.recordName)"
            case .receiptScan(let anchor, let scope):
                return "receiptScan_\(scope)_\(anchor.recordID.recordName)"
            case .moveToShared:
                return "moveToShared"
            }
        }
    }

    @State private var activeSheet: ActiveSheet? = nil
    @State private var pendingInvitePresentation: Bool = false
    @State private var preparingManagementFridgeID: CKRecord.ID? = nil

    var body: some View {
        content
            .sheet(isPresented: $showSignInPrompt) {
                AppleSignInPromptSheet(actionDescription: "create a shared frydge") {
                    newFridgeName = ""
                    activeSheet = .create
                }
            }
            .sheet(item: $activeSheet, onDismiss: {
                // If an invite arrived while another sheet was open, present it next.
                if pendingInvitePresentation, !invites.metas.isEmpty {
                    pendingInvitePresentation = false
                    activeSheet = .invitations
                }
            }) { sheet in
                switch sheet {
                case .create:
                    createSheet

                case .sharePending(let share, let root):
                    CloudSharingView(
                        container: CKContainer(identifier: "iCloud.com.Clark-Online.Recipe"),
                        share: share,
                        rootRecord: root,
                        initialTitle: sharedManager.namesByFridge[root.recordID],
                        defaultTitle: "Frydge – Fridge",
                        rootNameKey: "name",
                        rootEmojiKey: "emoji",
                        shareKind: "fridge",
                        rootDatabase: CKContainer(identifier: "iCloud.com.Clark-Online.Recipe").privateCloudDatabase,
                        allowLeaveForParticipants: true
                    )
                    .onDisappear {
                        Task { await sharedManager.reloadFridges() }
                    }

                case .invitations:
                    InvitationsView(onAccepted: {
                        // Dismiss the invitations sheet, then reload fridges.
                        activeSheet = nil
                        Task { await sharedManager.reloadFridges() }
                    })
                    .environmentObject(invites)

                case .rename(let anchor, let scope, _):
                    renameSheet(anchor: anchor, scope: scope)

                case .manageShare(let share, let root, let scope):
                    let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
                    ShareManagementSheet(
                        container: container,
                        database: (scope == .owned ? container.privateCloudDatabase : container.sharedCloudDatabase),
                        kind: .fridge,
                        share: share,
                        rootRecord: root,
                        initialName: sharedManager.namesByFridge[root.recordID],
                        onChanged: {
                            Task { await sharedManager.reloadFridges() }
                        },
                        onDeleted: {
                            activeSheet = nil
                            Task { await sharedManager.reloadFridges() }
                        },
                        onLeft: {
                            activeSheet = nil
                            Task { await sharedManager.reloadFridges() }
                        },
                        onStoppedSharing: {
                            Task { await sharedManager.reloadFridges() }
                        }
                    )
                    .onDisappear {
                        Task { await sharedManager.reloadFridges() }
                    }

                case .productDetails(let anchor, let scope):
                    ProductDetailsView(
                        isShowing: .constant(true),
                        productDetails: nil,
                        context: .sharedFridge(anchor: anchor, db: dbFor(scope: scope))
                    )
                    .environmentObject(frydgeManager)
                    .onDisappear {
                        Task { await sharedManager.loadItems(for: anchor, scope: scope) }
                    }

                case .receiptScan(let anchor, let scope):
                    // Opens with this frydge already chosen; the destination
                    // picker on the confirmation screen can still change it.
                    ReceiptScanView(initialDestination: .shared(anchor.recordID))
                        .environmentObject(frydgeManager)
                        .environmentObject(sharedManager)
                        .onDisappear {
                            Task { await sharedManager.loadItems(for: anchor, scope: scope) }
                        }

                case .moveToShared:
                    MoveToSharedFrydgeSheet(
                        sharedFridgeManager: sharedManager,
                        onCancel: { activeSheet = nil },
                        onMove: { selectedAnchor in
                            // NOTE: actual move of items is triggered from FridgeView.
                            // This picker only returns the destination anchor.
                            NotificationCenter.default.post(
                                name: .didPickMoveToSharedFrydgeDestination,
                                object: nil,
                                userInfo: ["anchorRecordName": selectedAnchor.recordID.recordName]
                            )
                            activeSheet = nil
                        }
                    )
                }
            }
            // Shared items open the very same detail sheet as "Mine"; edits route
            // to CloudKit via the shared manager instead of FrydgeManager.
            .sheet(item: $selectedSharedItem) { sel in
                IngredientDetailSheet(
                    ingredient: StoredIngredient(fromSharedRecord: sel.rec),
                    actions: sharedActions(for: sel),
                    onUsageChanged: { newValue in
                        Task {
                            await sharedManager.updateSharedItemUsage(
                                recordName: sel.rec.recordID.recordName,
                                quantityUsed: newValue
                            )
                        }
                    }
                )
                .environmentObject(frydgeManager)
                .onDisappear {
                    Task { await sharedManager.loadItems(for: sel.anchor, scope: sel.scope) }
                }
            }
            .alert("Sharing Error", isPresented: isShowingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(sharedManager.errorMessage ?? "")
            }
            .task { await sharedManager.reloadFridges() }
            .onChange(of: invites.metas.count) { _, newValue in
                guard newValue > 0 else { return }
                if activeSheet == nil {
                    activeSheet = .invitations
                } else {
                    pendingInvitePresentation = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cloudShareAcceptedMetadata)) { _ in
                Task { await sharedManager.reloadFridges() }
            }
            // ✅ Listen for shared frydge changes (CloudKit push notifications)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SharedFrydgeChanged"))) { _ in
                print("[SharedFridgeView] Received SharedFrydgeChanged notification")
                Task { await sharedManager.reloadFridges() }
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            topBar
                .padding(.horizontal)
            fridgeList
        }
        // Height hugs content: this lays out inside the parent FridgeView ScrollView
        // (no longer its own scroll view), so it must not grab infinite height.
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                    Text("Shared frydges")
                        .font(.headline)
                }
                .foregroundStyle(.blue)

                Spacer()

                // Grouped in one container so the glass shapes can blend/morph
                // together rather than rendering as three separate materials.
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            activeSheet = .invitations
                        } label: {
                            Image(systemName: invites.metas.isEmpty ? "envelope.badge" : "envelope.badge.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.blue)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Invitations")

                        Button {
                            // First sharing action: offer (don't require) an Apple ID link
                            // so household members can see who created the frydge.
                            if AppleSignInGate.shouldOfferBeforeSharing {
                                showSignInPrompt = true
                            } else {
                                newFridgeName = ""
                                activeSheet = .create
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.blue)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Create a shared frydge")

                        Button {
                            activeSheet = .moveToShared
                        } label: {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.blue)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Move items to a shared frydge")
                    }
                }
            }

            Text("Drag an item onto a frydge to share it")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // No nested ScrollView: the frydge cards lay out as a plain VStack so the parent
    // FridgeView ScrollView owns scrolling and drag-and-drop routes cleanly to each
    // card. Pull-to-refresh is provided by the parent list.
    private var fridgeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !sharedManager.owned.isEmpty {
                ForEach(sharedManager.owned, id: \.recordID) { anchor in
                    fridgeRow(anchor: anchor, scope: .owned)
                }
            }

            if !sharedManager.incoming.isEmpty {
                ForEach(sharedManager.incoming, id: \.recordID) { anchor in
                    fridgeRow(anchor: anchor, scope: .incoming)
                }
            }

            if sharedManager.owned.isEmpty && sharedManager.incoming.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Share a frydge with your household so everyone sees the same fridge and shopping list.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        if AppleSignInGate.shouldOfferBeforeSharing {
                            showSignInPrompt = true
                        } else {
                            newFridgeName = ""
                            activeSheet = .create
                        }
                    } label: {
                        Label("Create a Shared Frydge", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.glassProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }
        }
    }

    private var isShowingError: Binding<Bool> {
        Binding(
            get: { sharedManager.errorMessage != nil },
            set: { _ in sharedManager.errorMessage = nil }
        )
    }

    private var createSheet: some View {
        CreateSharedFridgeSheet(
            name: $newFridgeName,
            onCreate: { name in
                Task {
                    do {
                        let (share, root) = try await sharedManager.createSharedFridge(named: name)
                        activeSheet = .sharePending(share: share, root: root)
                        await sharedManager.reloadFridges()
                    } catch {
                        let message = (error as? CKError)?.friendlyMessage ?? error.localizedDescription
                        sharedManager.errorMessage = "Failed to create shared fridge: \(message)"
                    }
                }
            },
            onCancel: { activeSheet = nil }
        )
    }

    private func renameSheet(anchor: CKRecord, scope: SharedFridgeManager.ShareScope) -> some View {
        VStack(spacing: 20) {
            Text("Rename Frydge")
                .font(.headline)

            TextField("Enter name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .padding()

            HStack {
                Button("Cancel") { activeSheet = nil }
                Spacer()
                Button("Save") {
                    Task { await sharedManager.updateFridgeName(renameText, for: anchor, scope: scope) }
                    activeSheet = nil
                }
            }
            .padding(.horizontal)
        }
        .padding()
    }

    // MARK: - Row for Each Shared Fridge

    @ViewBuilder
    private func fridgeRow(anchor: CKRecord, scope: SharedFridgeManager.ShareScope) -> some View {
        let fid = anchor.recordID
        let title = sharedManager.namesByFridge[fid] ?? "Frydge – Fridge"
        let emoji = sharedManager.emojiByFridge[fid] ?? "🧊"
        let isExpanded = expandedIDs.contains(fid)
        let items = sharedManager.itemsByFridge[fid] ?? []

        VStack(alignment: .leading, spacing: 0) {
            // MARK: Header Row (matching SharedShoppingListView)
            HStack(spacing: 12) {

                // Left: Share/Manage button
                Button {
                            guard preparingManagementFridgeID == nil else { return }
                            // Tap title -> sharing/details (warm via correct DB + share cache)
                            Task {
                                preparingManagementFridgeID = fid
                                defer { preparingManagementFridgeID = nil }
                                do {
                                    let (share, freshAnchor) = try await sharedManager.warmManagement(for: anchor, scope: scope)
                                    activeSheet = .manageShare(share: share, root: freshAnchor, scope: scope)
                                } catch {
                                    // warmManagement throws its own distinct "No CKShare
                                    // found" error when a fridge genuinely hasn't been
                                    // shared yet — anything else (network blip, auth,
                                    // CloudKit hiccup on an already-shared fridge) is a
                                    // real failure and shouldn't be guessed away as
                                    // "needs sharing", which would wrongly reopen the
                                    // rename sheet on an owned fridge that's already shared.
                                    let nsError = error as NSError
                                    let noShareYet = nsError.domain == "SharedFridgeManager" && nsError.code == 1
                                    guard noShareYet else {
                                        print("Failed to warm management:", error)
                                        sharedManager.errorMessage = "Couldn't open sharing settings: \(error.localizedDescription)"
                                        return
                                    }

                                    do {
                                        let db = dbFor(scope: scope)
                                        let freshAnchor = try await db.record(for: anchor.recordID)

                                        if scope == .incoming {
                                            sharedManager.errorMessage = "This shared frydge isn’t ready for management yet. Ask the owner to re-share it."
                                        } else {
                                            renameText = title
                                            activeSheet = .rename(anchor: freshAnchor, scope: scope, title: title)
                                        }
                                    } catch {
                                        print("Failed to warm management:", error)
                                        sharedManager.errorMessage = "Couldn't open sharing settings: \(error.localizedDescription)"
                                    }
                                }
                            }
                } label: {
                    HStack(spacing: 12) {
                        Text(emoji)
                            .font(.title2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.headline)
                                .lineLimit(1)
                                .foregroundColor(.primary)

                            Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if preparingManagementFridgeID == fid {
                            ProgressView()
                                .scaleEffect(0.7)
                        }

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(preparingManagementFridgeID != nil)

                // Vertical separator
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1, height: 22)
                    .padding(.trailing, 5)

                // Right: Expand/collapse chevron
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        toggleExpanded(for: anchor, scope: scope)
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

            // MARK: Expanded Content
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    
                    // Owner/Participant badge
                    HStack {
                        Text(scope == .owned ? "Owner" : "Participant")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(scope == .owned ? Color.blue.opacity(0.2) : Color.green.opacity(0.2))
                            )
                            .foregroundColor(scope == .owned ? .blue : .green)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 14)

                    HStack(spacing: 6) {
                        Image(systemName: "hand.draw")
                            .font(.caption)
                        Text(scope == .owned
                             ? "Add with ➕ at the top, or drag items here from Mine."
                             : "Drag an item onto Mine to take it into your fridge.")
                            .font(.caption)
                        Spacer()
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 2)

                    // Fill a shared frydge from a receipt in one go. The owner always
                    // can; participants only once the owner has approved it in
                    // Manage Sharing (and their share lets them edit).
                    if sharedManager.canScanReceipts(into: anchor) {
                        Button {
                            activeSheet = .receiptScan(anchor: anchor, scope: scope)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text.viewfinder")
                                Text("Scan a receipt into this frydge")
                                Spacer()
                            }
                            .font(.caption.weight(.medium))
                            .foregroundColor(.blue)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .accessibilityLabel("Scan a receipt into \(title)")
                    }

                    let items = sharedManager.itemsByFridge[anchor.recordID] ?? []

                    if items.isEmpty {
                        Text("No items yet.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    } else {
                        // IMPORTANT: stable identity stops SwiftUI duplicate rendering glitches.
                        // No SwipeToDeleteRow here — its swipe gesture fights scroll/drag;
                        // delete lives in the item's detail sheet (tap → trash).
                        ForEach(items, id: \.recordID) { rec in
                            sharedItemRow(rec, in: anchor, scope: scope)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                    }
                }
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contentShape(Rectangle())
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.blue.opacity(dropTargetedFridgeID == fid ? 0.12 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.blue, lineWidth: dropTargetedFridgeID == fid ? 2 : 0)
        )
        .padding(.vertical, 4)
        // Drop a food item straight onto this frydge to move it in. Per-row targets
        // are far more reliable than one big drop zone wrapping the scroll view.
        .dropDestination(for: DraggableFridgeItem.self) { dropped, _ in
            handleDropOntoSharedFridge(dropped, anchor: anchor, scope: scope)
        } isTargeted: { targeting in
            dropTargetedFridgeID = targeting ? fid : (dropTargetedFridgeID == fid ? nil : dropTargetedFridgeID)
        }
    }

    /// Moves dropped items into this shared frydge. Accepts items from "Mine"
    /// (delete the local copy) and from other shared frydges (remove from source),
    /// so food can be shared in every direction. Imports first and only removes the
    /// source on success, so a read-only share can't lose the item.
    private func handleDropOntoSharedFridge(
        _ dropped: [DraggableFridgeItem],
        anchor: CKRecord,
        scope: SharedFridgeManager.ShareScope
    ) -> Bool {
        let targetName = anchor.recordID.recordName
        // Ignore anything already living in this frydge.
        let incoming = dropped.filter { $0.fromSharedAnchorRecordName != targetName }
        guard !incoming.isEmpty else { return false }

        Task {
            let items = incoming.map { d in
                sharedManager.makeSharedFrydgeItem(
                    name: d.name,
                    quantity: d.quantity.isEmpty ? "1" : d.quantity,
                    unit: d.unit,
                    location: d.location,
                    dietaryTags: d.dietaryTags,
                    expirationDate: d.expirationDate,
                    lifecycle: d.lifecycle
                )
            }

            do {
                // One batched save + one reload for the whole drop — importItemsIntoSharedFrydge
                // already takes an array, so a multi-item drag no longer costs one
                // CKModifyRecordsOperation and one full reload per item.
                _ = try await sharedManager.importItemsIntoSharedFrydge(items, into: anchor, scope: scope)
                await sharedManager.loadItems(for: anchor, scope: scope)

                // Remove each from wherever it came from now that it's safely added.
                for d in incoming {
                    if let source = d.fromSharedAnchorRecordName, !source.isEmpty {
                        await sharedManager.removeSharedItemAnywhere(recordName: d.id)
                    } else if let uuid = UUID(uuidString: d.id),
                              let stored = frydgeManager.storedIngredients.first(where: { $0.id == uuid }) {
                        await frydgeManager.deleteItem(stored)
                    }
                }
            } catch {
                let label = incoming.count == 1 ? incoming[0].name : "\(incoming.count) items"
                sharedManager.errorMessage = "Couldn't move \(label): \(error.localizedDescription)"
            }
        }
        return true
    }

    private func toggleExpanded(for anchor: CKRecord, scope: SharedFridgeManager.ShareScope) {
        let id = anchor.recordID
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
            Task { await sharedManager.loadItems(for: anchor, scope: scope) }
        }
    }

    private func dbFor(scope: SharedFridgeManager.ShareScope) -> CKDatabase {
        switch scope {
        case .owned:
            return sharedManager.container.privateCloudDatabase
        case .incoming:
            return sharedManager.container.sharedCloudDatabase
        }
    }

    // MARK: - Shared Item Row (identical card + interactions to "Mine")

    /// Renders a shared item through the same `FridgeItemRow` as the personal
    /// fridge. Tap opens the shared `IngredientDetailSheet`; the usage slider,
    /// drag-to-Mine and delete all write to CloudKit via `SharedFridgeManager`.
    @ViewBuilder
    private func sharedItemRow(_ rec: CKRecord, in anchor: CKRecord, scope: SharedFridgeManager.ShareScope) -> some View {
        let display = StoredIngredient(fromSharedRecord: rec)

        FridgeItemRow(
            item: display,
            showAddToList: false,
            onTapDetail: {
                selectedSharedItem = SharedItemSelection(rec: rec, anchor: anchor, scope: scope)
            },
            onUsageChange: { newValue in
                Task {
                    await sharedManager.updateSharedItemUsage(
                        recordName: rec.recordID.recordName,
                        quantityUsed: newValue
                    )
                }
            },
            onAddToList: {}
        )
        // Long-press begins a drag (onto "Mine" or another frydge). No .contextMenu —
        // it would win the long-press and block dragging. Delete/edit is in the sheet.
        .draggable(
            DraggableFridgeItem(
                id: rec.recordID.recordName,
                name: display.name,
                quantity: display.quantity,
                unit: display.unit,
                location: display.location,
                dietaryTags: Array(display.dietaryTags),
                expirationDate: display.expirationDate,
                fromSharedAnchorRecordName: anchor.recordID.recordName,
                lifecycle: display.lifecycle.rawValue
            )
        )
    }

    /// Builds the shared-frydge edit actions for the detail sheet: location/expiry
    /// go through `updateSharedItem`, delete through `removeSharedItemAnywhere`.
    private func sharedActions(for sel: SharedItemSelection) -> IngredientEditActions {
        IngredientEditActions(
            setLocation: { newLocation in
                await sharedManager.updateSharedItem(
                    sel.rec, in: sel.anchor, scope: sel.scope,
                    newLocationRaw: newLocation, newExpirationDate: nil
                )
                if let updated = sharedManager.itemsByFridge[sel.anchor.recordID]?
                    .first(where: { $0.recordID == sel.rec.recordID }),
                   let d = updated["expirationDate"] as? Date {
                    return d
                }
                return (sel.rec["expirationDate"] as? Date) ?? Date()
            },
            setExpiration: { newDate in
                await sharedManager.updateSharedItem(
                    sel.rec, in: sel.anchor, scope: sel.scope,
                    newLocationRaw: nil, newExpirationDate: newDate
                )
            },
            delete: {
                await sharedManager.removeSharedItemAnywhere(recordName: sel.rec.recordID.recordName)
            }
        )
    }

}

// MARK: - Move-to-shared routing (destination picker)

extension Notification.Name {
    /// FridgeView listens for this after the user picks a destination anchor.
    static let didPickMoveToSharedFrydgeDestination = Notification.Name("DidPickMoveToSharedFrydgeDestination")
}

private struct MoveToSharedFrydgeSheet: View {
    let sharedFridgeManager: SharedFridgeManager

    let onCancel: () -> Void
    let onMove: (CKRecord) -> Void

    @Environment(\.dismiss) private var dismiss

    private var anchors: [CKRecord] { sharedFridgeManager.sharedFrydgeAnchors }

    var body: some View {
        NavigationStack {
            List {
                if anchors.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.2.fill")
                        Text("No shared frydges")
                            .font(.headline)
                        Text("Create or accept a shared frydge first.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(anchors, id: \.recordID) { anchor in
                        let id = anchor.recordID
                        let name = sharedFridgeManager.namesByFridge[id] ?? (anchor["name"] as? String ?? "Shared Frydge")
                        let emoji = sharedFridgeManager.emojisByFridge[id] ?? (anchor["emoji"] as? String ?? "🧊")

                        Button {
                            onMove(anchor)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Text(emoji)
                                Text(name)
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Move to Shared")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
            }
            .task {
                await sharedFridgeManager.refreshSharedFrydges()
            }
        }
    }
}

// MARK: - ForEach CKRecord Helper

private extension CKRecord {
    var _recordIDHashValue: Int { recordID.hash }
}
