//
//  RecipeAuthor.swift
//  FrydgeRecipes
//
//  Identifies the current user as the author of newly-created recipes
//  and provides a small reusable byline footer view.
//

import SwiftUI
import CloudKit
import UIKit

enum RecipeAuthor {
    private static let kAuthorNameKey = "frydge.authorName"

    /// Best-effort current user name to stamp on new recipes.
    /// Reads from UserDefaults; falls back to `UIDevice.current.name`.
    /// Concurrent `refreshFromCloudKit()` updates the cached value asynchronously
    /// once CloudKit returns the user's record.
    static var currentName: String {
        if let cached = UserDefaults.standard.string(forKey: kAuthorNameKey),
           !cached.trimmingCharacters(in: .whitespaces).isEmpty {
            return cached
        }
        return UIDevice.current.name
    }

    /// Overwrite the cached author name (e.g. from a profile screen).
    static func setName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            UserDefaults.standard.removeObject(forKey: kAuthorNameKey)
            return
        }
        UserDefaults.standard.set(trimmed, forKey: kAuthorNameKey)
    }

    /// Pulls the iCloud user's record and caches "displayName" if present.
    /// Safe to call at app launch — failures are silent.
    static func refreshFromCloudKit() {
        let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        container.fetchUserRecordID { recordID, error in
            guard let recordID, error == nil else { return }
            container.publicCloudDatabase.fetch(withRecordID: recordID) { record, _ in
                if let name = record?["displayName"] as? String,
                   !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    setName(name)
                }
            }
        }
    }

    /// Builds a `CloudRecipe` from a `RecipeDraft` and saves it via the existing CloudKit pipeline.
    /// Stamps `authorName` from the cached current user.
    @MainActor
    static func saveDraftAsRecipe(_ draft: RecipeDraft) {
        // Derive cumulative cook time string for `serves` is N/A; keep serves blank if not collected by the flow.
        let recipe = CloudRecipe(
            name: draft.name.isEmpty ? "Untitled Recipe" : draft.name,
            serves: "1",
            ingredients: draft.ingredients,
            pan: "",
            instructions: draft.steps.map { $0.text }.joined(separator: "\n\n"),
            steps: draft.steps,
            image: draft.image,
            authorName: currentName
        )

        CloudRecipe.saveNewRecipe(recipe, image: draft.image) { result in
            switch result {
            case .success:
                print("[RECIPE] Saved new recipe '\(recipe.name)' by \(recipe.authorName ?? "?")")
            case .failure(let error):
                print("[RECIPE] Save failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Small reusable byline shown at the bottom of recipe detail views.
struct RecipeAuthorFooter: View {
    let authorName: String?
    let creationDate: Date?

    var body: some View {
        if let author = authorName?.trimmingCharacters(in: .whitespaces), !author.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "person.circle.fill")
                    .foregroundStyle(.secondary)
                Text("Recipe by \(Text(author).fontWeight(.semibold).foregroundStyle(.primary))")
                    .foregroundStyle(.secondary)
                if let date = creationDate {
                    Text(" · \(date.formatted(date: .abbreviated, time: .omitted))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 16)
        }
    }
}
