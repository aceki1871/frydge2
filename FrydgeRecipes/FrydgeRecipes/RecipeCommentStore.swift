//
//  RecipeCommentStore.swift
//  FrydgeRecipes
//
//  Comments on a recipe, visible to every Frydge user. Lives in the public
//  CloudKit database next to the recipes themselves, one `RecipeComment`
//  record per comment. Shown as a drop-down under a recipe card in the
//  recipe *list* (long-press a card), deliberately not on the detail page.
//
//  NOTE: before shipping, mark `recipeID` and `createdAt` as queryable (and
//  `createdAt` sortable) for the RecipeComment record type in the CloudKit
//  Dashboard schema — the client-side query below requires those indexes.
//

import Foundation
import CloudKit
import SwiftUI

// MARK: - Model

struct RecipeComment: Identifiable, Hashable {
    static let recordType = "RecipeComment"

    let id: CKRecord.ID
    let recipeID: String
    let authorID: String
    let authorName: String
    let text: String
    let createdAt: Date

    init?(record: CKRecord) {
        guard let recipeID = record["recipeID"] as? String,
              let text = record["text"] as? String else { return nil }
        self.id = record.recordID
        self.recipeID = recipeID
        self.authorID = record["authorID"] as? String ?? ""
        self.authorName = (record["authorName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.text = text
        self.createdAt = record["createdAt"] as? Date ?? record.creationDate ?? Date()
    }

    var displayAuthor: String { authorName.isEmpty ? "A Frydge cook" : authorName }
}

// MARK: - Store

@MainActor
final class RecipeCommentStore: ObservableObject {
    static let shared = RecipeCommentStore()

    private let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
    private var database: CKDatabase { container.publicCloudDatabase }

    /// Comments per recipe id, newest first. Published so every open
    /// drop-down for the same recipe updates together.
    @Published private(set) var commentsByRecipe: [String: [RecipeComment]] = [:]
    @Published private(set) var loadingRecipeIDs: Set<String> = []

    private init() {}

    func comments(for recipeID: String) -> [RecipeComment] { commentsByRecipe[recipeID] ?? [] }
    func isLoading(_ recipeID: String) -> Bool { loadingRecipeIDs.contains(recipeID) }

    /// Fetches once per recipe per launch unless `force` is set.
    func load(recipeID: String, force: Bool = false) async {
        if !force, commentsByRecipe[recipeID] != nil { return }
        guard !loadingRecipeIDs.contains(recipeID) else { return }
        loadingRecipeIDs.insert(recipeID)
        defer { loadingRecipeIDs.remove(recipeID) }

        let query = CKQuery(recordType: RecipeComment.recordType,
                            predicate: NSPredicate(format: "recipeID == %@", recipeID))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            let (results, _) = try await database.records(matching: query, resultsLimit: 50)
            let fetched = results.compactMap { _, result -> RecipeComment? in
                if case .success(let record) = result { return RecipeComment(record: record) }
                return nil
            }
            commentsByRecipe[recipeID] = fetched
        } catch {
            print("[RecipeCommentStore] fetch failed: \(error.localizedDescription)")
            if commentsByRecipe[recipeID] == nil { commentsByRecipe[recipeID] = [] }
        }
    }

    /// Posts a comment as the current user and prepends it locally.
    func post(_ text: String, recipeID: String) async throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        let record = CKRecord(recordType: RecipeComment.recordType)
        record["recipeID"] = recipeID as CKRecordValue
        record["text"] = String(clean.prefix(500)) as CKRecordValue
        record["authorID"] = await currentUserID() as CKRecordValue
        record["authorName"] = RecipeAuthor.currentName as CKRecordValue
        record["createdAt"] = Date() as CKRecordValue

        let saved = try await database.save(record)
        if let comment = RecipeComment(record: saved) {
            commentsByRecipe[recipeID, default: []].insert(comment, at: 0)
        }
    }

