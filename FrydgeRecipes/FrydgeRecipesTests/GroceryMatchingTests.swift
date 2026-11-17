//
//  GroceryMatchingTests.swift
//  FrydgeRecipes Tests
//
//  Tests for the new grocery product matching system.
//

import Testing
import Foundation
import CoreLocation
@testable import FrydgeRecipes

@Suite("Grocery Query Builder Tests")
struct GroceryQueryBuilderTests {
    
    @Test("Extract size in grams")
    func extractSizeGrams() {
        let (query, size) = GroceryQueryBuilder.build(from: "500g beef mince")
        #expect(size == "500g")
        #expect(!query.contains("500g"))
        #expect(query.contains("mince"))
    }
    
    @Test("Extract size in liters")
    func extractSizeLiters() {
        let (query, size) = GroceryQueryBuilder.build(from: "2L milk")
        #expect(size == "2l")
        #expect(query.contains("milk"))
    }
    
    @Test("Extract decimal size")
    func extractSizeDecimal() {
        let (query, size) = GroceryQueryBuilder.build(from: "1.5kg chicken breast")
        #expect(size == "1.5kg")
        #expect(query.contains("chicken"))
    }
    
    @Test("Strip cup quantity")
    func stripCupQuantity() {
        let (query, _) = GroceryQueryBuilder.build(from: "2 cups of flour")
        #expect(!query.contains("cups"))
        #expect(!query.contains("of"))
        #expect(query.contains("flour"))
    }
    
    @Test("Strip tablespoon quantity")
    func stripTablespoonQuantity() {
        let (query, _) = GroceryQueryBuilder.build(from: "3 tablespoons of olive oil")
        #expect(!query.contains("tablespoons"))
        #expect(query.contains("olive"))
        #expect(query.contains("oil"))
    }
    
    @Test("Plain flour substitution")
    func plainFlourSubstitution() {
        let (query, _) = GroceryQueryBuilder.build(from: "plain flour")
        #expect(query == "flour plain")
    }
    
    @Test("Self raising flour substitution")
    func selfRaisingFlourSubstitution() {
        let (query, _) = GroceryQueryBuilder.build(from: "self raising flour")
        #expect(query == "flour self raising")
    }
    
    @Test("Sugar substitutions")
    func sugarSubstitutions() {
        let (query1, _) = GroceryQueryBuilder.build(from: "caster sugar")
        #expect(query1 == "sugar caster")
        
        let (query2, _) = GroceryQueryBuilder.build(from: "brown sugar")
        #expect(query2 == "sugar brown")
    }
    
    @Test("Remove noise: fresh")
    func removeNoiseFresh() {
        let (query, _) = GroceryQueryBuilder.build(from: "fresh tomatoes")
        #expect(!query.contains("fresh"))
        #expect(query.contains("tomatoes"))
    }
    
    @Test("Remove noise: chopped")
    func removeNoiseChopped() {
        let (query, _) = GroceryQueryBuilder.build(from: "chopped onions")
        #expect(!query.contains("chopped"))
        #expect(query.contains("onions"))
    }
    
    @Test("Remove multiple noise words")
    func removeMultipleNoise() {
        let (query, _) = GroceryQueryBuilder.build(from: "fresh finely chopped tomatoes")
        #expect(!query.contains("fresh"))
        #expect(!query.contains("finely"))
        #expect(!query.contains("chopped"))
        #expect(query.contains("tomatoes"))
    }
    
    @Test("Complex example with multiple transformations")
    func complexExample() {
        let (query, size) = GroceryQueryBuilder.build(from: "2 cups of fresh plain flour")
        #expect(!query.contains("cups"))
        #expect(!query.contains("fresh"))
        #expect(query.contains("flour"))
        #expect(query.contains("plain"))
        #expect(size == nil) // No size like "2kg" detected
    }
    
    @Test("Preserves important words")
    func preservesImportantWords() {
        let (query, _) = GroceryQueryBuilder.build(from: "chicken breast")
        #expect(query.contains("chicken"))
        #expect(query.contains("breast"))
    }
}

@Suite("Product Matcher Scoring Tests")
struct ProductMatcherScoringTests {
    
