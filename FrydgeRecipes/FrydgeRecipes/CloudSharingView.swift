//
//  CloudSharingView.swift
//  FrydgeRecipes
//
//  Created by Josh on 10/10/2025.
//

import SwiftUI
import CloudKit
import UIKit
import PhotosUI

struct CloudSharingView: UIViewControllerRepresentable {

    typealias UIViewControllerType = UINavigationController

    let container: CKContainer
    let share: CKShare
    let rootRecord: CKRecord

    /// Initial title to show. If nil, uses share title or a fallback.
    var initialTitle: String? = nil

    /// Optional logo image name for the thumbnail (shown in Messages/Mail).
    var logoImageName: String? = "AppIcon"

    /// Fallback title if share title + initialTitle are nil/empty
    var defaultTitle: String = "Frydge – Fridge"

    /// Root record keys (if you persist these)
    var rootNameKey: String = "name"
    var rootEmojiKey: String = "emoji"

    /// Optional stable list UUID key on the ROOT record (ShareAnchor) for shopping lists.
    var rootListUUIDKey: String = "listUUID"

    /// Optional share kind marker so different share flows can be distinguished.
    /// Example values: "fridge", "shoppingList"
    /// Stored on the CKShare as `frydgeKind` (custom field) to match the rest of the app.
    var shareKind: String? = nil

    /// IMPORTANT: pass the same DB you used to create/save the root/share (private vs shared).
    /// If nil, we resolve it from the rootRecord zone owner.
    var rootDatabase: CKDatabase? = nil

    /// Optional explicit override if you already know ownership (e.g. from a prepared context).
    /// If provided, it is used as the source of truth.
    var isOwnerOverride: Bool? = nil

    var onShareSaved: ((CKShare, CKRecord) -> Void)? = nil
    var onStopSharing: ((CKShare, CKRecord) -> Void)? = nil
    var onShareSaveFailed: ((Error) -> Void)? = nil
    var onDeleted: ((CKShare, CKRecord) -> Void)? = nil
    var onLeftShare: ((CKShare, CKRecord) -> Void)? = nil

    var allowDelete: Bool = true
    var allowLeaveForParticipants: Bool = true

    // MARK: - Ownership helpers (robust)

    private func isOwnerContext() -> Bool {
        if let isOwnerOverride { return isOwnerOverride }

        if let role = share.currentUserParticipant?.role {
            return role == .owner
        }

        let owner = share.owner

        if let current = share.currentUserParticipant {
            if
                let cID = current.userIdentity.userRecordID,
                let oID = owner.userIdentity.userRecordID,
                cID == oID
            {
                return true
            }

            if
                let cLookup = current.userIdentity.lookupInfo,
                let oLookup = owner.userIdentity.lookupInfo,
                cLookup == oLookup
            {
                return true
            }
        }

        return rootRecord.recordID.zoneID.ownerName == CKCurrentUserDefaultName
    }

    private func resolvedDatabase() -> CKDatabase {
        if let rootDatabase { return rootDatabase }

        if rootRecord.recordID.zoneID.ownerName == CKCurrentUserDefaultName {
            return container.privateCloudDatabase
        } else {
            return container.sharedCloudDatabase
        }
    }

    private func applyShareKindIfNeeded(to share: CKShare) {
        guard let shareKind else { return }
        let trimmed = shareKind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        share["frydgeKind"] = trimmed as CKRecordValue
    }

    private func resolvedSharedZoneIDForLeave() -> CKRecordZone.ID {
        let zid = rootRecord.recordID.zoneID
        if zid.ownerName != CKCurrentUserDefaultName {
            return zid
        }
        return share.recordID.zoneID
    }

    // MARK: - Emoji + title helpers

