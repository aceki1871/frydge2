//
//  CloudSharingWrapperView.swift
//  FrydgeRecipes
//
//  Wraps CloudSharingView and adds invite response tracking
//

import SwiftUI
import CloudKit

struct CloudSharingWrapperView: View {
    let container: CKContainer
    let share: CKShare
    let rootRecord: CKRecord
    let initialTitle: String?
    let logoImageName: String?
    let defaultTitle: String
    let rootNameKey: String
    let rootEmojiKey: String
    let shareKind: String?
    let rootDatabase: CKDatabase?
    let isOwner: Bool
    
    let onShareSaved: ((CKShare, CKRecord) -> Void)?
    let onStopSharing: ((CKShare, CKRecord) -> Void)?
    let onShareSaveFailed: ((Error) -> Void)?
    let onDeleted: ((CKShare, CKRecord) -> Void)?
    let onLeftShare: ((CKShare, CKRecord) -> Void)?
    let allowDelete: Bool
    let allowLeaveForParticipants: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // ✅ Show invite responses section ONLY for owners
            if isOwner {
                InviteResponsesView(
                    share: share,
                    rootRecord: rootRecord,
                    container: container
                )
                
                Divider()
            }
            
            // ✅ System CloudKit sharing UI
            CloudSharingView(
                container: container,
                share: share,
                rootRecord: rootRecord,
                initialTitle: initialTitle,
                logoImageName: logoImageName,
                defaultTitle: defaultTitle,
                rootNameKey: rootNameKey,
                rootEmojiKey: rootEmojiKey,
                shareKind: shareKind,
                rootDatabase: rootDatabase,
                isOwnerOverride: isOwner,
                onShareSaved: onShareSaved,
                onStopSharing: onStopSharing,
                onShareSaveFailed: onShareSaveFailed,
                onDeleted: onDeleted,
                onLeftShare: onLeftShare,
                allowDelete: allowDelete,
                allowLeaveForParticipants: allowLeaveForParticipants
            )
        }
    }
}