    @Test("Perfect token match")
    func perfectTokenMatch() {
        let offer = makeOffer(title: "Flour Plain 1kg Premium")
        let score = ProductMatcher.score(
            offer: offer,
            query: "flour plain",
            sizeHint: nil
        )
        #expect(score.value > 0.65) // At least the token weight
    }
    
    @Test("No token match")
    func noTokenMatch() {
        let offer = makeOffer(title: "Chocolate Cookies 200g")
        let score = ProductMatcher.score(
            offer: offer,
            query: "flour plain",
            sizeHint: nil
        )
        #expect(score.value < 0.3)
    }
    
    @Test("Exact size match")
    func exactSizeMatch() {
        let offer = makeOffer(title: "Flour Plain 1kg")
        let score = ProductMatcher.score(
            offer: offer,
            query: "flour plain",
            sizeHint: "1kg"
        )
        #expect(score.value > 0.8)
        #expect(score.hasExactSizeMatch)
    }
    
    @Test("Close size match")
    func closeSizeMatch() {
        let offer = makeOffer(title: "Flour Plain 1.5kg")
        let score = ProductMatcher.score(
            offer: offer,
            query: "flour plain",
            sizeHint: "1kg"
        )
        #expect(score.value > 0.6)
        #expect(!score.hasExactSizeMatch)
    }
    
    @Test("Different size categories")
    func differentSizeCategories() {
        let offer = makeOffer(title: "Milk 2L") // Volume
        let score = ProductMatcher.score(
            offer: offer,
            query: "milk",
            sizeHint: "500g" // Weight
        )
        // Should have lower size component
        #expect(score.value < 0.9)
    }
    
    @Test("Store brand penalty")
    func storeBrandPenalty() {
        let regular = makeOffer(title: "Anchor Flour Plain 1kg")
        let storeBrand = makeOffer(title: "Pams Flour Plain 1kg")
        
        let regularScore = ProductMatcher.score(offer: regular, query: "flour plain", sizeHint: "1kg")
        let brandScore = ProductMatcher.score(offer: storeBrand, query: "flour plain", sizeHint: "1kg")
        
        #expect(regularScore.value > brandScore.value)
    }
    
    @Test("Homebrand detection")
    func homebrandDetection() {
        let offer = makeOffer(title: "Homebrand Flour 1kg")
        let score1 = ProductMatcher.score(offer: offer, query: "flour", sizeHint: nil)
        
        let regularOffer = makeOffer(title: "Premium Flour 1kg")
        let score2 = ProductMatcher.score(offer: regularOffer, query: "flour", sizeHint: nil)
        
        #expect(score2.value > score1.value)
    }
    
    private func makeOffer(title: String, price: Double = 5.99) -> StockAvailability.StoreOffer {
        StockAvailability.StoreOffer(
            store: "Test Store",
            productURL: URL(string: "https://example.com")!,
            currencyCode: "NZD",
            price: price,
            promoText: nil,
            isProbablyMatch: true,
            storeCoordinate: nil,
            distanceMeters: nil,
            productTitle: title,
            imageURL: nil,
            detailsText: nil
        )
    }
}

@Suite("Product Matcher Ranking Tests")
struct ProductMatcherRankingTests {
    
    @Test("Filter below threshold")
    func filterBelowThreshold() {
        let offers = [
            makeOffer(title: "Flour Plain 1kg", price: 5.99, query: "flour plain"),      // Good match
            makeOffer(title: "Chocolate Cookies", price: 5.99, query: "flour plain"),     // Bad match
            makeOffer(title: "Sugar White 1kg", price: 5.99, query: "flour plain")        // Bad match
        ]
        
        let ranked = ProductMatcher.rankAndFilter(
            offers: offers,
            query: "flour plain",
            sizeHint: nil,
            threshold: 0.45
        )
        
        #expect(ranked.count < offers.count)
        #expect(ranked.contains { $0.productTitle?.contains("Flour") == true })
    }
    
    @Test("Sorts exact size first")
    func sortsExactSizeFirst() {
        let offers = [
            makeOffer(title: "Flour Plain 500g", price: 2.99),   // Close size
            makeOffer(title: "Flour Plain 1kg", price: 4.99),    // Exact size, more expensive
            makeOffer(title: "Flour Plain 2kg", price: 7.99)     // Different size
        ]
        
        let ranked = ProductMatcher.rankAndFilter(
            offers: offers,
            query: "flour plain",
            sizeHint: "1kg"
        )
        
        // 1kg should be first despite higher price
        #expect(ranked.first?.productTitle?.contains("1kg") == true)
    }
    
