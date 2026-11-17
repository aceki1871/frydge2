//
//  UseItUpAI.swift
//  FrydgeRecipes
//
//  Uses Apple's on-device Foundation Models to turn fridge items that are
//  about to expire into a couple of quick meal ideas. Results are cached by
//  day and item set so reopening the Fridge tab doesn't re-generate on every
//  appearance — the same approach ShoppingSuggestionService uses.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Public output type

struct UseItUpIdea: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
}

/// A short meal idea expanded into something a home cook can actually follow.
struct UseItUpRecipe: Equatable {
    let ingredients: [String]
    let steps: [String]
}

// MARK: - Generable intermediate

@available(iOS 26.0, *)
@Generable(description: "Quick meal ideas built around fridge items that are about to expire")
private struct AIUseItUpIdeas {
    @Guide(description: "Up to 3 quick meal ideas", .count(0...3))
    var ideas: [AIIdea]

    @Generable
    struct AIIdea {
        @Guide(description: "A short dish name, e.g. 'Spinach and feta omelette'")
        var title: String

        @Guide(description: "One line on how to use it, max 12 words")
        var detail: String
    }
}

@available(iOS 26.0, *)
@Generable(description: "A full quick recipe expanding a short meal idea")
private struct AIUseItUpRecipe {
    @Guide(description: "Ingredient lines with approximate amounts, e.g. '2 eggs', 'A handful of spinach'", .count(2...6))
    var ingredients: [String]

    @Guide(description: "Short, practical cooking steps a home cook can follow", .count(2...6))
    var steps: [String]
}

// MARK: - Service

enum UseItUpAI {
    private static let cacheKeyKey = "useItUpCache.key"
    private static let cachePayloadKey = "useItUpCache.payload"

    // MARK: - Personalization

    /// Same keys ProfileView and the recipe favouriting code already write to —
    /// read directly rather than threading a dependency through, since this is
    /// a plain service enum with no view context.
    private static let profileDietaryKey = "frydge.profileDietary"
    private static let favoriteRecipeIDsKey = "favoriteRecipeIDs"

    private static func dietaryPreferenceText() -> String? {
        let labels: [String: String] = [
            "GF": "gluten-free", "DF": "dairy-free", "V": "vegetarian", "VG": "vegan"
        ]
        let csv = UserDefaults.standard.string(forKey: profileDietaryKey) ?? ""
        let tags = csv.split(separator: ",").compactMap { labels[String($0)] }
        guard !tags.isEmpty else { return nil }
        return tags.joined(separator: ", ")
    }

    private static func favoriteRecipeNames(limit: Int = 5) -> [String] {
        let csv = UserDefaults.standard.string(forKey: favoriteRecipeIDsKey) ?? ""
        let ids = Set(csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !ids.isEmpty else { return [] }
        let recipes = CachedRecipeLibrary.shared.load()
        return Array(recipes.filter { ids.contains($0.id) }.prefix(limit).map { $0.name })
    }

    /// Folds whatever we actually know about this person — diet, taste from
    /// favourited recipes — into a couple of prompt lines, so ideas read as
    /// theirs instead of a generic "use up some cheese" filler suggestion.
    private static func personalizationBlock() -> String {
        var lines: [String] = []
        if let diet = dietaryPreferenceText() {
            lines.append("This person's diet: \(diet). Only suggest ideas that fit this.")
        }
        let favorites = favoriteRecipeNames()
        if !favorites.isEmpty {
            lines.append("Recipes they've favourited before (reference for flavour/style, don't just repeat one): \(favorites.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    /// In-memory only, keyed by idea (title+detail): the ideas themselves are
    /// re-rolled daily, so a recipe for one is worthless after that — no point
    /// persisting it past this app session. Lock-protected because `recipe`
    /// resumes off the main actor after awaiting the model.
    private static var recipeCache: [String: UseItUpRecipe] = [:]
    private static let recipeCacheLock = NSLock()

    /// Returns 0–3 quick meal ideas for the given expiring-soon fridge item
    /// names, using a same-day cache so repeat calls with the same inputs
    /// don't re-hit the model.
    static func ideas(forExpiringItems items: [String]) async -> [UseItUpIdea] {
        guard !items.isEmpty else { return [] }
        let personalization = personalizationBlock()
        let key = cacheKey(for: items, personalization: personalization)

        if UserDefaults.standard.string(forKey: cacheKeyKey) == key,
           let cached = cachedIdeas() {
            return cached
        }

        guard let result = await FrydgeIntelligence.generate(
            AIUseItUpIdeas.self,
            instructions: """
                You suggest quick meal ideas for a home cook using fridge items that are about to expire.
                Prioritise using as many of the given items together as makes sense.
                Keep each idea short and practical for a weeknight.
                Avoid generic filler like plain toast with a single spread — only suggest something that basic if it's genuinely the best use of what's expiring. These should feel like real ideas for this specific person, not a lazy catch-all.
                \(personalization)
                """,
            prompt: "Expiring soon:\n\(items.joined(separator: "\n"))",
            logTag: "UseItUpAI"
        ) else { return [] }

        let ideas = result.ideas.compactMap { idea -> UseItUpIdea? in
            let title = idea.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return UseItUpIdea(title: title, detail: idea.detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        persist(ideas, key: key)
        return ideas
    }

    /// Expands a short idea (title + one-line hint) into a full ingredients +
    /// steps recipe. Cached per idea for the rest of this app session so
    /// reopening the same idea's sheet is instant instead of re-rolling the
    /// model every time.
    static func recipe(forTitle title: String, detail: String) async -> UseItUpRecipe? {
        let personalization = personalizationBlock()
        let key = recipeCacheKey(title: title, detail: detail, personalization: personalization)
        if let cached = recipeCacheLock.withLock({ recipeCache[key] }) { return cached }

        guard let result = await FrydgeIntelligence.generate(
            AIUseItUpRecipe.self,
            instructions: """
                You are a chef turning a short meal idea into a full quick recipe for a home cook.
                Keep it realistic for a weeknight: simple ingredients, short practical steps.
                \(personalization)
                """,
            prompt: "Dish: \(title)\nIdea: \(detail)",
            logTag: "UseItUpAI.recipe"
        ) else { return nil }

        let ingredients = result.ingredients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let steps = result.steps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !ingredients.isEmpty, !steps.isEmpty else { return nil }

        let recipe = UseItUpRecipe(ingredients: ingredients, steps: steps)
        recipeCacheLock.withLock { recipeCache[key] = recipe }
        return recipe
    }

    private static func recipeCacheKey(title: String, detail: String, personalization: String) -> String {
        title.lowercased() + "|" + detail.lowercased() + "|" + personalization
    }

    private static func cacheKey(for items: [String], personalization: String) -> String {
        let day = DateFormatter.useItUpCacheDay.string(from: Date())
        return day + "|" + items.sorted().joined(separator: ",") + "|" + personalization
    }

    private static func cachedIdeas() -> [UseItUpIdea]? {
        guard let data = UserDefaults.standard.data(forKey: cachePayloadKey),
              let pairs = try? JSONDecoder().decode([[String]].self, from: data) else { return nil }
        return pairs.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return UseItUpIdea(title: pair[0], detail: pair[1])
        }
    }

    private static func persist(_ ideas: [UseItUpIdea], key: String) {
        let payload = ideas.map { [$0.title, $0.detail] }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: cachePayloadKey)
        UserDefaults.standard.set(key, forKey: cacheKeyKey)
    }
}

private extension DateFormatter {
    static let useItUpCacheDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
