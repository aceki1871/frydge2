//
//  AllergenAdaptation.swift
//  FrydgeRecipes
//
//  Makes the user's "can't / won't eat" rules bite instantly in recipes:
//
//    • `RecipeAllergenCheck.evaluate(_:)` runs every recipe's name and
//      ingredient lines through DietaryRestrictionStore and says whether it
//      is unsafe (a can't-eat match), merely flagged (a prefer-not match) or
//      fine — purely local, synchronous, memoised by the caller.
//    • `AllergenSwaps.substitute(for:ingredient:)` suggests a replacement for
//      an offending line ("peanuts" → "toasted pepitas") so an unsafe recipe
//      can be adapted instead of just hidden.
//

import Foundation

// MARK: - Per-recipe verdict

struct RecipeAllergenVerdict: Equatable {
    /// Lines (original text) that match a can't-eat rule, with the rule term.
    var unsafe: [(line: String, term: String)] = []
    /// Lines that match a prefer-not rule, with the rule term.
    var flagged: [(line: String, term: String)] = []

    var isUnsafe: Bool { !unsafe.isEmpty }
    var isFlagged: Bool { !flagged.isEmpty }
    var isClean: Bool { unsafe.isEmpty && flagged.isEmpty }

    /// Distinct offending terms, blocking ones first.
    var terms: [String] {
        var seen = Set<String>()
        return (unsafe.map(\.term) + flagged.map(\.term)).filter { seen.insert($0).inserted }
    }

    /// "Contains peanuts" / "Contains peanuts, milk".
    var headline: String? {
        let list = terms.prefix(3).map { $0.localizedCapitalized }
        guard !list.isEmpty else { return nil }
        let extra = terms.count - list.count
        return "Contains " + list.joined(separator: ", ") + (extra > 0 ? " +\(extra)" : "")
    }

    static func == (lhs: RecipeAllergenVerdict, rhs: RecipeAllergenVerdict) -> Bool {
        lhs.unsafe.map(\.line) == rhs.unsafe.map(\.line)
            && lhs.unsafe.map(\.term) == rhs.unsafe.map(\.term)
            && lhs.flagged.map(\.line) == rhs.flagged.map(\.line)
            && lhs.flagged.map(\.term) == rhs.flagged.map(\.term)
    }
}

@MainActor
enum RecipeAllergenCheck {

    /// Cheap fingerprint of the current rules, so callers can memoise verdicts
    /// per recipe and only recompute when the rules (or profile tags) change.
    static func rulesFingerprint() -> String {
        let store = DietaryRestrictionStore.shared
        let rules = store.restrictions.map { "\($0.severity.rawValue):\($0.term.lowercased())" }.sorted().joined(separator: "|")
        let tags = UserDefaults.standard.string(forKey: DietaryRestrictionStore.profileTagsKey) ?? ""
        return rules + "#" + tags
    }

    static var hasAnyRules: Bool {
        let store = DietaryRestrictionStore.shared
        if !store.restrictions.isEmpty { return true }
        let tags = UserDefaults.standard.string(forKey: DietaryRestrictionStore.profileTagsKey) ?? ""
        return !tags.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Checks the recipe name and each ingredient line. A line is attributed
    /// to the first rule that matches it; the same rule can flag many lines.
    static func evaluate(_ recipe: CloudRecipe) -> RecipeAllergenVerdict {
        guard hasAnyRules else { return RecipeAllergenVerdict() }
        let store = DietaryRestrictionStore.shared
        var verdict = RecipeAllergenVerdict()

        // Whole recipe first (catches "Peanut Satay" even when lines say "satay sauce").
        for flag in store.flags(forName: recipe.name) where flag.evidence == .name {
            let entry = (line: recipe.name, term: flag.term)
            if flag.isBlocking { verdict.unsafe.append(entry) } else { verdict.flagged.append(entry) }
        }

        for line in recipe.ingredients {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Treat the line as a product name so the food-family matcher
            // ("cheddar" ↔ "cheese") applies, not just whole words.
            let flags = store.flags(forName: trimmed)
            guard let top = flags.first else { continue }
            let entry = (line: trimmed, term: top.term)
            if top.isBlocking {
                verdict.unsafe.append(entry)
            } else if !verdict.unsafe.contains(where: { $0.line == trimmed }) {
                verdict.flagged.append(entry)
            }
        }
        return verdict
    }
}

// MARK: - Swaps

enum AllergenSwaps {

