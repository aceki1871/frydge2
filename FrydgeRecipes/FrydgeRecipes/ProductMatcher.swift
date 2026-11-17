//
//  ProductMatcher.swift
//  FrydgeRecipes
//
//  Scores and ranks grocery product offers based on query matching.
//

import Foundation

enum ProductMatcher {
    
    struct Score {
        let value: Double // 0.0 to 1.0
        let hasExactSizeMatch: Bool
        
        var isAboveThreshold: Bool {
            value >= 0.45
        }
    }
    
    /// Scores a store offer against a query and size hint.
    /// - Parameters:
    ///   - offer: The store offer to score
    ///   - query: The cleaned search query
    ///   - sizeHint: Optional size hint (e.g., "2l", "500g")
    /// - Returns: A Score indicating match quality
    static func score(
        offer: StockAvailability.StoreOffer,
        query: String,
        sizeHint: String?
    ) -> Score {
        guard let productTitle = offer.productTitle else {
            return Score(value: 0.0, hasExactSizeMatch: false)
        }
        
        let normalizedTitle = productTitle.lowercased()
        let normalizedQuery = query.lowercased()
        
        // 1. Token overlap (60% weight - reduced to make room for other factors)
        let tokenScore = calculateTokenOverlap(
            title: normalizedTitle,
            query: normalizedQuery
        )
        
        // 2. Unwanted variant penalty (15% weight - NEW)
        let variantPenalty = calculateVariantPenalty(
            title: normalizedTitle,
            query: normalizedQuery
        )
        
        // 3. Size match (25% weight - reduced)
        let (sizeScore, hasExactSizeMatch) = calculateSizeMatch(
            title: normalizedTitle,
            sizeHint: sizeHint
        )
        
        // 4. Weighted combination
        var finalScore = (tokenScore * 0.60) + (variantPenalty * 0.15) + (sizeScore * 0.25)
        
        // 5. Store-brand penalty (×0.9 for budget brands)
        if isStoreBrand(offer: offer) {
            finalScore *= 0.9
        }
        
        return Score(value: min(1.0, max(0.0, finalScore)), hasExactSizeMatch: hasExactSizeMatch)
    }
    
    /// Ranks and filters offers based on score threshold.
    /// - Parameters:
    ///   - offers: Array of store offers to filter and rank
    ///   - query: The cleaned search query
    ///   - sizeHint: Optional size hint
    ///   - threshold: Minimum score threshold (default: 0.50 - increased for better precision)
    /// - Returns: Filtered and sorted array of offers
    static func rankAndFilter(
        offers: [StockAvailability.StoreOffer],
        query: String,
        sizeHint: String?,
        threshold: Double = 0.50
    ) -> [StockAvailability.StoreOffer] {
        // Score all offers
        let scoredOffers = offers.map { offer -> (offer: StockAvailability.StoreOffer, score: Score) in
            let score = self.score(offer: offer, query: query, sizeHint: sizeHint)
            return (offer, score)
        }
        
        // Filter by threshold
        let filtered = scoredOffers.filter { $0.score.value >= threshold }
        
        // Sort by:
        // 1. Exact size match first
        // 2. Then by score (descending)
        // 3. Then by price (ascending)
        let sorted = filtered.sorted { lhs, rhs in
            // Exact size matches come first
            if lhs.score.hasExactSizeMatch != rhs.score.hasExactSizeMatch {
                return lhs.score.hasExactSizeMatch
            }
            
            // Then by score
            if abs(lhs.score.value - rhs.score.value) > 0.01 {
                return lhs.score.value > rhs.score.value
            }
            
            // Then by price
            switch (lhs.offer.price, rhs.offer.price) {
            case let (l?, r?):
                return l < r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.offer.store.localizedCaseInsensitiveCompare(rhs.offer.store) == .orderedAscending
            }
        }
        
        return sorted.map { $0.offer }
    }
    
    // MARK: - Private Helpers
    
    private static func calculateVariantPenalty(title: String, query: String) -> Double {
        // Penalize products with unwanted variant keywords that aren't in the query
        let unwantedVariants = [
            "and coconut", "coconut", "chocolate", "vanilla", "strawberry",
            "sweetened", "unsweetened", "light", "lite", "reduced fat", "skim",
            "full cream", "lactose free", "gluten free", "organic",
            "flavoured", "flavored", "extra", "plus"
        ]
        
        let titleTokens = Set(tokenize(title))
        let queryTokens = Set(tokenize(query))
        
        var penalty = 1.0
        
        for variant in unwantedVariants {
            let variantTokens = Set(tokenize(variant))
            
            // If the title contains this variant but the query doesn't...
            if !variantTokens.isDisjoint(with: titleTokens) && variantTokens.isDisjoint(with: queryTokens) {
                // Apply a penalty (reduce score by 30% for each unwanted variant)
                penalty *= 0.7
            }
        }
        
        return penalty
    }
    
