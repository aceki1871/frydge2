//
//  PendingInvites.swift
//  FrydgeRecipes
//
//  Created by Josh on 30/10/2025.
//

import SwiftUI
import CloudKit

// MARK: - Notifications

extension Notification.Name {
    static let cloudShareMetadataReceived      = Notification.Name("CloudShareMetadataReceived")
    static let cloudShareAccepted              = Notification.Name("CloudShareAccepted")
    static let cloudShareAcceptedMetadata      = Notification.Name("CloudShareAcceptedMetadata")
    static let cloudShareAcceptFailed          = Notification.Name("CloudShareAcceptFailed")
    static let cloudShareDeclined              = Notification.Name("CloudShareDeclined")
}

// MARK: - MODEL

@MainActor
final class PendingInvites: ObservableObject {
    static let shared = PendingInvites()

    @Published var metas: [CKShare.Metadata] = []

    /// Share recordIDs currently being accepted (prevents accidental decline during accept).
    @Published private(set) var acceptingShareIDs: Set<CKRecord.ID> = []

    var hasPendingInvites: Bool { !metas.isEmpty }

    func isAccepting(_ meta: CKShare.Metadata) -> Bool {
        acceptingShareIDs.contains(meta.share.recordID)
    }

    /// Add a metadata object if it's not already in the list.
    func add(meta: CKShare.Metadata) {
        let newID = meta.share.recordID
        if metas.contains(where: { $0.share.recordID == newID }) {
            print("[INVITES] duplicate shareID, ignoring")
            return
        }

        metas.append(meta)
        print("[INVITES] added shareID \(newID.recordName) (count=\(metas.count))")

        NotificationCenter.default.post(
            name: .cloudShareMetadataReceived,
            object: nil,
            userInfo: [
                "shareRecordID": meta.share.recordID.recordName,
                "containerIdentifier": meta.containerIdentifier
            ]
        )
    }

