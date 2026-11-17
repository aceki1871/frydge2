//
//  RecipePresentation.swift
//  FrydgeRecipes
//
//  Small presentation helpers shared by the recipe list, detail view and
//  thumbnails: a tidied display name, and the artwork shown in place of a
//  photo so every recipe has an image even before one is found or added.
//

import SwiftUI

// MARK: - Display name

extension CloudRecipe {
    /// The recipe name as it should read in the UI: whitespace collapsed,
    /// stray punctuation trimmed, and SHOUTED or all-lowercase names
    /// brought to title case. Names with deliberate mixed case ("Mum's
    /// Pav") are left exactly as typed.
    var displayName: String {
        RecipeNameFormatter.display(name)
    }
}

enum RecipeNameFormatter {

    /// Words kept lowercase inside a title-cased name.
    private static let minorWords: Set<String> = [
        "a", "an", "and", "at", "but", "by", "for", "in", "n", "of", "on", "or", "the", "to", "with", "de", "la", "al"
    ]

    /// Leading labels people paste in from imports.
    private static let leadingNoise = try? NSRegularExpression(
        pattern: #"^\s*(recipe|recipes?\s*:|how to make|easy|the best)\s*[:\-–—]?\s+"#,
        options: [.caseInsensitive]
    )

    static func display(_ raw: String) -> String {
        var name = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let leadingNoise {
            let range = NSRange(name.startIndex..., in: name)
            name = leadingNoise.stringByReplacingMatches(in: name, range: range, withTemplate: "")
        }

        // Trailing punctuation left over from imports: "Pad Thai." / "Soup -"
        while let last = name.last, ".,;:-–—|".contains(last) {
            name.removeLast()
            name = name.trimmingCharacters(in: .whitespaces)
        }

        guard !name.isEmpty else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }

        let letters = name.filter(\.isLetter)
        let isShouting = !letters.isEmpty && letters.allSatisfy(\.isUppercase) && letters.count > 3
        let isAllLower = !letters.isEmpty && letters.allSatisfy(\.isLowercase)
        guard isShouting || isAllLower else { return name }

        return titleCased(name)
    }

    /// "chicken and leek pie" → "Chicken and Leek Pie".
    static func titleCased(_ s: String) -> String {
        let words = s.lowercased().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return words.enumerated().map { index, word in
            let isEdge = index == 0 || index == words.count - 1
            if !isEdge, minorWords.contains(word) { return word }
            // Keep hyphenated parts capitalised too: "stir-fry" → "Stir-Fry".
            return word.split(separator: "-", omittingEmptySubsequences: false)
                .map { part -> String in
                    guard let first = part.first else { return "" }
                    return String(first).uppercased() + part.dropFirst()
                }
                .joined(separator: "-")
        }
        .joined(separator: " ")
    }
}

// MARK: - Placeholder artwork

/// What a recipe looks like when it has no photo: a soft gradient in the
/// recipe's chapter colour with its food emoji, so cards never show a grey
/// "missing image" box. Fills whatever frame it's given.
struct RecipePlaceholderArtwork: View {
    let recipeName: String
    var category: RecipeCategory? = nil
    /// Emoji size relative to the shorter side of the frame.
    var emojiScale: CGFloat = 0.42

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let tint = (category ?? .veggie).color

            ZStack {
                LinearGradient(
                    colors: [tint.opacity(0.85), tint.opacity(0.45), Color.black.opacity(0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // A couple of soft highlights so the gradient reads as
                // "artwork" rather than a flat colour.
                Circle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: side * 0.9, height: side * 0.9)
                    .offset(x: -side * 0.35, y: -side * 0.3)
                    .blur(radius: side * 0.08)
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: side * 0.6, height: side * 0.6)
                    .offset(x: side * 0.4, y: side * 0.35)
                    .blur(radius: side * 0.06)

                Text(FoodEmoji.emoji(for: recipeName))
                    .font(.system(size: max(16, side * emojiScale)))
                    .shadow(color: .black.opacity(0.25), radius: side * 0.03, x: 0, y: side * 0.015)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Preferred store

/// The supermarket the user would rather buy from. Price tags and recipe
/// cost totals prefer this store's offer when it has one; "cheapest" is used
/// when nothing is set.
enum PreferredStore {
    static let key = "frydge.preferredStoreName"

    static var name: String? {
        get {
            let value = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        set {
            let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
    }

    /// Loose store-name comparison: "New World Mt Roskill" matches "New World".
    static func matches(_ storeName: String, preferred: String?) -> Bool {
        guard let preferred, !preferred.isEmpty else { return false }
        let a = normalize(storeName)
        let b = normalize(preferred)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// Picks the offer to show for one ingredient: the cheapest at the
    /// preferred store when it stocks it, otherwise the cheapest anywhere.
    static func bestOffer(from offers: [StockAvailability.StoreOffer], preferred: String?) -> StockAvailability.StoreOffer? {
        let priced = offers.filter { $0.price != nil }
        if let preferred {
            let atStore = priced.filter { matches($0.store, preferred: preferred) }
            if let best = atStore.min(by: { ($0.price ?? 0) < ($1.price ?? 0) }) { return best }
        }
        return priced.min(by: { ($0.price ?? 0) < ($1.price ?? 0) })
    }

    /// Brand name without a branch: "Pak'nSave Sylvia Park" → "Pak'nSave".
    static func brand(of storeName: String) -> String {
        let folded = normalize(storeName)
        // Compared after the same normalisation as the store name, so
        // "Pak’nSave", "Pak'nSave", "PAK n SAVE" and "paknsave" all match.
        let brands = ["pak n save", "pak nsave", "paknsave", "new world", "four square", "woolworths", "countdown",
                      "fresh choice", "supervalue", "waitrose", "sainsbury s", "sainsburys", "tesco", "co op", "coop",
                      "morrisons", "asda", "aldi", "lidl", "ocado", "iceland"]
            .map(normalize)
            .sorted { $0.count > $1.count }
        for brand in brands where folded.hasPrefix(brand) {
            let endIndex = storeName.index(storeName.startIndex, offsetBy: min(brand.count, storeName.count))
            return String(storeName[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return storeName.split(separator: " ").first.map(String.init) ?? storeName
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
