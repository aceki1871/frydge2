//
//  IngredientProductCache.swift
//  FrydgeRecipes
//
//  Caches user-preferred products for specific ingredients.
//

import Foundation
import CoreLocation

actor IngredientProductCache {
    
    static let shared = IngredientProductCache()
    
    private let cacheKey = "ingredient_product_prefs_v1"
    private var cache: [String: CachedProduct] = [:]
    
    struct CachedProduct: Codable {
        let ingredient: String
        let store: String
        let productURL: String
        let currencyCode: String
        let price: Double?
        let productTitle: String
        let imageURL: String?
        let timestamp: Date
        
        // Additional fields for context
        let storeLatitude: Double?
        let storeLongitude: Double?
    }
    
    private init() {
        cache = Self.loadFromDisk(cacheKey: cacheKey)
    }
    
    // MARK: - Public API
    
    /// Retrieves the preferred product for a given ingredient.
    /// - Parameter ingredient: The ingredient name (will be normalized)
    /// - Returns: The cached product, if one exists
    func preferred(for ingredient: String) -> CachedProduct? {
        let key = normalizeKey(ingredient)
        return cache[key]
    }
    
    /// Saves a user-selected product preference for an ingredient.
    /// - Parameters:
    ///   - offer: The store offer the user selected
    ///   - ingredient: The ingredient name
    func save(offer: StockAvailability.StoreOffer, for ingredient: String) {
        let key = normalizeKey(ingredient)
        
        guard let productTitle = offer.productTitle else { return }
        
        let cached = CachedProduct(
            ingredient: ingredient,
            store: offer.store,
            productURL: offer.productURL.absoluteString,
            currencyCode: offer.currencyCode,
            price: offer.price,
            productTitle: productTitle,
            imageURL: offer.imageURL?.absoluteString,
            timestamp: Date(),
            storeLatitude: offer.storeCoordinate?.latitude,
            storeLongitude: offer.storeCoordinate?.longitude
        )
        
        cache[key] = cached
        saveToDisk()
    }
    
    /// Clears the cached preference for a specific ingredient.
    /// - Parameter ingredient: The ingredient name
    func clear(for ingredient: String) {
        let key = normalizeKey(ingredient)
        cache.removeValue(forKey: key)
        saveToDisk()
    }
    
    /// Clears all cached preferences.
    func clearAll() {
        cache.removeAll()
        saveToDisk()
    }
    
    /// Returns all cached products (for debugging/UI purposes).
    func allCached() -> [CachedProduct] {
        Array(cache.values).sorted { $0.timestamp > $1.timestamp }
    }
    
    // MARK: - Private Helpers
    
    private func normalizeKey(_ ingredient: String) -> String {
        ingredient
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
    }
    
    private static func loadFromDisk(cacheKey: String) -> [String: CachedProduct] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([String: CachedProduct].self, from: data) else {
            return [:]
        }
        
        // Filter out entries older than 30 days
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        return decoded.filter { $0.value.timestamp > thirtyDaysAgo }
    }
    
    private func saveToDisk() {
        guard let encoded = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(encoded, forKey: cacheKey)
    }
}

// MARK: - StoreOffer to CachedProduct Conversion

extension IngredientProductCache.CachedProduct {
    
    /// Converts a cached product back to a StoreOffer for display.
    func toStoreOffer() -> StockAvailability.StoreOffer? {
        guard let productURL = URL(string: self.productURL) else { return nil }
        
        let coordinate: CLLocationCoordinate2D? = {
            guard let lat = storeLatitude, let lon = storeLongitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }()
        
        return StockAvailability.StoreOffer(
            store: store,
            productURL: productURL,
            currencyCode: currencyCode,
            price: price,
            promoText: nil,
            isProbablyMatch: true,
            storeCoordinate: coordinate,
            distanceMeters: nil,
            productTitle: productTitle,
            imageURL: imageURL.flatMap { URL(string: $0) },
            detailsText: nil
        )
    }
}
