//
//  RecipePickerSheet.swift
//  FrydgeRecipes
//
//  A lightweight recipe picker used to expand a recipe's ingredients into a shared
//  frydge or a shared shopping list. Reuses the shared RecipeListModel.
//

import SwiftUI

struct RecipePickerSheet: View {
    @ObservedObject var model: RecipeListModel
    var title: String = "Choose Recipe"
    var onPick: (CloudRecipe) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [CloudRecipe] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return model.recipes }
        return model.recipes.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.recipes.isEmpty {
                    ContentUnavailableView {
                        Label("No recipes yet", systemImage: "book.closed")
                    } description: {
                        Text("Add or sync recipes first, then you can add them here.")
                    } actions: {
                        Button("Close") { dismiss() }
                    }
                } else {
                    List {
                        ForEach(filtered, id: \.id) { recipe in
                            Button {
                                onPick(recipe)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    RecipeThumbnailView(
                                        recipeID: recipe.id,
                                        recipeName: recipe.name,
                                        imageSourceURL: recipe.imageSourceURL,
                                        size: 76
                                    )
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(recipe.name)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        Text("\(recipe.ingredients.count) ingredient\(recipe.ingredients.count == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        HealthScoreBadge(
                                            rating: RecipeHealthScore.rating(
                                                ingredients: recipe.ingredients,
                                                dietaryTags: recipe.dietaryTags
                                            )
                                        )
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $search, prompt: "Search recipes")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await model.fetchIfStale() }
        }
    }
}