    private func currentEmoji() -> String {
        let e = (rootRecord[rootEmojiKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let e, !e.isEmpty { return String(e.prefix(1)) }
        return "🛒"
    }

    private func currentTitle() -> String {
        if let t = (share[CKShare.SystemFieldKey.title] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !t.isEmpty {
            return t
        }

        if let t = initialTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !t.isEmpty {
            return t
        }

        return defaultTitle
    }

    private func combinedTitle(emoji: String? = nil, title: String? = nil) -> String {
        let e = (emoji?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : String($0.prefix(1)) } ?? currentEmoji()

        let t = (title?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? currentTitle()

        return "\(e) \(t)"
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {

        let parent: CloudSharingView
        weak var csc: UICloudSharingController?
        weak var nav: UINavigationController?

        private var pendingAlert: UIAlertController?
        private var isAttemptingPresent: Bool = false

        init(parent: CloudSharingView) {
            self.parent = parent
        }

        // MARK: - Safe presenting (prevents crash during sheet transitions)

        private func enqueuePresent(_ alert: UIAlertController, from csc: UICloudSharingController) {
            pendingAlert = alert
            attemptPresentIfPossible(from: csc)
        }

        private func attemptPresentIfPossible(from csc: UICloudSharingController) {
            guard !isAttemptingPresent else { return }
            isAttemptingPresent = true

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.isAttemptingPresent = false }

                guard let alert = self.pendingAlert else { return }

                guard csc.viewIfLoaded?.window != nil else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                        guard let self else { return }
                        self.isAttemptingPresent = false
                        self.attemptPresentIfPossible(from: csc)
                    }
                    return
                }

                guard csc.presentedViewController == nil else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                        guard let self else { return }
                        self.isAttemptingPresent = false
                        self.attemptPresentIfPossible(from: csc)
                    }
                    return
                }

                self.pendingAlert = nil
                csc.present(alert, animated: true)
            }
        }

        // MARK: - Save edits immediately (owner only)

