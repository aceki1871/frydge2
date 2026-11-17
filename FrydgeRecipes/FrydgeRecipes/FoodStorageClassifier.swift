//
//  FoodStorageClassifier.swift
//  FrydgeRecipes
//
//  Decides where a product should be stored (Fridge / Freezer / Pantry) from its
//  name, and computes a realistic best-before date that accounts for both the food
//  and its storage location. Centralises logic that used to be duplicated across
//  StoredIngredient.defaultExpiry and the two normalizeStorageLocation copies.
//

import Foundation

enum FoodStorageClassifier {

    /// Canonical storage locations used throughout the app.
    static let fridge = "Fridge"
    static let freezer = "Freezer"
    static let pantry = "Pantry"

    // MARK: - Location suggestion

    /// Best-guess storage location for a product name.
    /// Order: explicitly-frozen items → shelf-stable pantry items → default Fridge.
    static func suggestedLocation(for name: String) -> String {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if freezerKeywords.contains(where: { lower.contains($0) }) { return freezer }
        if isShelfStable(lower) { return pantry }
        return fridge
    }

    /// Maps any raw/legacy location string onto the canonical set.
    /// Accepts historical values like "Dry" (→ Pantry) and "Cupboard".
    static func normalize(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.contains("freez") { return freezer }
        if t.contains("frid") || t.contains("chill") { return fridge }
        if t.contains("pantry") || t.contains("dry") || t.contains("cupboard") || t.contains("shelf") {
            return pantry
        }
        // Unknown labels (e.g. "Store", "Suggestion") fall back to Pantry, matching
        // the previous normalizeStorageLocation default of "Dry".
        return pantry
    }

    // MARK: - Best-before dates

    /// A realistic best-before date combining the food's shelf life with its
    /// storage location. Freezing extends most perishables dramatically; the
    /// pantry only extends genuinely shelf-stable goods.
    static func bestBefore(for name: String, location: String, from: Date = Date()) -> Date {
        let base = baseShelfLifeDays(for: name)
        let loc = normalize(location)
        let days: Int
        switch loc {
        case freezer:
            // Freezing multiplies shelf life; clamp to a sane 3-month..1-year band.
            days = min(365, max(base * 10, 90))
        case pantry:
            // Only stretch things that are actually shelf-stable; a perishable that
            // the user parks in the pantry keeps its short life.
            days = isShelfStable(name.lowercased()) ? max(base, 180) : base
        default: // Fridge
            days = base
        }
        return Calendar.current.date(byAdding: .day, value: days, to: from) ?? from
    }

    /// Re-derives a best-before date when an item's location changes, without
    /// surprise-shortening a freezer date someone already relied on. Shared by
    /// `FrydgeManager` and `SharedFridgeManager` so Mine and Shared frydges
    /// can't silently diverge on this rule.
    static func adjustedExpiryDate(currentExpiry: Date, name: String, forLocation location: String) -> Date {
        let proposed = bestBefore(for: name, location: location)
        let today = Calendar.current.startOfDay(for: Date())
        if normalize(location) == freezer {
            return max(currentExpiry, proposed)
        }
        return max(today, proposed)
    }

    /// Fridge-oriented shelf life in days for a product name.
    static func baseShelfLifeDays(for name: String) -> Int {
        matchedShelfLifeDays(for: name.lowercased()) ?? 7
    }

    /// True when a keyword list (freezer, pantry, or one of the shelf-life
    /// bands) recognises this name. Names with no match are candidates for an
    /// AI-refined storage/shelf-life guess rather than the generic default.
    static func hasKeywordMatch(for name: String) -> Bool {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return freezerKeywords.contains(where: { lower.contains($0) })
            || isShelfStable(lower)
            || matchedShelfLifeDays(for: lower) != nil
    }

    private static func matchedShelfLifeDays(for lower: String) -> Int? {
        // Shelf-stable snacks and pantry items
        if isShelfStable(lower) { return 60 }
        // Eggs
        if lower.contains("egg") { return 21 }
        // Hard cheese and butter
        if lower.contains("cheese") || lower.contains("butter") { return 14 }
        // Milk, yogurt, cream
        if lower.contains("milk") || lower.contains("yogurt") || lower.contains("yoghurt") ||
           lower.contains("cream") { return 7 }
        // Raw meat
        if lower.contains("chicken") || lower.contains("beef") || lower.contains("pork") ||
           lower.contains("lamb") || lower.contains("mince") || lower.contains("sausage") ||
           lower.contains("steak") || lower.contains("meat") { return 3 }
        // Fish and seafood
        if lower.contains("fish") || lower.contains("salmon") || lower.contains("tuna") ||
           lower.contains("shrimp") || lower.contains("prawn") || lower.contains("seafood") { return 2 }
        // Leafy greens and fresh herbs
        if lower.contains("lettuce") || lower.contains("spinach") || lower.contains("herb") ||
           lower.contains("basil") || lower.contains("parsley") || lower.contains("coriander") ||
           lower.contains("kale") || lower.contains("rocket") || lower.contains("arugula") { return 5 }
        // Soft fruit and berries
        if lower.contains("banana") || lower.contains("berry") || lower.contains("strawberry") ||
           lower.contains("grape") || lower.contains("mango") || lower.contains("peach") ||
           lower.contains("plum") || lower.contains("nectarine") { return 5 }
        // Bread and wraps
        if lower.contains("bread") || lower.contains("wrap") || lower.contains("tortilla") ||
           lower.contains("bagel") || lower.contains("roll") || lower.contains("bun") { return 5 }
        // Most vegetables
        if lower.contains("tomato") || lower.contains("cucumber") || lower.contains("pepper") ||
           lower.contains("zucchini") || lower.contains("courgette") || lower.contains("broccoli") ||
           lower.contains("cauliflower") || lower.contains("mushroom") || lower.contains("celery") ||
           lower.contains("asparagus") || lower.contains("pea") || lower.contains("bean") { return 7 }
        // Root vegetables, citrus, apples
        if lower.contains("carrot") || lower.contains("potato") || lower.contains("onion") ||
           lower.contains("garlic") || lower.contains("cabbage") || lower.contains("beetroot") ||
           lower.contains("apple") || lower.contains("pear") || lower.contains("orange") ||
           lower.contains("lemon") || lower.contains("lime") || lower.contains("grapefruit") { return 14 }
        // Beverages
        if lower.contains("juice") || lower.contains("drink") || lower.contains("soda") ||
           lower.contains("beer") || lower.contains("wine") { return 14 }
        return nil
    }

    // MARK: - Keyword sets

    /// Products that belong in the freezer.
    private static let freezerKeywords: [String] = [
        "frozen", "ice cream", "ice-cream", "icecream", "ice block", "iceblock",
        "ice lolly", "gelato", "sorbet", "fish finger", "fish fingers",
        "frozen peas", "frozen veg", "frozen berries", "popsicle"
    ]

    /// Shelf-stable goods that live in the pantry / cupboard.
    private static let pantryKeywords: [String] = [
        "crisp", "chip", "cracker", "biscuit", "cookie", "cereal", "pasta",
        "rice", "flour", "sugar", "oat", "granola", "chocolate", "candy",
        "snack", "nut", "seed", "dried", "canned", "tin", "jar", "noodle",
        "lentil", "chickpea", "spice", "honey", "tea", "coffee", "cocoa",
        "stock", "sauce", "oil", "vinegar", "peanut butter", "jam", "spread",
        "couscous", "quinoa", "baking", "syrup", "condiment"
    ]

    private static func isShelfStable(_ lower: String) -> Bool {
        pantryKeywords.contains { lower.contains($0) }
    }
}
