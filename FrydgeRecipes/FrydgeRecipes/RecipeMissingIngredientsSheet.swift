//
//  RecipeMissingIngredientsSheet.swift
//  FrydgeRecipes
//
//  "Complete this recipe": shows what a recipe still needs against the
//  current fridge and pushes those lines to the shopping list in one tap.
//  Reached from the match % badge on the recipes list and from the
//  "Recipes using this" rows on an item's detail sheet.
//

import SwiftUI

extension ShoppingListManager {
    /// Adds the given recipe ingredient lines to the shopping list, skipping
    /// anything already on it. Quantities are parsed from the line; the
    /// manager rounds them up to purchasable pack sizes. Returns how many were added.
    @discardableResult
    func addMissingIngredients(_ lines: [String], dietaryTags: Set<String> = []) -> Int {
        var added = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parsed = RecipeIngredientParser.parse(line)
            let name = RecipeReadiness.cleanedName(parsed.name.isEmpty ? line : parsed.name)
            guard !isInShoppingList(name), !isInShoppingList(line) else { continue }
            addToShoppingList(
                name: name,
                quantity: parsed.quantity.isEmpty ? "1" : parsed.quantity,
                unit: parsed.unit,
                location: "Shopping",
                dietaryTags: dietaryTags
            )
            added += 1
        }
        return added
    }
}

struct RecipeMissingIngredientsSheet: View {
    let recipe: CloudRecipe

    @EnvironmentObject private var frydgeManager: FrydgeManager
    @EnvironmentObject private var shoppingListManager: ShoppingListManager
    @Environment(\.dismiss) private var dismiss

    @State private var didAdd = false
    @State private var substitutions: [IngredientSubstitution] = []

    private var match: RecipeMatch { frydgeManager.recipeMatch(for: recipe) }

    /// Missing lines not already on the shopping list.
    private var toAdd: [String] {
        match.missing.filter { line in
            let parsed = RecipeIngredientParser.parse(line)
            let name = RecipeReadiness.cleanedName(parsed.name.isEmpty ? line : parsed.name)
            return !shoppingListManager.isInShoppingList(name) && !shoppingListManager.isInShoppingList(line)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recipe.name)
                                .font(.headline)
                                .lineLimit(2)
                            Text("You have \(match.haveCount) of \(match.total) ingredients")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ZStack {
                            Circle()
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 5)
                            Circle()
                                .trim(from: 0, to: match.percent)
                                .stroke(barColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text(match.percentText)
                                .font(.caption2)
                                .fontWeight(.semibold)
                        }
                        .frame(width: 52, height: 52)
                        .accessibilityLabel("\(match.percentText) match")
                    }
                    .padding(.vertical, 6)
                }

                if match.missing.isEmpty {
                    Section {
                        Label("You have everything for this recipe", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    Section("Still needed") {
                        ForEach(Array(match.missing.enumerated()), id: \.offset) { _, line in
                            let onList = !toAdd.contains(line)
                            HStack(spacing: 10) {
                                Image(systemName: onList ? "cart.fill" : "circle")
                                    .foregroundStyle(onList ? Color.blue : Color.secondary)
                                    .font(.subheadline)
                                Text(line)
                                    .font(.body)
                                Spacer()
                                if onList {
                                    Text("On list")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !substitutions.isEmpty {
                        Section {
                            ForEach(substitutions) { swap in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(.purple)
                                        .font(.subheadline)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Use \(swap.use) instead of \(swap.missing)")
                                            .font(.subheadline.weight(.medium))
                                        Text(swap.note)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text("You could use instead")
                        }
                    }
                }
            }
            .navigationTitle("Complete this recipe")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: match.missing) {
                substitutions = await RecipeSubstitutionAI.suggest(
                    missingLines: match.missing,
                    fridgeItemNames: frydgeManager.matchableFridgeItems.map(\.name)
                )
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !toAdd.isEmpty {
                    Button {
                        let count = shoppingListManager.addMissingIngredients(toAdd, dietaryTags: normalizedTags)
                        guard count > 0 else { return }
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        withAnimation { didAdd = true }
                    } label: {
                        Label("Add \(toAdd.count) to Shopping List", systemImage: "cart.badge.plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                } else if didAdd || !match.missing.isEmpty {
                    Label("Everything missing is on your shopping list", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.vertical, 12)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var barColor: Color {
        match.percent >= 0.9 ? .green : match.percent >= 0.5 ? .blue : .red
    }

    /// Recipe-level dietary tags carried onto the shopping items.
    private var normalizedTags: Set<String> {
        let wanted: Set<String> = ["DF", "GF", "V", "VG"]
        let mapped = recipe.dietaryTags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .map { t -> String in
                switch t {
                case "DAIRY FREE": return "DF"
                case "GLUTEN FREE": return "GF"
                case "VEGETARIAN": return "V"
                case "VEGAN": return "VG"
                default: return t
                }
            }
            .filter { wanted.contains($0) }
        return Set(mapped)
    }
}