        private func saveRootAndShareNowIfOwner() {
            guard parent.isOwnerContext() else { return }
            guard let share = csc?.share else { return }

            parent.applyShareKindIfNeeded(to: share)

            let db = parent.resolvedDatabase()
            let saveOp = CKModifyRecordsOperation(recordsToSave: [parent.rootRecord, share], recordIDsToDelete: nil)
            saveOp.savePolicy = .changedKeys
            saveOp.isAtomic = true
            saveOp.modifyRecordsResultBlock = { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self.parent.onShareSaved?(share, self.parent.rootRecord)
                    case .failure(let err):
                        self.parent.onShareSaveFailed?(err)
                    }
                }
            }
            db.add(saveOp)
        }

        // MARK: - UICloudSharingControllerDelegate

        func itemTitle(for csc: UICloudSharingController) -> String? {
            return parent.combinedTitle()
        }

        func itemThumbnailData(for csc: UICloudSharingController) -> Data? {
            // ✅ Return nil to hide the document icon completely
            // The system will show just the title/emoji without any thumbnail
            return nil
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            // CRASH FIX (same invariant as saveRootAndShareNowIfOwner): participants
            // must not mutate share permissions/custom fields or re-save the root record.
            guard parent.isOwnerContext() else { return }
            guard let share = csc.share else { return }

            parent.applyShareKindIfNeeded(to: share)

            let db = parent.resolvedDatabase()
            let rootToSave = parent.rootRecord

            let saveOp = CKModifyRecordsOperation(recordsToSave: [rootToSave, share], recordIDsToDelete: nil)
            saveOp.savePolicy = .changedKeys
            saveOp.isAtomic = true
            saveOp.modifyRecordsResultBlock = { _ in
                DispatchQueue.main.async {
                    self.parent.onShareSaved?(share, self.parent.rootRecord)
                }
            }
            db.add(saveOp)
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            parent.onShareSaveFailed?(error)
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            // ✅ "Stop Sharing" removes all participants but keeps the share record alive
            // This is different from "Delete" which permanently removes the share AND root record
            guard let share = csc.share else { return }
            
            // The share still exists, but all participants have been removed
            // We should NOT delete the share record here - just notify the callback
            parent.onStopSharing?(share, parent.rootRecord)
        }

        // MARK: - Actions

        @objc func doneTapped() {
            (nav ?? csc?.navigationController)?.dismiss(animated: true)
        }

        @objc func leaveTapped() {
            guard let csc else {
                (nav ?? csc?.navigationController)?.dismiss(animated: true)
                return
            }

            guard parent.isOwnerContext() == false else {
                (nav ?? csc.navigationController)?.dismiss(animated: true)
                return
            }

            let alert = UIAlertController(
                title: "Leave shared list?",
                message: "You will lose access to this shared shopping list.",
                preferredStyle: .actionSheet
            )

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in
                self?.performLeave()
            })

            if let pop = alert.popoverPresentationController {
                pop.sourceView = csc.view
                pop.sourceRect = CGRect(x: csc.view.bounds.midX, y: csc.view.bounds.maxY, width: 1, height: 1)
            }

            enqueuePresent(alert, from: csc)
        }

        @objc func renameTapped() {
            guard let csc else { return }
            guard parent.isOwnerContext() else {
                showParticipantInfo()
                return
            }

            let alert = UIAlertController(title: "Edit list", message: nil, preferredStyle: .alert)

            let currentTitleOnly: String =
                (csc.share?[CKShare.SystemFieldKey.title] as? String)
                ?? parent.initialTitle
                ?? parent.defaultTitle

            let currentEmoji: String = parent.currentEmoji()

            alert.addTextField {
                $0.text = currentEmoji
                $0.placeholder = "Emoji (e.g. 🛒)"
                $0.autocapitalizationType = .none
            }

            alert.addTextField {
                $0.text = currentTitleOnly
                $0.placeholder = "Name (e.g. Weekly shop)"
                $0.autocapitalizationType = .words
            }

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
            alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
                guard let self else { return }
                guard let csc = self.csc else { return }

                let emojiText = alert.textFields?.first?.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let titleText = alert.textFields?.dropFirst().first?.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let finalEmoji = emojiText.isEmpty ? "🛒" : String(emojiText.prefix(1))
                let finalTitle = titleText.isEmpty ? self.parent.defaultTitle : titleText

                // Share title (name only)
                csc.share?[CKShare.SystemFieldKey.title] = finalTitle as CKRecordValue
                if let share = csc.share {
                    self.parent.applyShareKindIfNeeded(to: share)
                }

                // Root fields (what SharedShoppingListView reads)
                self.parent.rootRecord[self.parent.rootNameKey] = finalTitle as CKRecordValue
                self.parent.rootRecord[self.parent.rootEmojiKey] = finalEmoji as CKRecordValue

                // Update UI immediately
                let combined = self.parent.combinedTitle(emoji: finalEmoji, title: finalTitle)
                csc.navigationItem.title = combined
                self.configureTitleView(for: csc, title: combined)

                // Persist now (so it shows everywhere without waiting for “Save Share” flows)
                self.saveRootAndShareNowIfOwner()
            })

            enqueuePresent(alert, from: csc)
        }

        @objc func participantTitleTapped() {
            showParticipantInfo()
        }

        private func showParticipantInfo() {
            guard let csc else { return }

            let title = parent.combinedTitle()

            let listUUID = (parent.rootRecord[parent.rootListUUIDKey] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let messageBase = "Only the owner can rename or delete this shared list."
            let message = (listUUID?.isEmpty == false)
                ? "\(messageBase)\n\nList ID: \(listUUID!)"
                : messageBase

            let alert = UIAlertController(
                title: title,
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))

            enqueuePresent(alert, from: csc)
        }

        @objc func deleteTapped() {
            guard parent.allowDelete else { return }
            guard parent.isOwnerContext() else { return }
            guard let csc else { return }

            let alert = UIAlertController(
                title: "Delete?",
                message: "This will permanently delete this shared item for everyone.",
                preferredStyle: .actionSheet
            )

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
                self?.performDelete()
            })

            if let pop = alert.popoverPresentationController {
                pop.sourceView = csc.view
                pop.sourceRect = CGRect(x: csc.view.bounds.midX, y: csc.view.bounds.maxY, width: 1, height: 1)
            }

            enqueuePresent(alert, from: csc)
        }

        private func performLeave() {
            let sharedDB = parent.container.sharedCloudDatabase

            func finishLeaving() {
                DispatchQueue.main.async {
                    self.parent.onLeftShare?(self.parent.share, self.parent.rootRecord)
                    (self.nav ?? self.csc?.navigationController)?.dismiss(animated: true)
                }
            }

            func leaveByDeletingZone() {
                let zoneID = parent.resolvedSharedZoneIDForLeave()
                let op = CKModifyRecordZonesOperation(recordZonesToSave: nil, recordZoneIDsToDelete: [zoneID])
                op.modifyRecordZonesResultBlock = { result in
                    switch result {
                    case .success:
                        finishLeaving()
                    case .failure(let error):
                        if let ck = error as? CKError,
                           ck.code == .zoneNotFound || ck.code == .unknownItem {
                            finishLeaving()
                            return
                        }
                        DispatchQueue.main.async { self.parent.onShareSaveFailed?(error) }
                    }
                }
                sharedDB.add(op)
            }

            // Each fridge/list is its own root-record share, but one owner keeps all
            // of theirs in a single zone. Deleting the zone would drop this person
            // from every share that owner has given them, so leave by deleting just
            // this share and only fall back to the zone if CloudKit refuses.
            let op = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: [parent.share.recordID])
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    finishLeaving()
                case .failure(let error):
                    if let ck = error as? CKError, ck.code == .unknownItem || ck.code == .zoneNotFound {
                        finishLeaving()
                    } else {
                        leaveByDeletingZone()
                    }
                }
            }
            sharedDB.add(op)
        }

        private func performDelete() {
            let db = parent.resolvedDatabase()

            let idsToDelete: [CKRecord.ID] = [
                parent.rootRecord.recordID,
                parent.share.recordID
            ]

            let op = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: idsToDelete)
            op.savePolicy = .ifServerRecordUnchanged
            op.isAtomic = true
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    DispatchQueue.main.async {
                        self.parent.onDeleted?(self.parent.share, self.parent.rootRecord)
                        (self.nav ?? self.csc?.navigationController)?.dismiss(animated: true)
                    }
                case .failure(let error):
                    DispatchQueue.main.async {
                        self.parent.onShareSaveFailed?(error)
                    }
                }
            }

            db.add(op)
        }

        // MARK: - Title view (tap behaviour)

        func configureTitleView(for csc: UICloudSharingController, title: String) {
            if parent.isOwnerContext() {
                let btn = UIButton(type: .system)
                btn.setTitle(title, for: .normal)
                btn.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
                btn.titleLabel?.lineBreakMode = .byTruncatingTail
                btn.contentHorizontalAlignment = .center
                btn.addTarget(self, action: #selector(renameTapped), for: .touchUpInside)
                csc.navigationItem.titleView = btn
                csc.navigationItem.title = nil
            } else {
                let btn = UIButton(type: .system)
                btn.setTitle(title, for: .normal)
                btn.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
                btn.titleLabel?.lineBreakMode = .byTruncatingTail
                btn.contentHorizontalAlignment = .center
                btn.addTarget(self, action: #selector(participantTitleTapped), for: .touchUpInside)
                
                DispatchQueue.main.async {
                    csc.navigationItem.titleView = btn
                    csc.navigationItem.title = nil
                }
                
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - UIViewControllerRepresentable

    func makeUIViewController(context: Context) -> UINavigationController {

        let displayTitle = combinedTitle()

        let csc = UICloudSharingController(share: share, container: container)
        csc.delegate = context.coordinator
        context.coordinator.csc = csc

        // CRASH FIX: participants must not mutate share permissions or custom fields on the share.
        if isOwnerContext() {
            csc.availablePermissions = [.allowReadWrite, .allowPrivate]
            share.publicPermission = .none
            applyShareKindIfNeeded(to: share)
        } else {
            csc.availablePermissions = []
            // DO NOT set share.publicPermission here.
            // DO NOT write custom fields to share here.
        }

        // ✅ Let the system provide its own Done button (the checkmark)
        // We'll just add our custom buttons alongside it
        
        if isOwnerContext() {
            // ✅ Pencil icon for editing (owner only)
            let edit = UIBarButtonItem(
                image: UIImage(systemName: "pencil"),
                style: .plain,
                target: context.coordinator,
                action: #selector(Coordinator.renameTapped)
            )
            edit.tintColor = .systemBlue
            csc.navigationItem.rightBarButtonItem = edit
        } else if allowLeaveForParticipants {
            // ✅ Leave button for participants
            let leave = UIBarButtonItem(
                title: "Leave",
                style: .plain,
                target: context.coordinator,
                action: #selector(Coordinator.leaveTapped)
            )
            leave.tintColor = .systemRed
            csc.navigationItem.leftBarButtonItem = leave
        }

        context.coordinator.configureTitleView(for: csc, title: displayTitle)

        // Bottom toolbar
        if isOwnerContext() && allowDelete {
            let delete = UIBarButtonItem(
                title: "Delete",
                style: .plain,
                target: context.coordinator,
                action: #selector(Coordinator.deleteTapped)
            )
            delete.tintColor = .systemRed

            csc.toolbarItems = [
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                delete,
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
            ]
        } else if allowLeaveForParticipants, !isOwnerContext() {
            let leave = UIBarButtonItem(
                title: "Leave",
                style: .plain,
                target: context.coordinator,
                action: #selector(Coordinator.leaveTapped)
            )
            leave.tintColor = .systemRed

            csc.toolbarItems = [
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                leave,
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
            ]
        } else {
            csc.toolbarItems = nil
        }

        let nav = UINavigationController(rootViewController: csc)
        context.coordinator.nav = nav

        nav.navigationBar.prefersLargeTitles = false
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .systemBackground
        nav.navigationBar.standardAppearance = appearance
        nav.navigationBar.scrollEdgeAppearance = appearance

        nav.setToolbarHidden(false, animated: false)

        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        // no-op
    }

    // MARK: - Helpers

    private func resolvedThumbnailPNGData() -> Data? {
        if let name = logoImageName, let img = UIImage(named: name) {
            return img.pngData()
        }
        return nil
    }
}