    @Test("Sorts by score")
    func sortsByScore() {
        let offers = [
            makeOffer(title: "Flour", price: 3.99),                    // Partial match
            makeOffer(title: "Flour Plain Premium", price: 5.99),      // Best match
            makeOffer(title: "Plain Baking Flour", price: 4.99)        // Good match
        ]
        
        let ranked = ProductMatcher.rankAndFilter(
            offers: offers,
            query: "flour plain",
            sizeHint: nil
        )
        
        // Best scoring (most query tokens) should be first
        #expect(ranked.first?.productTitle?.contains("Plain") == true)
    }
    
    @Test("Sorts by price")
    func sortsByPrice() {
        let offers = [
            makeOffer(title: "Flour Plain 1kg", price: 5.99),
            makeOffer(title: "Flour Plain 1kg", price: 3.99),
            makeOffer(title: "Flour Plain 1kg", price: 7.99)
        ]
        
        let ranked = ProductMatcher.rankAndFilter(
            offers: offers,
            query: "flour plain",
            sizeHint: "1kg"
        )
        
        #expect(ranked.first?.price == 3.99)
    }
    
    private func makeOffer(title: String, price: Double, query: String = "") -> StockAvailability.StoreOffer {
        StockAvailability.StoreOffer(
            store: "Test Store",
            productURL: URL(string: "https://example.com/\(UUID().uuidString)")!,
            currencyCode: "NZD",
            price: price,
            promoText: nil,
            isProbablyMatch: true,
            storeCoordinate: nil,
            distanceMeters: nil,
            productTitle: title,
            imageURL: nil,
            detailsText: nil
        )
    }
}

@Suite("Ingredient Product Cache Tests", .serialized)
struct IngredientProductCacheTests {
    
    @Test("Save and retrieve")
    func saveAndRetrieve() async throws {
        let cache = IngredientProductCache.shared
        let offer = makeOffer(title: "Anchor Flour Plain 1kg")
        
        await cache.save(offer: offer, for: "plain flour")
        let retrieved = await cache.preferred(for: "plain flour")
        
        #expect(retrieved != nil)
        #expect(retrieved?.productTitle == "Anchor Flour Plain 1kg")
        
        // Cleanup
        await cache.clear(for: "plain flour")
    }
    
    @Test("Key normalization: case")
    func keyNormalizationCase() async throws {
        let cache = IngredientProductCache.shared
        let offer = makeOffer(title: "Test Product")
        
        await cache.save(offer: offer, for: "Plain Flour")
        let retrieved = await cache.preferred(for: "plain flour")
        
        #expect(retrieved != nil)
        
        // Cleanup
        await cache.clear(for: "plain flour")
    }
    
    @Test("Key normalization: spaces")
    func keyNormalizationSpaces() async throws {
        let cache = IngredientProductCache.shared
        let offer = makeOffer(title: "Test Product")
        
        await cache.save(offer: offer, for: "chicken breast")
        let retrieved = await cache.preferred(for: "chicken breast")
        
        #expect(retrieved != nil)
        
        // Cleanup
        await cache.clear(for: "chicken breast")
    }
    
    @Test("Clear specific item")
    func clearSpecific() async throws {
        let cache = IngredientProductCache.shared
        let offer1 = makeOffer(title: "Flour")
        let offer2 = makeOffer(title: "Sugar")
        
        await cache.save(offer: offer1, for: "flour")
        await cache.save(offer: offer2, for: "sugar")
        
        await cache.clear(for: "flour")
        
        let flourRetrieved = await cache.preferred(for: "flour")
        let sugarRetrieved = await cache.preferred(for: "sugar")
        
        #expect(flourRetrieved == nil)
        #expect(sugarRetrieved != nil)
        
        // Cleanup
        await cache.clear(for: "sugar")
    }
    
