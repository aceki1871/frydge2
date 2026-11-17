//
//  CloudSharingManager.swift
//  FrydgeRecipes
//
//  Created by Josh on 04/01/2026.
//

import CloudKit

@MainActor
final class CloudSharingManager {

    // MARK: - Types

    struct PreparedShareContext {
        let share: CKShare
        let root: CKRecord
        let database: CKDatabase
        let isOwner: Bool
    }

    enum ShareKind: String {
        case fridge
        case shoppingList
    }

    // MARK: - Public API

    func prepareShare(
        container: CKContainer,
        rootRecord: CKRecord,
        existingShare: CKShare?,
        rootNameKey: String,
        rootEmojiKey: String,
        defaultTitle: String,
        shareKind: ShareKind,
        rootDatabaseOverride: CKDatabase? = nil,
        // stable list UUID support (shopping lists)
        rootListUUIDKey: String = "listUUID"
    ) async throws -> PreparedShareContext {

        let isOwner = isOwnerContext(rootRecord: rootRecord, share: existingShare)

        let db = resolveDatabase(
            container: container,
            root: rootRecord,
            override: rootDatabaseOverride
        )

        // If there is no existing share and you're not owner, you can't create one.
        // Fail fast with a clear error.
        guard isOwner || existingShare != nil else {
            throw NSError(
                domain: "CloudSharingManager",
                code: -100,
                userInfo: [NSLocalizedDescriptionKey: "Only the owner can create a CloudKit share."]
            )
        }

        let share: CKShare = existingShare ?? CKShare(rootRecord: rootRecord)

        // ✅ PARTICIPANT SAFETY:
        // Never mutate share permissions/custom fields/title as a participant.
        // Also avoid saving records in shared DB from participant context here.
        if !isOwner {
            // We can still ensure the root has a stable listUUID locally if it's missing,
            // BUT do not save it here (participants may not have write access).
            // The UI should treat root fields as read-only for participants anyway.
            _ = rootEmojiKey
            _ = rootNameKey
            _ = defaultTitle
            _ = shareKind
            _ = rootListUUIDKey

            return PreparedShareContext(
                share: share,
                root: rootRecord,
                database: db,
                isOwner: false
            )
        }

        // ✅ OWNER PATH: normalize + persist
        try await normalizeShare(
            share: share,
            root: rootRecord,
            rootNameKey: rootNameKey,
            rootEmojiKey: rootEmojiKey,
            rootListUUIDKey: rootListUUIDKey,
            defaultTitle: defaultTitle,
            shareKind: shareKind
        )

        let (savedShare, savedRoot) = try await commitAndRefetch(
            share: share,
            root: rootRecord,
            database: db
        )

        return PreparedShareContext(
            share: savedShare,
            root: savedRoot,
            database: db,
            isOwner: true
        )
    }

    // MARK: - Share recreation (last participant removed)

    func recreateShareAfterStop(
        container: CKContainer,
        oldShare: CKShare,
        rootRecord: CKRecord,
        rootNameKey: String,
        defaultTitle: String,
        shareKind: ShareKind,
        rootDatabaseOverride: CKDatabase? = nil,
        rootListUUIDKey: String = "listUUID"
    ) async throws -> CKShare {

        let db = resolveDatabase(
            container: container,
            root: rootRecord,
            override: rootDatabaseOverride
        )

        // This should only be run by an owner.
        guard isOwnerContext(rootRecord: rootRecord, share: oldShare) else {
            throw NSError(
                domain: "CloudSharingManager",
                code: -101,
                userInfo: [NSLocalizedDescriptionKey: "Only the owner can recreate a share."]
            )
        }

        let newShare = CKShare(rootRecord: rootRecord)

        let title: String =
            (oldShare[CKShare.SystemFieldKey.title] as? String)
            ?? (rootRecord[rootNameKey] as? String)
            ?? defaultTitle

        newShare[CKShare.SystemFieldKey.title] = stripLeadingEmoji(title) as CKRecordValue

        if let thumb = oldShare[CKShare.SystemFieldKey.thumbnailImageData] as? Data {
            newShare[CKShare.SystemFieldKey.thumbnailImageData] = thumb as CKRecordValue
        }

        newShare.publicPermission = .none
        newShare["frydgeKind"] = shareKind.rawValue as CKRecordValue

        // Ensure root has stable list UUID (shopping lists)
        ensureListUUID(on: rootRecord, key: rootListUUIDKey)

        try await save(records: [rootRecord, newShare], to: db)

        return newShare
    }

    // MARK: - Ownership

    func isOwnerContext(rootRecord: CKRecord, share: CKShare?) -> Bool {
        if let role = share?.currentUserParticipant?.role {
            return role == .owner
        }
        return rootRecord.recordID.zoneID.ownerName == CKCurrentUserDefaultName
    }

    // MARK: - Private helpers

    private func resolveDatabase(
        container: CKContainer,
        root: CKRecord,
        override: CKDatabase?
    ) -> CKDatabase {
        if let override { return override }

        if root.recordID.zoneID.ownerName == CKCurrentUserDefaultName {
            return container.privateCloudDatabase
        } else {
            return container.sharedCloudDatabase
        }
    }

    private func normalizeShare(
        share: CKShare,
        root: CKRecord,
        rootNameKey: String,
        rootEmojiKey: String,
        rootListUUIDKey: String,
        defaultTitle: String,
        shareKind: ShareKind
    ) async throws {

        let existingTitle = share[CKShare.SystemFieldKey.title] as? String
        let rootTitle = root[rootNameKey] as? String

        let finalTitle = stripLeadingEmoji(existingTitle ?? rootTitle ?? defaultTitle)

        share[CKShare.SystemFieldKey.title] = finalTitle as CKRecordValue
        share.publicPermission = .none
        share["frydgeKind"] = shareKind.rawValue as CKRecordValue

        if root[rootNameKey] == nil {
            root[rootNameKey] = finalTitle as CKRecordValue
        }

        ensureListUUID(on: root, key: rootListUUIDKey)

        // The manager doesn’t force emoji; caller owns emoji storage.
        _ = rootEmojiKey
    }

    private func ensureListUUID(on root: CKRecord, key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }

        let existing = (root[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing, !existing.isEmpty, UUID(uuidString: existing) != nil {
            return
        }

        root[k] = UUID().uuidString as CKRecordValue
    }

    private func commitAndRefetch(
        share: CKShare,
        root: CKRecord,
        database: CKDatabase
    ) async throws -> (CKShare, CKRecord) {

        try await save(records: [root, share], to: database)

        let freshRoot = try await database.record(for: root.recordID)

        guard let shareRef = freshRoot.share else {
            throw NSError(domain: "CloudSharingManager", code: -1)
        }

        let freshShareRecord = try await database.record(for: shareRef.recordID)

        guard let freshShare = freshShareRecord as? CKShare else {
            throw NSError(domain: "CloudSharingManager", code: -2)
        }

        return (freshShare, freshRoot)
    }

    private func save(records: [CKRecord], to database: CKDatabase) async throws {
        let op = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
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
            database.add(op)
        }
    }

    private func stripLeadingEmoji(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first else { return trimmed }

        if first.properties.isEmoji || first.properties.isEmojiPresentation {
            return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}
