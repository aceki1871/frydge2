//
//  GroceryQueryBuilder.swift
//  FrydgeRecipes
//
//  Cleans raw ingredient queries for better grocery product matching.
//

import Foundation

enum GroceryQueryBuilder {
    
    /// Builds a clean query and extracts size hints from a raw ingredient string.
    /// - Parameter rawQuery: The raw ingredient query (e.g., "2 cups of plain flour")
    /// - Returns: A tuple containing the cleaned query and optional size hint
    static func build(from rawQuery: String) -> (query: String, sizeHint: String?) {
        var text = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. Extract size hint and remove from query
        var sizeHint: String?
        (text, sizeHint) = extractSizeHint(from: text)
        
        // 2. Strip leading quantities
        text = stripLeadingQuantities(from: text)
        
        // 3. Apply recipe→retail substitutions
        text = applyRetailSubstitutions(to: text)
        
        // 4. Remove noise words
        text = removeNoiseWords(from: text)
        
        // 5. Clean up whitespace
        text = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        
        return (query: text, sizeHint: sizeHint)
    }

    /// Prepends quantity/unit to a shopping list item's name so `build(from:)` can pull out
    /// a size hint from structured fields instead of relying on it being present in free text.
    /// e.g. name="butter", quantity="500", unit="g" -> "500g butter".
    static func sizeAwareQuery(name: String, quantity: String, unit: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let qty  = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let u    = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only prepend when we have a meaningful unit (weight/volume) so we don't pollute the query.
        let knownUnits: Set<String> = ["g", "kg", "ml", "l", "lb", "oz"]
        guard !u.isEmpty, knownUnits.contains(u.lowercased()), !qty.isEmpty else { return name }
        return "\(qty)\(u) \(name)"
    }

    // MARK: - Private Helpers
    
    private static func extractSizeHint(from text: String) -> (cleanedText: String, sizeHint: String?) {
        // Pattern: matches common size formats like "2L", "500g", "1kg", "250ml", "2.5L", etc.
        let sizePattern = #"(\d+(?:\.\d+)?)\s*(kg|g|l|ml|lb|oz|fl\s?oz)\b"#
        
        guard let regex = try? NSRegularExpression(pattern: sizePattern, options: .caseInsensitive) else {
            return (text, nil)
        }
        
        let range = NSRange(text.startIndex..., in: text)
        var extractedSize: String?
        var cleanedText = text
        
        // Find the first match
        if let match = regex.firstMatch(in: text, range: range) {
            if let matchRange = Range(match.range, in: text) {
                extractedSize = String(text[matchRange])
                    .replacingOccurrences(of: " ", with: "")
                    .lowercased()
                
                // Remove the size from the text
                cleanedText = text.replacingCharacters(in: matchRange, with: "")
            }
        }
        
        return (cleanedText, extractedSize)
    }
    
    private static func stripLeadingQuantities(from text: String) -> String {
        // Pattern: matches "2 cups of", "500g of", "a pinch of", "½ cup", etc.
        let quantityPatterns = [
            #"^\d+(?:\.\d+)?\s+(?:cups?|tablespoons?|teaspoons?|tbsp?|tsp?|pinch(?:es)?)\s+(?:of\s+)?"#,
            #"^(?:a|an)\s+(?:cup|tablespoon|teaspoon|tbsp|tsp|pinch)\s+(?:of\s+)?"#,
            #"^½|¼|¾|⅓|⅔|⅛\s+(?:cups?|tablespoons?|teaspoons?|tbsp?|tsp?)\s+(?:of\s+)?"#,
            #"^\d+(?:\.\d+)?\s*(?:kg|g|l|ml|lb|oz)\s+(?:of\s+)?"#
        ]
        
        var result = text
        for pattern in quantityPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            }
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func applyRetailSubstitutions(to text: String) -> String {
        let substitutions: [(from: String, to: String)] = [
            // Flour types
            ("plain flour", "flour plain"),
            ("self raising flour", "flour self raising"),
            ("self-raising flour", "flour self raising"),
            ("wholemeal flour", "flour wholemeal"),
            ("bread flour", "flour bread"),
            
            // Sugar types
            ("caster sugar", "sugar caster"),
            ("icing sugar", "sugar icing"),
            ("brown sugar", "sugar brown"),
            ("raw sugar", "sugar raw"),
            
            // Other common swaps
            ("chicken breast", "chicken breast"),
            ("beef mince", "mince beef"),
            ("chicken stock", "stock chicken"),
            ("vegetable stock", "stock vegetable"),
            ("beef stock", "stock beef"),
            ("tomato paste", "paste tomato"),
            ("tomato puree", "puree tomato"),
        ]
        
        var result = text.lowercased()
        for (from, to) in substitutions {
            result = result.replacingOccurrences(of: from, with: to)
        }
        
        return result
    }
    
    private static func removeNoiseWords(from text: String) -> String {
        let noiseWords: Set<String> = [
            "fresh", "frozen", "chopped", "diced", "sliced", "minced",
            "roughly", "finely", "coarsely", "thinly", "thickly",
            "to taste", "optional", "if needed", "as needed",
            "room temperature", "cold", "warm", "hot",
            "good quality", "high quality", "organic",
            "preferably", "ideally", "approximately", "about"
        ]
        
        var result = text
        for word in noiseWords {
            // Use word boundaries to avoid partial matches
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            }
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