    /// Accept a single invite and remove it from the list.
    func accept(_ meta: CKShare.Metadata, containerID: String) async throws {
        let shareID = meta.share.recordID
        
        print("[INVITES] 🔵 Starting accept for shareID=\(shareID.recordName)")
        
        if acceptingShareIDs.contains(shareID) {
            print("[INVITES] ⚠️ accept already in progress for shareID \(shareID.recordName)")
            return
        }

        acceptingShareIDs.insert(shareID)
        defer { acceptingShareIDs.remove(shareID) }

        do {
            // ✅ Step 1: Accept the share
            print("[INVITES] 📤 Sending CKAcceptSharesOperation for shareID=\(shareID.recordName)")

            // Transient network/service hiccups (CKErrorDomain code 3, zone busy, rate
            // limiting, ...) retry automatically instead of surfacing an error on the
            // first blip — a fresh CKAcceptSharesOperation is built per attempt since a
            // CKOperation can't be re-added once it's run.
            try await withCloudKitRetry {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let op = CKAcceptSharesOperation(shareMetadatas: [meta])
                    op.acceptSharesResultBlock = { result in
                        switch result {
                        case .success:
                            print("[INVITES] ✅ CKAcceptSharesOperation succeeded for shareID=\(shareID.recordName)")
                            cont.resume()
                        case .failure(let e):
                            print("[INVITES] ❌ CKAcceptSharesOperation failed for shareID=\(shareID.recordName): \(e)")
                            cont.resume(throwing: e)
                        }
                    }

                    let resolvedContainerID = meta.containerIdentifier.isEmpty ? containerID : meta.containerIdentifier
                    print("[INVITES] 🔄 Adding operation to container: \(resolvedContainerID)")
                    CKContainer(identifier: resolvedContainerID).add(op)
                }
            }

            // ✅ Step 2: Remove from pending list
            metas.removeAll { $0.share.recordID == meta.share.recordID }
            Task { await clearDeclineResponse(for: meta) }
            print("[INVITES] ✅ Removed from pending list. Remaining invites: \(metas.count)")

            // ✅ Step 3: Small delay to let CloudKit propagate the accepted share
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            print("[INVITES] ⏸️ Completed propagation delay")

            // ✅ Step 4: Broadcast acceptance events
            print("[INVITES] 📢 Broadcasting cloudShareAccepted notification")
            NotificationCenter.default.post(
                name: .cloudShareAccepted,
                object: nil,
                userInfo: [
                    "shareRecordID": meta.share.recordID.recordName,
                    "containerIdentifier": meta.containerIdentifier
                ]
            )

            print("[INVITES] 📢 Broadcasting cloudShareAcceptedMetadata notification")
            NotificationCenter.default.post(
                name: .cloudShareAcceptedMetadata,
                object: meta,
                userInfo: [
                    "shareRecordID": meta.share.recordID.recordName,
                    "containerIdentifier": meta.containerIdentifier
                ]
            )
            
            print("[INVITES] 🎉 Share acceptance complete for shareID=\(shareID.recordName)")
        } catch {
            print("[INVITES] ❌ accept error for shareID=\(shareID.recordName): \(error)")
            print("[INVITES] ❌ Error details: \(error.localizedDescription)")

            NotificationCenter.default.post(
                name: .cloudShareAcceptFailed,
                object: nil,
                userInfo: [
                    "shareRecordID": meta.share.recordID.recordName,
                    "containerIdentifier": meta.containerIdentifier,
                    "error": error
                ]
            )

            throw error
        }
    }

    /// Decline locally and optionally notify the owner.
    func decline(_ meta: CKShare.Metadata, notifyOwner: Bool = true) {
        let shareID = meta.share.recordID
        if acceptingShareIDs.contains(shareID) {
            print("[INVITES] decline ignored because accept is in progress for shareID \(shareID.recordName)")
            return
        }

        metas.removeAll { $0.share.recordID == shareID }
        print("[INVITES] declined shareID \(shareID.recordName) (remaining=\(metas.count))")

        NotificationCenter.default.post(
            name: .cloudShareDeclined,
            object: nil,
            userInfo: [
                "shareRecordID": meta.share.recordID.recordName,
                "containerIdentifier": meta.containerIdentifier
            ]
        )
        
        // ✅ Optionally notify the owner that this user declined
        if notifyOwner {
            Task {
                await recordDeclineResponse(for: meta)
            }
        }
    }
    
    static func inviteResponseRecordID(shareName: String, userName: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "InviteResponse_\(shareName)_\(userName)")
    }

    /// Removes this person's earlier decline once they accept, so the owner
    /// doesn't keep seeing someone who has since joined as "declined".
    private func clearDeclineResponse(for meta: CKShare.Metadata) async {
        let containerID = meta.containerIdentifier.isEmpty ? "iCloud.com.Clark-Online.Recipe" : meta.containerIdentifier
        let container = CKContainer(identifier: containerID)
        guard let me = try? await container.userRecordID() else { return }
        let id = Self.inviteResponseRecordID(shareName: meta.share.recordID.recordName, userName: me.recordName)
        _ = try? await container.publicCloudDatabase.deleteRecord(withID: id)
    }

    /// Record a decline response so the owner can see who declined
    private func recordDeclineResponse(for meta: CKShare.Metadata) async {
        let containerID = meta.containerIdentifier.isEmpty ? "iCloud.com.Clark-Online.Recipe" : meta.containerIdentifier
        let container = CKContainer(identifier: containerID)
        
        // Get current user's info
        guard let currentUserID = try? await container.userRecordID() else {
            print("[INVITES] ❌ Cannot get current user ID for decline notification")
            return
        }
        
        // An invitee who hasn't accepted yet has no access to the owner's zone, so
        // a record can't be written there (that is why declines never arrived).
        // The public database is the one place both sides can reach: the invitee
        // writes the response, and the owner queries it by share. The
        // deterministic recordID means a second decline overwrites instead of
        // piling up duplicates.
        let recordID = Self.inviteResponseRecordID(shareName: meta.share.recordID.recordName, userName: currentUserID.recordName)
        let responseRecord = CKRecord(recordType: "InviteResponse", recordID: recordID)
        responseRecord["shareRecordID"] = meta.share.recordID.recordName as NSString
        responseRecord["responderUserID"] = currentUserID.recordName as NSString
        responseRecord["response"] = "declined" as NSString
        responseRecord["timestamp"] = Date() as NSDate

        // Try to get the root record name/title for context
        if let rootRecordRef = meta.rootRecord {
            responseRecord["rootRecordID"] = rootRecordRef.recordID.recordName as NSString
            let recordName = (rootRecordRef["name"] as? String) ?? "Shared Item"
            responseRecord["rootRecordName"] = recordName as NSString
        }

        do {
            // .allKeys so a repeat decline from the same person replaces the old one.
            let op = CKModifyRecordsOperation(recordsToSave: [responseRecord], recordIDsToDelete: nil)
            op.savePolicy = .allKeys
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                op.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success: cont.resume()
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
                container.publicCloudDatabase.add(op)
            }
            print("[INVITES] ✅ Recorded decline response for shareID=\(meta.share.recordID.recordName)")
        } catch {
            print("[INVITES] ⚠️ Failed to record decline response: \(error)")
            // Don't fail the decline itself if recording fails
        }
    }
}

