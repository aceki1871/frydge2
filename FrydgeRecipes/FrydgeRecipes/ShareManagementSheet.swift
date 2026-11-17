//
//  ShareManagementSheet.swift
//  FrydgeRecipes
//
//  Created by Josh on 13/08/2026.
//
//  Native SwiftUI management sheet for shared frydges and shared shopping
//  lists. Replaces the raw UICloudSharingController for the *manage* flow:
//  shows the member list with roles/permissions, lets owners rename, change
//  permissions, remove people, stop sharing or delete, and lets participants
//  leave. The system sharing controller is still used for inviting people
//  (that's the only supported way to add participants to a private share).
//

import SwiftUI
import CloudKit
import UIKit

// MARK: - Kind

/// Which kind of shared thing the sheet manages. Controls wording, the default
/// emoji and the `frydgeKind` marker written onto the share.
enum SharedManagementKind {
    case fridge
    case shoppingList

    var noun: String {
        switch self {
        case .fridge: return "frydge"
        case .shoppingList: return "shopping list"
        }
    }

    var defaultEmoji: String {
        switch self {
        case .fridge: return "🧊"
        case .shoppingList: return "🛒"
        }
    }

    var defaultTitle: String {
        switch self {
        case .fridge: return "Frydge – Fridge"
        case .shoppingList: return "Frydge – Shopping List"
        }
    }

    /// Value stored on the CKShare as `frydgeKind`, matching the rest of the app.
    var shareKindValue: String {
        switch self {
        case .fridge: return "fridge"
        case .shoppingList: return "shoppingList"
        }
    }
}

// MARK: - Model

@MainActor
final class ShareManagementModel: ObservableObject {

    let container: CKContainer
    let database: CKDatabase
    let kind: SharedManagementKind

    private(set) var rootRecord: CKRecord
    @Published private(set) var share: CKShare

    @Published var participants: [CKShare.Participant] = []
    @Published var name: String
    @Published var emoji: String
    @Published var isBusy = false
    @Published var errorMessage: String?
    /// Owner's approval for participants to scan receipts into this frydge.
    @Published private(set) var allowMemberReceiptScan: Bool

