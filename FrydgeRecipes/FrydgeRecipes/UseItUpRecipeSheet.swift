//
//  UseItUpRecipeSheet.swift
//  FrydgeRecipes
//
//  Expands a short "Use it up" idea (title + one-line hint) into a full
//  quick recipe — ingredients and steps — generated on demand so the idea
//  card doesn't have to carry a full recipe up front.
//

import SwiftUI

struct UseItUpRecipeSheet: View {
    let idea: UseItUpIdea

    @Environment(\.dismiss) private var dismiss
    @State private var recipe: UseItUpRecipe?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Working out the recipe…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let recipe {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(idea.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ingredients")
                                    .font(.headline)
                                ForEach(recipe.ingredients, id: \.self) { ingredient in
                                    HStack(alignment: .top, spacing: 8) {
                                        Circle()
                                            .fill(Color.purple)
                                            .frame(width: 5, height: 5)
                                            .padding(.top, 7)
                                        Text(ingredient)
                                            .font(.subheadline)
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Steps")
                                    .font(.headline)
                                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text("\(index + 1)")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.purple)
                                            .frame(width: 20, alignment: .trailing)
                                        Text(step)
                                            .font(.subheadline)
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView {
                        Label("Couldn't generate this recipe", systemImage: "sparkles")
                    } description: {
                        Text("Apple Intelligence may be unavailable right now. Try again in a moment.")
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                }
            }
            .navigationTitle(idea.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        recipe = await UseItUpAI.recipe(forTitle: idea.title, detail: idea.detail)
        isLoading = false
    }
}