    /// Deletes one of the current user's own comments.
    func delete(_ comment: RecipeComment) async {
        let me = await currentUserID()
        guard comment.authorID == me else { return }
        do {
            try await database.deleteRecord(withID: comment.id)
            commentsByRecipe[comment.recipeID]?.removeAll { $0.id == comment.id }
        } catch {
            print("[RecipeCommentStore] delete failed: \(error.localizedDescription)")
        }
    }

    func isMine(_ comment: RecipeComment) -> Bool {
        guard let me = UserDefaults.standard.string(forKey: "appleUserID"), !me.isEmpty else { return false }
        return comment.authorID == me
    }

    private func currentUserID() async -> String {
        if let cached = UserDefaults.standard.string(forKey: "appleUserID"), !cached.isEmpty {
            return cached
        }
        if let rid = try? await container.userRecordID() {
            UserDefaults.standard.set(rid.recordName, forKey: "appleUserID")
            return rid.recordName
        }
        return "unknown"
    }
}

// MARK: - Drop-down view

/// "Comments (3) ▾" header that expands into the thread plus a composer.
/// Sits under the long-press action bar on a recipe card in the list.
struct RecipeCommentsDropdown: View {
    let recipeID: String

    @ObservedObject private var store = RecipeCommentStore.shared
    @State private var isOpen = false
    @State private var draft = ""
    @State private var isPosting = false
    @State private var errorText: String?
    @FocusState private var composerFocused: Bool

    private var comments: [RecipeComment] { store.comments(for: recipeID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isOpen.toggle() }
                if isOpen { Task { await store.load(recipeID: recipeID) } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.subheadline.weight(.semibold))
                    Text(headerTitle)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if store.isLoading(recipeID) {
                        ProgressView().tint(.white).scaleEffect(0.8)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headerTitle)
            .accessibilityHint(isOpen ? "Collapses comments" : "Shows comments")

            if isOpen {
                VStack(alignment: .leading, spacing: 10) {
                    if comments.isEmpty && !store.isLoading(recipeID) {
                        Text("No comments yet — be the first to say how it turned out.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                    } else {
                        ForEach(comments.prefix(8)) { comment in
                            commentRow(comment)
                        }
                        if comments.count > 8 {
                            Text("+ \(comments.count - 8) more")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }

                    composer

                    if let errorText {
                        Text(errorText)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .task { if store.commentsByRecipe[recipeID] == nil { await store.load(recipeID: recipeID) } }
    }

    private var headerTitle: String {
        let n = comments.count
        if store.commentsByRecipe[recipeID] == nil { return "Comments" }
        return n == 0 ? "Comments" : "Comments (\(n))"
    }

    private func commentRow(_ comment: RecipeComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(initials(comment.displayAuthor))
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.blue.opacity(0.8)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(comment.displayAuthor)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(comment.createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    Text("ago")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text(comment.text)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)

            if store.isMine(comment) {
                Button {
                    Task { await store.delete(comment) }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete my comment")
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Add a comment…", text: $draft, axis: .vertical)
                .lineLimit(1...3)
                .font(.caption)
                .foregroundStyle(.white)
                .tint(.white)
                .focused($composerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                Task { await send() }
            } label: {
                if isPosting {
                    ProgressView().tint(.white)
                        .frame(width: 34, height: 34)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.blue))
                }
            }
            .buttonStyle(.plain)
            .disabled(isPosting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Post comment")
        }
    }

    private func send() async {
        let text = draft
        isPosting = true
        errorText = nil
        defer { isPosting = false }
        do {
            try await store.post(text, recipeID: recipeID)
            draft = ""
            composerFocused = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            errorText = "Couldn't post — check you're signed in to iCloud."
        }
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2).compactMap { $0.first }
        let s = parts.map { String($0).uppercased() }.joined()
        return s.isEmpty ? "🙂" : s
    }
}