    private static func calculateTokenOverlap(title: String, query: String) -> Double {
        let titleTokens = Set(tokenize(title))
        let queryTokens = Set(tokenize(query))
        
        guard !queryTokens.isEmpty else { return 0.0 }
        
        let intersection = titleTokens.intersection(queryTokens)
        
        // Boost score if ALL query tokens are present
        let baseOverlap = Double(intersection.count) / Double(queryTokens.count)
        
        // Additional penalty if title has many extra tokens (suggests wrong product)
        let titleExtraTokens = titleTokens.subtracting(queryTokens).count
        let extraTokenPenalty = titleExtraTokens > 3 ? 0.9 : 1.0
        
        return baseOverlap * extraTokenPenalty
    }
    
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }
    
    private static func calculateSizeMatch(
        title: String,
        sizeHint: String?
    ) -> (score: Double, exactMatch: Bool) {
        guard let sizeHint = sizeHint?.lowercased() else {
            return (0.5, false) // Neutral score when no size hint
        }
        
        // Extract size from title using similar pattern
        let sizePattern = #"(\d+(?:\.\d+)?)\s*(kg|g|l|ml|lb|oz|fl\s?oz)\b"#
        
        guard let regex = try? NSRegularExpression(pattern: sizePattern, options: .caseInsensitive) else {
            return (0.5, false)
        }
        
        let range = NSRange(title.startIndex..., in: title)
        guard let match = regex.firstMatch(in: title, range: range),
              let matchRange = Range(match.range, in: title) else {
            return (0.5, false) // No size in title, neutral score
        }
        
        let titleSize = String(title[matchRange])
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        
        // Exact match
        if titleSize == sizeHint {
            return (1.0, true)
        }
        
        // Parse and compare values
        if let hintValue = extractSizeValue(from: sizeHint),
           let titleValue = extractSizeValue(from: titleSize) {
            
            let hintUnit = extractUnit(from: sizeHint)
            let titleUnit = extractUnit(from: titleSize)
            
            // Same unit comparison
            if hintUnit == titleUnit {
                let ratio = min(hintValue, titleValue) / max(hintValue, titleValue)
                return (ratio, false) // Close sizes get higher scores
            }
            
            // Different units but same category (weight or volume)
            if areSameCategory(unit1: hintUnit, unit2: titleUnit) {
                // Convert and compare
                let normalizedHint = normalizeToBase(value: hintValue, unit: hintUnit)
                let normalizedTitle = normalizeToBase(value: titleValue, unit: titleUnit)
                let ratio = min(normalizedHint, normalizedTitle) / max(normalizedHint, normalizedTitle)
                return (ratio, false)
            }
        }
        
        return (0.3, false) // Different units/categories
    }
    
    private static func extractSizeValue(from size: String) -> Double? {
        let pattern = #"(\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: size, range: NSRange(size.startIndex..., in: size)),
              let matchRange = Range(match.range, in: size) else {
            return nil
        }
        return Double(String(size[matchRange]))
    }
    
    private static func extractUnit(from size: String) -> String {
        let pattern = #"(kg|g|l|ml|lb|oz|floz)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: size, range: NSRange(size.startIndex..., in: size)),
              let matchRange = Range(match.range, in: size) else {
            return ""
        }
        return String(size[matchRange]).lowercased()
    }
    
    private static func areSameCategory(unit1: String, unit2: String) -> Bool {
        let weightUnits: Set<String> = ["kg", "g", "lb", "oz"]
        let volumeUnits: Set<String> = ["l", "ml", "floz"]
        
        return (weightUnits.contains(unit1) && weightUnits.contains(unit2)) ||
               (volumeUnits.contains(unit1) && volumeUnits.contains(unit2))
    }
    
    private static func normalizeToBase(value: Double, unit: String) -> Double {
        switch unit {
        case "kg": return value * 1000 // to grams
        case "g": return value
        case "lb": return value * 453.592 // to grams
        case "oz": return value * 28.3495 // to grams
        case "l": return value * 1000 // to ml
        case "ml": return value
        case "floz": return value * 29.5735 // to ml
        default: return value
        }
    }
    
    private static func isStoreBrand(offer: StockAvailability.StoreOffer) -> Bool {
        let storeBrands = [
            "pams", "pam's", "homebrand", "home brand",
            "countdown brand", "countdown", "value",
            "woolworths essentials", "woolworths", "essentials",
            "budget", "signature range", "select"
        ]
        
        guard let title = offer.productTitle?.lowercased() else { return false }
        
        return storeBrands.contains { brand in
            title.contains(brand)
        }
    }
}
