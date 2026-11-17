//
//  ProductShorthand.swift
//  FrydgeRecipes
//
//  Turns a long product name ("Brand Popcorn Sweet & Salted 150g") into a short,
//  at-a-glance label ("Popcorn") for shopping-list rows. Full details remain on the
//  item and are shown when the row is tapped.
//

import Foundation

enum ProductShorthand {

    /// A concise, capitalised label for a product name.
    static func short(for name: String) -> String {
        // Memoised: every shopping-list row asks for this on every redraw,
        // and the alphabetical sort asks twice per comparison. The derivation
        // runs several regexes and a scan of the food keyword list.
        if let cached = shortMemo.get(name) { return cached }
        let computed = computeShort(for: name)
        shortMemo.set(name, computed)
        return computed
    }

    private static let shortMemo = LockedMemo<String>()

    private static func computeShort(for name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return cleaned }

        // 1. Prefer recognised food keywords that appear as whole words (so "Popcorn"
        //    never collapses to "corn"). Among matches:
        //    • a specific multi-word phrase wins ("Ice Cream", "Chicken Breast");
        //    • otherwise take the head noun — the last-occurring single keyword — so
        //      "Milk Chocolate" → Chocolate but "Chocolate Milk" → Milk.
        let lower = cleaned.lowercased()
        let candidates = FoodEmoji.wholeWordKeywords(in: cleaned)

        let phrases = candidates.filter { $0.contains(" ") }
        if let phrase = phrases.max(by: { $0.count < $1.count }) {
            return titleCased(phrase)
        }
        // Flavour words ("Doritos Chilli Heatwave", "Lime Cordial") only name the
        // food when nothing else in the name does, so drop them when a real
        // food keyword is also present.
        let foods = candidates.filter { !flavourWords.contains($0) }
        let pool = foods.isEmpty ? candidates : foods

        let tokens = cleaned
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "()")) }
            .filter { !$0.isEmpty }

        // "Bluebird Salt & Vinegar": every keyword is a flavour and the name
        // marks it as one, so the product is whatever comes before the flavour.
        if foods.isEmpty, !candidates.isEmpty, isFlavourDescription(tokens),
           let brand = tokens.first, !isNoise(brand), !flavourWords.contains(brand), brand.count >= 3 {
            return titleCased(brand)
        }

        if let headNoun = pool.max(by: { startIndex(of: $0, in: lower) < startIndex(of: $1, in: lower) }) {
            return titleCased(headNoun)
        }

        // 2. Otherwise strip sizes, flavours and filler, then keep the core word.
        let core = tokens.filter { !isNoise($0) }

        guard let chosen = core.last, chosen.count >= 3 else {
            // Fall back to the first meaningful word, else the original.
            if let first = tokens.first(where: { $0.count >= 3 }) {
                return titleCased(first)
            }
            return titleCased(tokens.first ?? cleaned)
        }
        return titleCased(chosen)
    }

    // MARK: - Helpers

    /// Sizes, units, flavour and marketing words that don't help identify the item.
    private static let noiseWords: Set<String> = [
        "sweet", "salted", "salt", "flavour", "flavoured", "flavored", "original",
        "classic", "light", "lite", "low", "fat", "free", "reduced", "fresh",
        "organic", "natural", "value", "pack", "multipack", "family", "large",
        "small", "mini", "jumbo", "the", "and", "with", "in", "of", "no", "added",
        "extra", "premium", "select", "everyday", "essentials", "double", "triple",
        "new", "improved", "great", "best", "each", "ea"
    ]

    /// Food keywords that, on a packaged product, usually describe the flavour
    /// rather than the food itself.
    private static let flavourWords: Set<String> = [
        "chilli", "chili", "jalapeño", "jalapen", "lime", "lemon", "salt", "sea salt",
        "vinegar", "pepper", "black pepper", "honey", "paprika", "smoked paprika"
    ]

    /// True when the name reads as "<product> <flavour> & <flavour>" or carries an
    /// explicit flavour marker, e.g. "Salt & Vinegar", "Chilli Flavoured".
    private static func isFlavourDescription(_ tokens: [String]) -> Bool {
        if tokens.contains(where: { $0 == "flavour" || $0 == "flavoured" || $0 == "flavored" }) {
            return true
        }
        for (index, token) in tokens.enumerated() where token == "&" || token == "and" {
            guard index > 0, index + 1 < tokens.count else { continue }
            if flavourWords.contains(tokens[index - 1]), flavourWords.contains(tokens[index + 1]) {
                return true
            }
        }
        return false
    }

    private static func isNoise(_ token: String) -> Bool {
        if noiseWords.contains(token) { return true }
        // Sizes/units like "150g", "2l", "500ml", "x4", "6pk", pure numbers.
        if token.range(of: #"^\d"#, options: .regularExpression) != nil { return true }
        if token.range(of: #"^x?\d+(g|kg|ml|l|pk|pack|s)?$"#, options: .regularExpression) != nil { return true }
        if token == "&" || token == "-" { return true }
        return false
    }

    /// Character offset where `word` first appears in `lowercasedText` (0 if absent).
    private static func startIndex(of word: String, in lowercasedText: String) -> Int {
        guard let range = lowercasedText.range(of: word) else { return 0 }
        return lowercasedText.distance(from: lowercasedText.startIndex, to: range.lowerBound)
    }

    private static func titleCased(_ s: String) -> String {
        s.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
