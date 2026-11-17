//
//  InviteResponsesView.swift
//  FrydgeRecipes
//
//  Shows the owner who declined an invite to a shared frydge or list.
//
//  An invitee who hasn't accepted has no access to the owner's zone, so the
//  decline is written to the public database (see PendingInvites) and read back
//  here by share. Only the invitee can delete their own record, so the owner
//  "dismisses" a decline locally.
//

import SwiftUI
import CloudKit

struct InviteResponse: Identifiable {
    var id: String { recordName }
    let recordName: String
    let shareRecordID: String
    let responderUserID: String
    let response: String // "declined"
    let timestamp: Date
    let rootRecordName: String?
}

/// Declines for one share, as a List section (renders nothing when there are none).
struct InviteResponsesView: View {
    let share: CKShare
    let rootRecord: CKRecord
    let container: CKContainer

    @State private var responses: [InviteResponse] = []

    private static let dismissedKey = "dismissedInviteResponses"

    private var visibleDeclines: [InviteResponse] {
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        // Someone who declined and later accepted is a member now, not a decline.
        let acceptedUsers = Set(
            share.participants
                .filter { $0.acceptanceStatus == .accepted }
                .compactMap { $0.userIdentity.userRecordID?.recordName }
        )
        return responses.filter {
            $0.response == "declined"
                && !dismissed.contains($0.recordName)
                && !acceptedUsers.contains($0.responderUserID)
        }
    }

    var body: some View {
        Group {
            if !visibleDeclines.isEmpty {
                Section {
                    ForEach(visibleDeclines) { response in
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.xmark")
                                .font(.title2)
                                .foregroundColor(.red)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Invitation declined")
                                    .font(.body)
                                Text(response.timestamp.formatted(.relative(presentation: .named)))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Button("Dismiss") { dismiss(response) }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text("Declined")
                } footer: {
                    Text("Someone you invited chose not to join. Use Invite People to send a fresh invitation.")
                }
            }
        }
        .task { await loadResponses() }
    }

    private func dismiss(_ response: InviteResponse) {
        var dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        dismissed.insert(response.recordName)
        UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedKey)
        responses.removeAll { $0.recordName == response.recordName }
    }

    private func loadResponses() async {
        let query = CKQuery(
            recordType: "InviteResponse",
            predicate: NSPredicate(format: "shareRecordID == %@", share.recordID.recordName)
        )

        do {
            let (matches, _) = try await container.publicCloudDatabase.records(matching: query)
            var loaded: [InviteResponse] = []
            for (_, result) in matches {
                guard case .success(let record) = result,
                      let shareRecordID = record["shareRecordID"] as? String,
                      let responderUserID = record["responderUserID"] as? String,
                      let response = record["response"] as? String,
                      let timestamp = record["timestamp"] as? Date else { continue }
                loaded.append(InviteResponse(
                    recordName: record.recordID.recordName,
                    shareRecordID: shareRecordID,
                    responderUserID: responderUserID,
                    response: response,
                    timestamp: timestamp,
                    rootRecordName: record["rootRecordName"] as? String
                ))
            }
            responses = loaded.sorted { $0.timestamp > $1.timestamp }
        } catch {
            // Declines are informational; a failed lookup just shows none.
            print("[INVITE_RESPONSES] Failed to load responses: \(error)")
        }
    }
}