    @Test("Clear all items")
    func clearAll() async throws {
        let cache = IngredientProductCache.shared
        let offer1 = makeOffer(title: "Flour")
        let offer2 = makeOffer(title: "Sugar")
        
        await cache.save(offer: offer1, for: "flour")
        await cache.save(offer: offer2, for: "sugar")
        
        await cache.clearAll()
        
        let all = await cache.allCached()
        #expect(all.isEmpty)
    }
    
    @Test("Cached to offer conversion")
    func cachedToOffer() async throws {
        let cache = IngredientProductCache.shared
        let originalOffer = makeOffer(title: "Test Flour 1kg")
        
        await cache.save(offer: originalOffer, for: "flour")
        
        guard let cached = await cache.preferred(for: "flour"),
              let convertedOffer = cached.toStoreOffer() else {
            Issue.record("Failed to retrieve or convert cached offer")
            return
        }
        
        #expect(convertedOffer.productTitle == originalOffer.productTitle)
        #expect(convertedOffer.store == originalOffer.store)
        #expect(convertedOffer.price == originalOffer.price)
        #expect(convertedOffer.currencyCode == originalOffer.currencyCode)
        
        // Cleanup
        await cache.clear(for: "flour")
    }
    
    private func makeOffer(title: String, price: Double = 4.99) -> StockAvailability.StoreOffer {
        StockAvailability.StoreOffer(
            store: "Test Store",
            productURL: URL(string: "https://example.com/\(UUID().uuidString)")!,
            currencyCode: "NZD",
            price: price,
            promoText: nil,
            isProbablyMatch: true,
            storeCoordinate: CLLocationCoordinate2D(latitude: -36.8485, longitude: 174.7633),
            distanceMeters: 1000,
            productTitle: title,
            imageURL: URL(string: "https://example.com/image.jpg"),
            detailsText: "Test details"
        )
    }
}

@Suite("Integration Tests")
struct IntegrationTests {
    
    @Test("Full workflow")
    func fullWorkflow() {
        // 1. Build clean query
        let (cleanQuery, sizeHint) = GroceryQueryBuilder.build(from: "2 cups of fresh plain flour")
        #expect(cleanQuery.contains("flour"))
        
        // 2. Create mock offers
        let offers = [
            makeOffer(title: "Anchor Flour Plain 1kg", price: 4.99),
            makeOffer(title: "Pams Flour Plain 1kg", price: 3.49),
            makeOffer(title: "Flour Self Raising 1kg", price: 4.50),
            makeOffer(title: "Sugar White 1kg", price: 2.99)
        ]
        
        // 3. Rank and filter
        let ranked = ProductMatcher.rankAndFilter(
            offers: offers,
            query: cleanQuery,
            sizeHint: sizeHint
        )
        
        // 4. Verify results
        #expect(ranked.count > 0)
        #expect(ranked.count < offers.count) // Should filter out sugar
        
        // First result should be plain flour (not self-raising)
        #expect(ranked.first?.productTitle?.lowercased().contains("plain") == true)
    }
    
    @Test("Size matching workflow")
    func sizeMatchingWorkflow() {
        let (cleanQuery, sizeHint) = GroceryQueryBuilder.build(from: "1kg plain flour")
        
        #expect(sizeHint == "1kg")
        
        let offers = [
            makeOffer(title: "Flour Plain 500g", price: 2.99),
            makeOffer(title: "Flour Plain 1kg", price: 4.99),
            makeOffer(title: "Flour Plain 2kg", price: 8.99)
        ]
        
        let ranked = ProductMatcher.rankAndFilter(
            offers: offers,
            query: cleanQuery,
            sizeHint: sizeHint
        )
        
        // Exact size match (1kg) should be first, even though 500g is cheaper
        #expect(ranked.first?.productTitle?.contains("1kg") == true)
    }
    
    private func makeOffer(title: String, price: Double) -> StockAvailability.StoreOffer {
        StockAvailability.StoreOffer(
            store: "Test Store",
            productURL: URL(string: "https://example.com/\(UUID().uuidString)")!,
            currencyCode: "NZD",
            price: price,
            promoText: nil,
            isProbablyMatch: true,
            storeCoordinate: nil,
            distanceMeters: nil,
            productTitle: title,
            imageURL: nil,
            detailsText: nil
        )
    }
}
