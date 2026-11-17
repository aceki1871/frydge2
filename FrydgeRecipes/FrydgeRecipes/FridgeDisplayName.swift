//
//  FridgeDisplayName.swift
//  FrydgeRecipes
//
//  Short, one-line names and remaining-amount text for fridge rows.
//
//  Product names arrive as scanned ("Heinz Seriously Good Mayonnaise Original
//  Mayo 400g"), which wraps to three lines and makes every row a different
//  height. The row shows a short food noun instead ("Mayo") with the amount
//  beside it; the full name is still used everywhere else (detail sheet,
//  matching, shopping).
//

import Foundation

enum FridgeDisplayName {

    /// Longest short name that still fits one line at body size.
    private static let maxLength = 16

    /// Known food words that read better abbreviated on a card.
    private static let abbreviations: [String: String] = [
        "mayonnaise": "Mayo",
        "tomato ketchup": "Ketchup",
        "tomato sauce": "Tomato sauce",
        "worcestershire sauce": "Worcestershire",
        "parmesan cheese": "Parmesan",
        "cheddar cheese": "Cheddar",
        "greek yoghurt": "Greek yoghurt",
        "sweetened condensed milk": "Condensed milk",
        "extra virgin olive oil": "Olive oil",
        "balsamic vinegar": "Balsamic",
        "chicken breast fillets": "Chicken breast",
        "chicken thigh fillets": "Chicken thighs"
    ]

    /// "Heinz Seriously Good Mayonnaise Original Mayo" → "Mayo",
    /// "Anchor Butter" → "Butter", "Mainland Tasty Cheese" → "Cheese",
    /// "Free Range Eggs 12pk" → "Eggs". Names that are already short are
    /// returned as typed so the user's own wording isn't rewritten.
    static func short(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return name }

        let withoutPack = stripPackSize(trimmed)
        if withoutPack.count <= maxLength { return withoutPack }

        let lower = withoutPack.lowercased()

        // 1. Known food words appearing as whole words. Prefer the most
        //    specific (longest) one that still fits the line.
        let keywords = FoodEmoji.wholeWordKeywords(in: lower)
        if let keyword = pickKeyword(from: keywords) {
            return present(keyword)
        }
        // 2. A known food word embedded in a longer word ("Mayonnaise-style").
        if let keyword = FoodEmoji.knownKeyword(for: lower) {
            return present(keyword)
        }

        // 3. Nothing recognised: drop brand-ish leading words and keep the
        //    last two meaningful words ("Heinz Seriously Good Dressing" → "Good Dressing").
        let core = StepInference.coreNoun(of: withoutPack)
        let words = core.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let tail = words.suffix(2).joined(separator: " ")
        let fallback = tail.isEmpty ? withoutPack : tail
        return fallback.count <= maxLength ? fallback.capitalized : String(fallback.prefix(maxLength - 1)).capitalized + "…"
    }

    /// "≈ 115 g left" / "≈ 2 left" for a partly used item; nil when the
    /// amount can't be parsed or nothing has been used yet.
    static func remainingAmount(quantity: String, unit: String, quantityUsed: Double) -> String? {
        guard quantityUsed > 0, quantityUsed < 100,
              let total = FridgeUnits.parse(quantity), total > 0 else { return nil }
        let remaining = total * max(0, min(1, 1 - quantityUsed / 100))
        let (qty, displayUnit) = FridgeUnits.display(quantity: FridgeUnits.format(remaining), unit: unit)
        let normalizedUnit = displayUnit.lowercased()
        if normalizedUnit.isEmpty || normalizedUnit == "ea" || normalizedUnit == "x" {
            return "≈ \(qty) left"
        }
        return "≈ \(qty) \(displayUnit) left"
    }

    // MARK: - Helpers

    private static func pickKeyword(from keywords: [String]) -> String? {
        guard !keywords.isEmpty else { return nil }
        let fitting = keywords.filter { $0.count <= maxLength }
        let pool = fitting.isEmpty ? keywords : fitting
        // Longest first so "chicken thigh" beats "chicken"; ties keep lookup order.
        return pool.max { a, b in
            a.count != b.count ? a.count < b.count : (keywords.firstIndex(of: a) ?? 0) > (keywords.firstIndex(of: b) ?? 0)
        }
    }

    private static func present(_ keyword: String) -> String {
        if let abbreviated = abbreviations[keyword] { return abbreviated }
        let capitalised = keyword.prefix(1).uppercased() + keyword.dropFirst()
        return capitalised.count <= maxLength ? capitalised : String(capitalised.prefix(maxLength - 1)) + "…"
    }

    /// Removes trailing pack sizes and counts: "Butter 500g", "Eggs 12pk",
    /// "Milk 2L", "Yoghurt 6 x 100g".
    private static func stripPackSize(_ name: String) -> String {
        let pattern = #"\s*(\d+\s*x\s*)?\d+(?:[.,]\d+)?\s*(kg|g|l|ml|pk|pack|packs|pcs|pc|ea|x|each|dozen|%)?\.?\s*$"#
        let stripped = name.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–,")))
        return stripped.isEmpty ? name : stripped
    }
}
