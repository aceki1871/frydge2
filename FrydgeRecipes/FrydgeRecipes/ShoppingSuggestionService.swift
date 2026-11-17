//
//  ShoppingSuggestionService.swift
//  FrydgeRecipes
//
//  Uses Apple's on-device Foundation Models (Apple Intelligence, iOS 26+) to
//  suggest grocery items based on the user's recipe library and fridge contents.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Public output type (not iOS-version-gated — safe to use everywhere)

struct ShoppingSuggestion: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let reason: String
}

// MARK: - Generable intermediate (iOS 26+ only)

@available(iOS 26.0, *)
@Generable(description: "Grocery shopping suggestions for a home cook")
private struct AISuggestions {
    @Guide(description: "Exactly 5 grocery items to suggest buying", .count(5))
    var items: [AIItem]

    @Generable
    struct AIItem {
        @Guide(description: "Generic grocery item name, e.g. 'Butter' or 'Free-range eggs' or 'Chicken thighs'")
        var name: String

        @Guide(description: "Short reason to buy it, max 7 words, e.g. 'Used in 4 of your recipes'")
        var reason: String
    }
}

// MARK: - Service

final class ShoppingSuggestionService {
    static let shared = ShoppingSuggestionService()
    private init() {}

    private let cacheKey = "shoppingSuggestionsCache"

    /// True when Apple Intelligence on-device model is ready and enabled.
    var isAvailable: Bool {
        FrydgeIntelligence.isAvailable
    }

    /// Cached suggestions from the last successful generation (available immediately, even offline).
    var cachedSuggestions: [ShoppingSuggestion] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let items = try? JSONDecoder().decode([[String]].self, from: data) else { return [] }
        return items.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return ShoppingSuggestion(name: pair[0], reason: pair[1])
        }
    }

    private func persistSuggestions(_ suggestions: [ShoppingSuggestion]) {
        let payload = suggestions.map { [$0.name, $0.reason] }
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    /// Returns cached suggestions immediately, then generates fresh ones in background if AI is available.
    /// The caller receives cached results instantly; new results are pushed via the returned async stream.
    func suggestions(
        recipes: [CloudRecipe],
        fridgeItems: [String],
        alreadyOnList: [String]
    ) async -> [ShoppingSuggestion] {
        let fresh = await generateWithAI(recipes: recipes, fridgeItems: fridgeItems, alreadyOnList: alreadyOnList)
        // UserDefaults writes can trigger observers (e.g. @AppStorage) that publish
        // view updates, so write on the main thread.
        if !fresh.isEmpty { await MainActor.run { persistSuggestions(fresh) } }
        return fresh.isEmpty ? cachedSuggestions : fresh
    }

    private func generateWithAI(
        recipes: [CloudRecipe],
        fridgeItems: [String],
        alreadyOnList: [String]
    ) async -> [ShoppingSuggestion] {
        guard FrydgeIntelligence.isAvailable else {
            print("[ShoppingSuggestionService] Apple Intelligence not available.")
            return []
        }

        // Build a compact prompt — the on-device model has a limited context window
        let recipeLines = recipes.prefix(15).map { r in
            let ing = r.ingredients.prefix(6).joined(separator: ", ")
            return "\(r.name): \(ing)"
        }.joined(separator: "\n")

        let fridge = fridgeItems.prefix(20).joined(separator: ", ")
        let listed  = alreadyOnList.prefix(20).joined(separator: ", ")

        let prompt = """
        Recipes:
        \(recipeLines.isEmpty ? "none" : recipeLines)

        In fridge: \(fridge.isEmpty ? "none" : fridge)
        Already on list: \(listed.isEmpty ? "none" : listed)

        Suggest 5 grocery items needed for these recipes that are NOT already in the fridge or on the list.
        """

        let session = LanguageModelSession(instructions: """
            You are a practical grocery assistant for a home cook.
            Suggest specific grocery items based on the user's recipe collection and what they already have.
            Prioritise ingredients that appear across multiple recipes.
            Avoid items already in the fridge or on the shopping list.
            Use short, generic item names (e.g. 'Garlic' not 'Fresh garlic bulbs').
            """)

        do {
            let response = try await session.respond(to: prompt, generating: AISuggestions.self)
            return response.content.items.map {
                ShoppingSuggestion(name: $0.name, reason: $0.reason)
            }
        } catch {
            print("[ShoppingSuggestionService] Generation error: \(error.localizedDescription)")
            return []
        }
    }
}