// MARK: - Invitations UI (still used; now typically presented from FrydgeRecipesApp root sheet)

struct InvitationsView: View {
    @EnvironmentObject var invites: PendingInvites
    @Environment(\.dismiss) private var dismiss

    let containerID: String = "iCloud.com.Clark-Online.Recipe"
    var onAccepted: () -> Void = {}

    var body: some View {
        // Deployment target is iOS 27, so the pre-iOS 16 NavigationView fallback is gone.
        NavigationStack {
            listContent
                .navigationTitle("Invitations")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        // Prevent swipe-dismiss while an accept is running (avoids weird “accepted but sheet disappeared mid-flight”).
        .interactiveDismissDisabled(!invites.acceptingShareIDs.isEmpty)
    }

    private var listContent: some View {
        ScrollView {
            if invites.metas.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "envelope.open")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundColor(.blue)

                    Text("No pending invites")
                        .font(.headline)

                    Text("When someone shares a Frydge with you, it will show up here.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(invites.metas, id: \.share.recordID) { meta in
                        InviteBannerCard(
                            meta: meta,
                            isBusy: invites.isAccepting(meta),
                            onAccept: {
                                print("[INVITES][UI] Accept tapped shareID=\(meta.share.recordID.recordName)")
                                Task {
                                    do {
                                        try await invites.accept(meta, containerID: containerID)
                                        onAccepted()
                                    } catch {
                                        print("[INVITES][UI] accept error: \(error)")
                                    }
                                }
                            },
                            onDecline: {
                                print("[INVITES][UI] Decline tapped shareID=\(meta.share.recordID.recordName)")
                                invites.decline(meta)
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }
}

// MARK: - Banner-style invite card

private struct InviteBannerCard: View {
    let meta: CKShare.Metadata
    let isBusy: Bool
    let onAccept: () -> Void
    let onDecline: () -> Void

    private var title: String { meta.displayShareTitle }

    private var iconText: String {
        let kind = (meta.share["frydgeKind"] as? String)?.lowercased() ?? ""
        let defaultEmoji: String = (kind == "shoppinglist") ? "🛒" : "🧊"

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first else {
            if kind.isEmpty {
                return title.lowercased().contains("shopping") ? "🛒" : "🧊"
            }
            return defaultEmoji
        }

        if first.properties.isEmojiPresentation || first.properties.isEmoji {
            return String(trimmed.prefix(1))
        }

        if kind.isEmpty {
            return title.lowercased().contains("shopping") ? "🛒" : "🧊"
        }

        return defaultEmoji
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(iconText)
                .font(.system(size: 26))
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("From \(meta.displaySenderName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isBusy {
                ProgressView()
                    .frame(width: 76, height: 36)
            } else {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button(action: onDecline) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.glass(.regular.tint(.red)))
                        .foregroundStyle(.red)
                        .accessibilityLabel("Decline")

                        Button(action: onAccept) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.glass(.regular.tint(.green)))
                        .foregroundStyle(.green)
                        .accessibilityLabel("Accept")
                    }
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Metadata helpers

extension CKShare.Metadata {
    var displaySenderName: String {
        if let comps = ownerIdentity.nameComponents {
            return comps.formatted()
        }
        return "Shared with you"
    }

    var displayShareTitle: String {
        if let rawTitle = share[CKShare.SystemFieldKey.title] as? String {
            let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        let raw = share.recordID.recordName
        if !raw.isEmpty { return raw }
        return "Shared item"
    }
}
