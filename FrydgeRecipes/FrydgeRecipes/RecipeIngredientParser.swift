//
//  RecipeIngredientParser.swift
//  FrydgeRecipes
//
//  Splits a free-text recipe ingredient line ("2 cups flour", "500g butter",
//  "2 x eggs") into name / quantity / unit so recipes can be expanded into shared
//  frydges and shopping lists. A lightweight, reusable version of the private
//  parser in RecipeDetailView.
//

import Foundation

enum RecipeIngredientParser {

    /// Units we recognise at the start of an ingredient line.
    private static let units = #"kg|g|l|ml|pcs|pc|tbsp|tsp|cups?|oz|lb|cloves?|slices?|cans?|tins?|bunch(?:es)?"#

    /// Compiled once: this parser runs on every recipe line in every match pass.
    private static let leadingAmountRegex = try? NSRegularExpression(
        pattern: #"^(\d+(?:[.,]\d+)?|\d+/\d+)\s*(\#(units))?(?![a-zA-Z])\.?\s*(?:x\s+)?(.+)$"#,
        options: [.caseInsensitive]
    )

    /// "Onion 2", "Onion x2", "Butter 500 g", "Eggs 12 pcs": the amount after the
    /// name, which is how the bundled recipes and many hand-typed lines are written.
    /// The name must contain a letter so a bare "2" is never split into nothing.
    private static let trailingAmountRegex = try? NSRegularExpression(
        pattern: #"^(.*?[a-zA-Z].*?)\s+(?:x\s*)?(\d+(?:[.,]\d+)?|\d+/\d+)\s*(\#(units))?\.?\s*$"#,
        options: [.caseInsensitive]
    )

    /// Parses one ingredient line. Falls back to the whole string as the name with
    /// quantity "1" when no leading or trailing amount is found.
    static func parse(_ raw: String) -> (name: String, quantity: String, unit: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return ("", "1", "") }

        // "2 cups flour", "500g butter", "2 eggs", "2 x eggs", "1/2 tsp salt"
        // The unit must end at a word boundary, otherwise "1 lemon" reads as
        // unit "l" + name "emon" and "2 garlic" as unit "g" + name "arlic".
        if let regex = leadingAmountRegex {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            if let m = regex.firstMatch(in: cleaned, options: [], range: range), m.numberOfRanges > 3 {
                let qty = substring(m, 1, cleaned) ?? "1"
                let unit = substring(m, 2, cleaned) ?? ""
                let name = (substring(m, 3, cleaned) ?? cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    return (name, normalizeQuantity(qty), unit.lowercased())
                }
            }
        }

        // "Onion 2", "Butter 500 g": otherwise the number stays in the name and the
        // shopping list shows nonsense like "Onion 2 x1".
        if let regex = trailingAmountRegex {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            if let m = regex.firstMatch(in: cleaned, options: [], range: range), m.numberOfRanges > 3,
               let name = substring(m, 1, cleaned), let qty = substring(m, 2, cleaned) {
                let unit = substring(m, 3, cleaned) ?? ""
                return (name, normalizeQuantity(qty), unit.lowercased())
            }
        }
        return (cleaned, "1", "")
    }

    /// Splits a bare trailing count off a name that was stored without one being
    /// parsed, e.g. "Onion 2" → ("Onion", "2"). Returns nil when the name doesn't
    /// end in a plain number (a unit such as "500 g" is left alone here so pack
    /// sizing isn't second-guessed on an already-structured item).
    static func splitTrailingCount(_ name: String) -> (name: String, quantity: String)? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = trailingAmountRegex else { return nil }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        guard let m = regex.firstMatch(in: cleaned, options: [], range: range), m.numberOfRanges > 3,
              substring(m, 3, cleaned) == nil,
              let base = substring(m, 1, cleaned), let qty = substring(m, 2, cleaned) else { return nil }
        return (base, normalizeQuantity(qty))
    }

    private static func substring(_ match: NSTextCheckingResult, _ index: Int, _ source: String) -> String? {
        guard match.range(at: index).location != NSNotFound,
              let r = Range(match.range(at: index), in: source) else { return nil }
        let s = String(source[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func normalizeQuantity(_ q: String) -> String {
        q.replacingOccurrences(of: ",", with: ".")
    }
}