    init(
        container: CKContainer,
        database: CKDatabase,
        kind: SharedManagementKind,
        share: CKShare,
        rootRecord: CKRecord,
        initialName: String? = nil
    ) {
        self.container = container
        self.database = database
        self.kind = kind
        self.share = share
        self.rootRecord = rootRecord

        let shareTitle = (share[CKShare.SystemFieldKey.title] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rootName = (rootRecord["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = [shareTitle, initialName, rootName]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? kind.defaultTitle

        let rootEmoji = (rootRecord["emoji"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.emoji = (rootEmoji?.isEmpty == false) ? String(rootEmoji!.prefix(1)) : kind.defaultEmoji

        self.participants = Self.sortedParticipants(of: share)
        self.allowMemberReceiptScan =
            ((rootRecord[SharedFridgeManager.memberReceiptScanKey] as? Int64) ?? 0) == 1
    }

    // MARK: Ownership / identity

    var isOwner: Bool {
        if let role = share.currentUserParticipant?.role {
            return role == .owner
        }
        return rootRecord.recordID.zoneID.ownerName == CKCurrentUserDefaultName
    }

    func isCurrentUser(_ p: CKShare.Participant) -> Bool {
        guard let me = share.currentUserParticipant else { return false }
        if p === me { return true }
        if let a = p.userIdentity.userRecordID, let b = me.userIdentity.userRecordID {
            return a == b
        }
        return false
    }

    static func displayName(for p: CKShare.Participant) -> String {
        if let comps = p.userIdentity.nameComponents {
            let formatted = comps.formatted()
            if !formatted.isEmpty { return formatted }
        }
        if let email = p.userIdentity.lookupInfo?.emailAddress, !email.isEmpty {
            return email
        }
        if let phone = p.userIdentity.lookupInfo?.phoneNumber, !phone.isEmpty {
            return phone
        }
        return "Unknown member"
    }

    static func initials(for p: CKShare.Participant) -> String {
        let name = displayName(for: p)
        // Emails/phones don't split into meaningful initials — use the first character.
        if name.contains("@") || name.first?.isNumber == true {
            return String(name.prefix(1)).uppercased()
        }
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    private static func sortedParticipants(of share: CKShare) -> [CKShare.Participant] {
        share.participants.sorted { a, b in
            if (a.role == .owner) != (b.role == .owner) { return a.role == .owner }
            if (a.acceptanceStatus == .accepted) != (b.acceptanceStatus == .accepted) {
                return a.acceptanceStatus == .accepted
            }
            return displayName(for: a).localizedCaseInsensitiveCompare(displayName(for: b)) == .orderedAscending
        }
    }

    // MARK: Refresh

    /// Refetches the share so the member list reflects invites accepted or
    /// added since the sheet was warmed. Name/emoji edits in flight are kept.
    func refresh() async {
        do {
            if let fresh = try await database.record(for: share.recordID) as? CKShare {
                share = fresh
                participants = Self.sortedParticipants(of: fresh)
            }
        } catch {
            // Stale data keeps showing; every mutation refetches on its own.
        }
    }

    // MARK: Mutations (owner)

    func saveNameAndEmoji() async -> Bool {
        guard isOwner else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmedName.isEmpty ? kind.defaultTitle : trimmedName
        let finalEmoji = trimmedEmoji.isEmpty ? kind.defaultEmoji : String(trimmedEmoji.prefix(1))

        share[CKShare.SystemFieldKey.title] = finalTitle as CKRecordValue
        share["frydgeKind"] = kind.shareKindValue as CKRecordValue
        rootRecord["name"] = finalTitle as CKRecordValue
        rootRecord["emoji"] = finalEmoji as CKRecordValue

        let ok = await save(records: [rootRecord, share], policy: .changedKeys)
        if ok {
            name = finalTitle
            emoji = finalEmoji
        }
        return ok
    }

    /// Approves or revokes participants scanning receipts into this frydge. Stored
    /// on the anchor so every member's app can read it; reverts if the save fails.
    func setAllowMemberReceiptScan(_ allowed: Bool) async {
        guard isOwner, kind == .fridge else { return }
        let previous = allowMemberReceiptScan
        allowMemberReceiptScan = allowed
        rootRecord[SharedFridgeManager.memberReceiptScanKey] = (allowed ? 1 : 0) as CKRecordValue
        let saved = await save(records: [rootRecord], policy: .changedKeys)
        if !saved {
            allowMemberReceiptScan = previous
            rootRecord[SharedFridgeManager.memberReceiptScanKey] = (previous ? 1 : 0) as CKRecordValue
        }
    }

    func setPermission(_ permission: CKShare.ParticipantPermission, for participant: CKShare.Participant) async {
        guard isOwner, participant.role != .owner else { return }
        participant.permission = permission
        _ = await save(records: [share], policy: .ifServerRecordUnchanged)
        await refresh()
    }

    func removeParticipant(_ participant: CKShare.Participant) async {
        guard isOwner, participant.role != .owner else { return }
        share.removeParticipant(participant)
        _ = await save(records: [share], policy: .ifServerRecordUnchanged)
        await refresh()
    }

    /// Removes every other participant but keeps the CKShare: everyone loses access
    /// and the owner's data stays put. Deleting the share record instead would drop
    /// the frydge out of the owner's own list (the app only lists anchors that have
    /// a share), stranding its items, and would leave no way to re-invite.
    func stopSharing() async -> Bool {
        guard isOwner else { return false }
        for participant in share.participants where participant.role != .owner {
            share.removeParticipant(participant)
        }
        let ok = await save(records: [share], policy: .ifServerRecordUnchanged)
        if ok { await refresh() }
        return ok
    }

    /// Deletes the share AND the root record — the shared thing disappears for
    /// everyone, owner included. A frydge's items are separate records, so they go too.
    func deleteForEveryone() async -> Bool {
        guard isOwner else { return false }
        var ids: [CKRecord.ID] = []
        if kind == .fridge {
            let rootRef = CKRecord.Reference(recordID: rootRecord.recordID, action: .none)
            let query = CKQuery(
                recordType: "StoredIngredient",
                predicate: NSPredicate(format: "fridge == %@", rootRef)
            )
            let items = (try? await database.allRecords(matching: query, inZoneWith: rootRecord.recordID.zoneID)) ?? []
            ids.append(contentsOf: items.map(\.recordID))
        }
        ids.append(contentsOf: [rootRecord.recordID, share.recordID])

        // Chunked under CloudKit's per-request limit; the root and share go last so
        // a failure part-way leaves a frydge that can still be retried.
        for start in stride(from: 0, to: ids.count, by: 300) {
            let chunk = Array(ids[start..<min(start + 300, ids.count)])
            guard await delete(recordIDs: chunk) else { return false }
        }
        return true
    }

    // MARK: Mutations (participant)

    /// Participants leave by deleting this share from their shared DB. The owner
    /// keeps every fridge/list in one zone, so deleting the zone (the old approach)
    /// would also drop the participant from the owner's other shares. The zone is
    /// only a fallback if CloudKit refuses the share deletion. Gone-already errors
    /// count as success.
    func leave() async -> Bool {
        guard !isOwner else { return false }
        isBusy = true
        defer { isBusy = false }

        let sharedDB = container.sharedCloudDatabase
        do {
            _ = try await sharedDB.modifyRecords(
                saving: [], deleting: [share.recordID], savePolicy: .ifServerRecordUnchanged, atomically: true
            )
            return true
        } catch {
            if let ck = error as? CKError, ck.code == .zoneNotFound || ck.code == .unknownItem {
                return true
            }
        }

        let zid = rootRecord.recordID.zoneID
        let zoneID = (zid.ownerName != CKCurrentUserDefaultName) ? zid : share.recordID.zoneID

        do {
            _ = try await sharedDB.modifyRecordZones(saving: [], deleting: [zoneID])
            return true
        } catch {
            if let ck = error as? CKError, ck.code == .zoneNotFound || ck.code == .unknownItem {
                return true
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: CloudKit plumbing

    private func save(records: [CKRecord], policy: CKModifyRecordsOperation.RecordSavePolicy) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            let (saveResults, _) = try await database.modifyRecords(
                saving: records, deleting: [], savePolicy: policy, atomically: true
            )
            for (_, result) in saveResults {
                if case .failure(let err) = result {
                    errorMessage = err.localizedDescription
                    return false
                }
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func delete(recordIDs: [CKRecord.ID]) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await database.modifyRecords(
                saving: [], deleting: recordIDs, savePolicy: .ifServerRecordUnchanged, atomically: true
            )
            return true
        } catch {
            if let ck = error as? CKError, ck.code == .unknownItem || ck.code == .zoneNotFound {
                return true
            }
            errorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - Sheet

struct ShareManagementSheet: View {

    @StateObject private var model: ShareManagementModel
    @Environment(\.dismiss) private var dismiss

    private let onChanged: () -> Void
    private let onDeleted: () -> Void
    private let onLeft: () -> Void
    private let onStoppedSharing: () -> Void

    @State private var isEditingDetails = false
    @State private var showInviteSheet = false
    @State private var confirmStopSharing = false
    @State private var confirmDelete = false
    @State private var confirmLeave = false
    @State private var participantPendingRemoval: CKShare.Participant?
    @State private var justCopiedLink = false

    init(
        container: CKContainer,
        database: CKDatabase,
        kind: SharedManagementKind,
        share: CKShare,
        rootRecord: CKRecord,
        initialName: String? = nil,
        onChanged: @escaping () -> Void = {},
        onDeleted: @escaping () -> Void = {},
        onLeft: @escaping () -> Void = {},
        onStoppedSharing: @escaping () -> Void = {}
    ) {
        _model = StateObject(wrappedValue: ShareManagementModel(
            container: container,
            database: database,
            kind: kind,
            share: share,
            rootRecord: rootRecord,
            initialName: initialName
        ))
        self.onChanged = onChanged
        self.onDeleted = onDeleted
        self.onLeft = onLeft
        self.onStoppedSharing = onStoppedSharing
    }

    var body: some View {
        NavigationStack {
            List {
                headerSection
                peopleSection
                if model.isOwner {
                    InviteResponsesView(
                        share: model.share,
                        rootRecord: model.rootRecord,
                        container: model.container
                    )
                }
                if model.isOwner && model.kind == .fridge {
                    receiptSection
                }
                inviteSection
                dangerSection
            }
            .navigationTitle("Manage Sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await model.refresh() }
        .sheet(isPresented: $showInviteSheet) {
            CloudSharingView(
                container: model.container,
                share: model.share,
                rootRecord: model.rootRecord,
                initialTitle: model.name,
                defaultTitle: model.kind.defaultTitle,
                shareKind: model.kind.shareKindValue,
                rootDatabase: model.database,
                allowDelete: false,
                allowLeaveForParticipants: false
            )
            .onDisappear {
                Task {
                    await model.refresh()
                    onChanged()
                }
            }
        }
        .alert("Sharing Error", isPresented: showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            "Remove access?",
            isPresented: removalDialogBinding,
            titleVisibility: .visible,
            presenting: participantPendingRemoval
        ) { participant in
            Button("Remove \(ShareManagementModel.displayName(for: participant))", role: .destructive) {
                Task {
                    await model.removeParticipant(participant)
                    onChanged()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { participant in
            Text("\(ShareManagementModel.displayName(for: participant)) will no longer see this \(model.kind.noun).")
        }
        .confirmationDialog(
            "Stop sharing?",
            isPresented: $confirmStopSharing,
            titleVisibility: .visible
        ) {
            Button("Stop Sharing", role: .destructive) {
                Task {
                    if await model.stopSharing() {
                        onStoppedSharing()
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone loses access, but your \(model.kind.noun) and its items stay on your account.")
        }
        .confirmationDialog(
            "Delete for everyone?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete for Everyone", role: .destructive) {
                Task {
                    if await model.deleteForEveryone() {
                        onDeleted()
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the shared \(model.kind.noun) and its items for you and everyone it's shared with.")
        }
        .confirmationDialog(
            "Leave this \(model.kind.noun)?",
            isPresented: $confirmLeave,
            titleVisibility: .visible
        ) {
            Button("Leave", role: .destructive) {
                Task {
                    if await model.leave() {
                        onLeft()
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll lose access to this shared \(model.kind.noun). The owner can invite you again later.")
        }
    }

    // MARK: Header

    private var headerSection: some View {
        Section {
            if isEditingDetails {
                editableHeader
            } else {
                HStack(spacing: 14) {
                    Text(model.emoji)
                        .font(.system(size: 34))
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.blue.opacity(0.12)))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.name)
                            .font(.headline)
                            .lineLimit(2)
                        Text(memberSummary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if model.isOwner {
                        Button {
                            withAnimation { isEditingDetails = true }
                        } label: {
                            Image(systemName: "pencil.circle.fill")
                                .font(.title2)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Rename")
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var editableHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                TextField(model.kind.defaultEmoji, text: $model.emoji)
                    .multilineTextAlignment(.center)
                    .font(.title2)
                    .frame(width: 56)
                    .textFieldStyle(.roundedBorder)

                TextField("Name", text: $model.name)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
            }

            HStack {
                Button("Cancel") {
                    withAnimation { isEditingDetails = false }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    Task {
                        if await model.saveNameAndEmoji() {
                            withAnimation { isEditingDetails = false }
                            onChanged()
                        }
                    }
                } label: {
                    if model.isBusy {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }
        }
        .padding(.vertical, 6)
    }

    private var memberSummary: String {
        let accepted = model.participants.filter { $0.acceptanceStatus == .accepted }.count
        let pending = model.participants.filter { $0.acceptanceStatus == .pending }.count
        var parts = ["\(accepted) member\(accepted == 1 ? "" : "s")"]
        if pending > 0 { parts.append("\(pending) invited") }
        return parts.joined(separator: " · ")
    }

    // MARK: People

    private var peopleSection: some View {
        Section("People") {
            ForEach(model.participants, id: \.self) { participant in
                participantRow(participant)
            }
        }
    }

    @ViewBuilder
    private func participantRow(_ participant: CKShare.Participant) -> some View {
        let displayName = ShareManagementModel.displayName(for: participant)
        let isMe = model.isCurrentUser(participant)

        HStack(spacing: 12) {
            Text(ShareManagementModel.initials(for: participant))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(avatarColor(for: displayName)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(isMe ? "You" : displayName)
                        .font(.body)
                        .lineLimit(1)

                    if participant.role == .owner {
                        Text("Owner")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.blue.opacity(0.18)))
                            .foregroundColor(.blue)
                    }
                }

                Text(statusLine(for: participant))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if model.isOwner && participant.role != .owner {
                Menu {
                    Button {
                        Task {
                            await model.setPermission(.readWrite, for: participant)
                            onChanged()
                        }
                    } label: {
                        Label("Can edit", systemImage: participant.permission == .readWrite ? "checkmark" : "pencil")
                    }

                    Button {
                        Task {
                            await model.setPermission(.readOnly, for: participant)
                            onChanged()
                        }
                    } label: {
                        Label("View only", systemImage: participant.permission == .readOnly ? "checkmark" : "eye")
                    }

                    Divider()

                    Button(role: .destructive) {
                        participantPendingRemoval = participant
                    } label: {
                        Label("Remove Access", systemImage: "person.badge.minus")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .disabled(model.isBusy)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusLine(for participant: CKShare.Participant) -> String {
        if participant.role == .owner { return "Full access" }
        let access: String
        switch participant.permission {
        case .readWrite: access = "Can edit"
        case .readOnly: access = "View only"
        default: access = "No access"
        }
        switch participant.acceptanceStatus {
        case .pending: return "\(access) · Invited, hasn't joined yet"
        case .accepted: return access
        case .removed: return "Removed"
        default: return access
        }
    }

    private func avatarColor(for name: String) -> Color {
        let palette: [Color] = [.blue, .indigo, .teal, .orange, .pink, .purple, .green]
        var hash = 0
        for scalar in name.unicodeScalars { hash = (hash &* 31) &+ Int(scalar.value) }
        return palette[abs(hash) % palette.count]
    }

    // MARK: Receipt scanning approval

    private var receiptSection: some View {
        Section {
            Toggle(
                "Members can scan receipts",
                isOn: Binding(
                    get: { model.allowMemberReceiptScan },
                    set: { newValue in
                        Task {
                            await model.setAllowMemberReceiptScan(newValue)
                            onChanged()
                        }
                    }
                )
            )
            .disabled(model.isBusy)
        } footer: {
            Text("When on, people who can edit this frydge can scan a receipt straight into it. You can turn it off any time.")
        }
    }

    // MARK: Invite

    private var inviteSection: some View {
        Section("Invite") {
            Button {
                showInviteSheet = true
            } label: {
                Label("Invite People…", systemImage: "person.badge.plus")
            }
            .disabled(model.isBusy)

            if let url = model.share.url {
                Button {
                    UIPasteboard.general.url = url
                    justCopiedLink = true
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        justCopiedLink = false
                    }
                } label: {
                    Label(justCopiedLink ? "Link Copied!" : "Copy Invite Link",
                          systemImage: justCopiedLink ? "checkmark" : "link")
                }

                ShareLink(item: url) {
                    Label("Share Invite Link…", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    // MARK: Danger zone

    @ViewBuilder
    private var dangerSection: some View {
        if model.isOwner {
            Section {
                Button(role: .destructive) {
                    confirmStopSharing = true
                } label: {
                    Label("Stop Sharing", systemImage: "person.2.slash")
                }
                .disabled(model.isBusy)

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete for Everyone", systemImage: "trash")
                }
                .disabled(model.isBusy)
            } footer: {
                Text("Stop Sharing keeps your items but removes everyone's access. Delete removes the \(model.kind.noun) for everyone, including you.")
            }
        } else {
            Section {
                Button(role: .destructive) {
                    confirmLeave = true
                } label: {
                    Label("Leave This \(model.kind == .fridge ? "Frydge" : "List")", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(model.isBusy)
            } footer: {
                Text("You'll be removed from this shared \(model.kind.noun). Your own items aren't affected.")
            }
        }
    }

    // MARK: Bindings

    private var showingError: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var removalDialogBinding: Binding<Bool> {
        Binding(
            get: { participantPendingRemoval != nil },
            set: { if !$0 { participantPendingRemoval = nil } }
        )
    }
}