    /// A replacement for `ingredient` given the rule `term` it tripped, or
    /// nil when there's no sensible one-line swap (the UI then says "leave it
    /// out"). Checks the more specific food first.
    static func substitute(for term: String, ingredient: String) -> String? {
        let t = term.lowercased()
        let s = ingredient.lowercased()

        func any(_ words: [String], in text: String) -> Bool { words.contains { text.contains($0) } }

        // Peanuts & tree nuts
        if any(["peanut"], in: t) || any(["peanut"], in: s) {
            if s.contains("butter") { return "sunflower seed butter or tahini (1:1)" }
            if s.contains("oil") { return "neutral oil such as rice bran or sunflower" }
            if s.contains("satay") || s.contains("sauce") { return "sunflower-seed satay (blend toasted sunflower seeds, soy, lime)" }
            return "toasted pepitas or sunflower seeds (same amount)"
        }
        if any(["nut", "almond", "cashew", "walnut", "pecan", "hazelnut", "pistachio", "macadamia", "brazil"], in: t)
            || any(["almond", "cashew", "walnut", "pecan", "hazelnut", "pistachio", "macadamia", "brazil nut", "pine nut"], in: s) {
            if s.contains("milk") { return "oat milk (1:1)" }
            if s.contains("flour") || s.contains("meal") { return "fine oat flour or sunflower seed meal (1:1)" }
            if s.contains("butter") { return "sunflower seed butter (1:1)" }
            if s.contains("pesto") { return "nut-free pesto made with pepitas" }
            return "toasted pepitas or sunflower seeds (same amount)"
        }

        // Dairy
        if any(["milk", "dairy", "lactose", "casein", "whey", "cheese", "butter", "cream", "yoghurt", "yogurt", "ghee"], in: t) {
            if s.contains("cream cheese") { return "dairy-free cream cheese" }
            if s.contains("sour cream") || s.contains("yoghurt") || s.contains("yogurt") { return "coconut yoghurt (1:1)" }
            if s.contains("cream") { return "coconut cream (1:1)" }
            if s.contains("cheese") || s.contains("parmesan") || s.contains("cheddar") || s.contains("mozzarella") || s.contains("feta") {
                return "dairy-free cheese, or nutritional yeast for flavour"
            }
            if s.contains("butter") || s.contains("ghee") { return "olive oil or dairy-free spread (¾ the amount)" }
            if s.contains("milk") { return "oat or soy milk (1:1)" }
            return "a dairy-free alternative (same amount)"
        }

        // Eggs
        if t.contains("egg") || (s.contains("egg") && !s.contains("eggplant")) {
            if s.contains("mayo") { return "egg-free mayonnaise (1:1)" }
            return "flax egg per egg (1 tbsp ground flaxseed + 3 tbsp water) or ¼ cup aquafaba"
        }

        // Gluten / wheat
        if any(["gluten", "wheat", "barley", "rye", "spelt", "semolina", "couscous", "bulgur", "malt"], in: t) {
            if s.contains("soy sauce") { return "tamari (1:1)" }
            if s.contains("flour") { return "gluten-free flour blend (1:1)" }
            if s.contains("breadcrumb") || s.contains("panko") { return "gluten-free breadcrumbs or crushed rice crackers" }
            if s.contains("bread") || s.contains("bun") || s.contains("wrap") || s.contains("tortilla") || s.contains("pita") {
                return "gluten-free bread / wraps"
            }
            if any(["pasta", "noodle", "spaghetti", "penne", "linguine", "fettuc"], in: s) { return "gluten-free pasta or rice noodles" }
            if s.contains("couscous") || s.contains("bulgur") { return "quinoa (same cooked amount)" }
            if s.contains("beer") { return "gluten-free beer or dry cider" }
            if s.contains("oat") { return "certified gluten-free oats" }
            if s.contains("barley") { return "brown rice or quinoa" }
            return "a certified gluten-free version"
        }

        // Soy
        if any(["soy", "soya", "tofu", "edamame"], in: t) {
            if s.contains("soy sauce") || s.contains("tamari") { return "coconut aminos (1:1, a touch more salt)" }
            if s.contains("tofu") || s.contains("tempeh") { return "chickpeas or cooked white beans (same weight)" }
            if s.contains("milk") { return "oat milk (1:1)" }
            if s.contains("miso") { return "chickpea miso" }
            return "a soy-free alternative"
        }

        // Fish & shellfish
        if any(["shellfish", "prawn", "shrimp", "crab", "lobster", "mussel", "oyster", "scallop", "clam", "crayfish", "squid"], in: t) {
            if s.contains("sauce") || s.contains("paste") { return "soy sauce with a squeeze of lime" }
            return "firm white fish, or chickpeas for a plant-based swap"
        }
        if any(["fish", "salmon", "tuna", "cod", "anchov", "sardine"], in: t) {
            if s.contains("fish sauce") { return "soy sauce + a squeeze of lime (1:1)" }
            if s.contains("anchov") { return "capers (1:1)" }
            if s.contains("worcestershire") { return "vegan Worcestershire sauce" }
            return "chicken thigh or firm tofu (same weight)"
        }

        // Sesame
        if t.contains("sesame") || t.contains("tahini") {
            if s.contains("tahini") { return "sunflower seed butter (1:1)" }
            if s.contains("oil") { return "toasted peanut-free nut-free oil such as rice bran, plus a pinch of pepitas for crunch" }
            return "toasted pepitas or hemp seeds"
        }

        // Sulphites
        if t.contains("sulphite") || t.contains("sulfite") {
            if s.contains("wine") { return "stock plus a splash of vinegar" }
            if s.contains("dried") { return "fresh fruit, or unsulphured dried fruit" }
            return "an unsulphured version"
        }

        // Celery, mustard, lupin
        if t.contains("celery") { return "fennel bulb or extra leek (same amount)" }
        if t.contains("mustard") { return "horseradish or a pinch of turmeric + vinegar" }
        if t.contains("lupin") { return "chickpea flour (1:1)" }

        // Meats (often "prefer not")
        if any(["pork", "bacon", "ham"], in: t) { return "turkey or beef equivalent (same weight)" }
        if t.contains("beef") { return "chicken thigh or lamb (same weight)" }
        if t.contains("chicken") { return "turkey or firm tofu (same weight)" }

        // Additives / preferences
        if t.contains("palm oil") { return "a palm-oil-free brand, or coconut oil" }
        if t.contains("msg") || t.contains("621") { return "a pinch of mushroom powder or nutritional yeast" }
        if t.contains("aspartame") || t.contains("sweetener") { return "a little honey or maple syrup" }
        if t.contains("sugar") { return "halve it, or use ripe banana / dates for sweetness" }
        if t.contains("alcohol") || t.contains("wine") || t.contains("beer") { return "stock plus a splash of vinegar or lemon" }
        if t.contains("caffeine") || t.contains("coffee") { return "decaf, or chicory for the flavour" }

        return nil
    }
}
