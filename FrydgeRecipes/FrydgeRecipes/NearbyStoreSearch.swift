//  NearbyStoreSearch.swift
//  FrydgeRecipes
//
//  Live supermarket discovery via Apple Maps.
//
//  The hand-maintained store directory (`LocationManager.predefinedStores` and
//  `RegionMonitoring.stores`) only covers Auckland plus two small UK pockets.
//  Anyone outside those areas used to be shown a "nearest" store that could be
//  hundreds of kilometres away. This type asks MapKit for grocery points of
//  interest around the user and merges them with the directory, so the map,
//  store list, widget readout and geofences all work wherever the user is.
//
//  The directory stays as the seed and offline fallback: live results never
//  replace a directory entry, they only fill in the gaps around it.

import Foundation
import CoreLocation
import MapKit

enum NearbyStoreSearch {

    // MARK: - Tuning

    /// How far around the user to look for stores.
    static let searchRadius: CLLocationDistance = 8_000

    /// Re-run the search once the user has moved this far from the last search centre.
    static let refreshDistance: CLLocationDistance = 2_000

    /// Re-run the search once the cached results are older than this.
    static let refreshInterval: TimeInterval = 30 * 60

    /// Minimum gap between two live search attempts, so a failed (offline) search
    /// does not re-fire on every 25 m location update.
    static let retryInterval: TimeInterval = 2 * 60

    /// Two same-brand stores closer than this are treated as the same shop.
    static let duplicateDistance: CLLocationDistance = 120

    /// MapKit does not expose opening hours, so live results carry the same
    /// placeholder the directory already uses for unknown hours.
    static let placeholderHours = "Check in-store for current hours"

    /// Natural-language queries run against Apple Maps. Each is restricted to the
    /// `.foodMarket` point-of-interest category, so cafés and restaurants that
    /// happen to match the words are filtered out.
    private static let queries = ["supermarket", "grocery store"]

    // MARK: - Search

    /// Looks up grocery stores around `center` and returns them as `Store` values,
    /// nearest first. Returns an empty array when offline or when MapKit has
    /// nothing for the area.
    static func search(around center: CLLocation,
                       radius: CLLocationDistance = searchRadius) async -> [Store] {
        var found: [Store] = []

        for query in queries {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = MKCoordinateRegion(center: center.coordinate,
                                                latitudinalMeters: radius * 2,
                                                longitudinalMeters: radius * 2)
            request.resultTypes = .pointOfInterest
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.foodMarket])
            request.regionPriority = .required

            // MapKit throws for "no results"; treat that the same as an empty page.
            guard let response = try? await MKLocalSearch(request: request).start() else { continue }

            for item in response.mapItems {
                guard let store = store(from: item) else { continue }
                // `regionPriority = .required` is a strong hint, not a guarantee.
                guard center.distance(from: location(of: store)) <= radius * 1.5 else { continue }
                found.append(store)
            }
        }

        let unique = deduplicated(found)
        return unique.sorted {
            center.distance(from: location(of: $0)) < center.distance(from: location(of: $1))
        }
    }

    /// Maps an Apple Maps result onto the app's `Store` model.
    private static func store(from item: MKMapItem) -> Store? {
        guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }

        let coordinate = item.location.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

        // Prefer the compact "street, town" form; fall back to the full address
        // flattened onto one line so it reads like the directory's `vicinity`.
        let vicinity: String
        if let short = item.address?.shortAddress, !short.isEmpty {
            vicinity = short
        } else if let full = item.address?.fullAddress {
            vicinity = full
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        } else {
            vicinity = ""
        }

        return Store(name: name,
                     vicinity: vicinity,
                     latitude: coordinate.latitude,
                     longitude: coordinate.longitude,
                     storehours: placeholderHours,
                     phoneNumber: item.phoneNumber,
                     website: item.url?.absoluteString ?? "")
    }

    // MARK: - Merging

    /// Directory entries first (untouched), then any live store that is not
    /// already represented by a same-brand directory entry at the same spot.
    static func merge(directory: [Store], live: [Store]) -> [Store] {
        var result = directory
        for store in live where !result.contains(where: { isSamePlace($0, store) }) {
            result.append(store)
        }
        return result
    }

    /// Collapses results that the two queries both returned.
    private static func deduplicated(_ stores: [Store]) -> [Store] {
        var result: [Store] = []
        for store in stores where !result.contains(where: { isSamePlace($0, store) }) {
            result.append(store)
        }
        return result
    }

    /// Same brand within `duplicateDistance` counts as the same physical shop.
    /// Brand matching stops a Lidl and a Tesco on the same retail park from
    /// collapsing into one pin.
    static func isSamePlace(_ a: Store, _ b: Store) -> Bool {
        guard location(of: a).distance(from: location(of: b)) <= duplicateDistance else { return false }
        return brandToken(a.name) == brandToken(b.name)
    }

    /// First meaningful word of a store name, lower-cased and stripped of
    /// punctuation, with a few known rebrands folded together.
    static func brandToken(_ name: String) -> String {
        let words = name.lowercased().split(separator: " ").map(String.init)
        var first = words.first ?? ""
        if first == "the", words.count > 1 { first = words[1] }
        let token = first.filter { $0.isLetter || $0.isNumber }

        switch token {
        case "woolworths", "countdown", "metro": return "countdown"
        case "marks", "ms": return "ms"
        case "pak", "paknsave": return "paknsave"
        case "coop", "cooperative": return "coop"
        default: return token
        }
    }

    private static func location(of store: Store) -> CLLocation {
        CLLocation(latitude: store.latitude, longitude: store.longitude)
    }

    // MARK: - Cache

    /// Last successful live search, kept in UserDefaults so the store list is
    /// populated immediately on launch and keeps working offline. Also read by
    /// `RegionMonitoring` so geofences can target live stores.
    struct CachedResult: Codable {
        var latitude: Double
        var longitude: Double
        var fetchedAt: Date
        var stores: [Store]

        var center: CLLocation {
            CLLocation(latitude: latitude, longitude: longitude)
        }
    }

    private static let cacheKey = "nearbyStoreSearch.cache.v1"
    private static let lastAttemptKey = "nearbyStoreSearch.lastAttempt"

    static func loadCache() -> CachedResult? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(CachedResult.self, from: data)
    }

    static func saveCache(stores: [Store], center: CLLocation) {
        let cached = CachedResult(latitude: center.coordinate.latitude,
                                  longitude: center.coordinate.longitude,
                                  fetchedAt: Date(),
                                  stores: stores)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    /// Live stores from the cache, or none if nothing has been fetched yet.
    static var cachedStores: [Store] {
        loadCache()?.stores ?? []
    }

    /// True when the cached results are recent and were fetched close to `location`.
    static func isCacheFresh(for location: CLLocation) -> Bool {
        guard let cache = loadCache() else { return false }
        return Date().timeIntervalSince(cache.fetchedAt) < refreshInterval
            && cache.center.distance(from: location) < refreshDistance
    }

    /// Records that a search was attempted, successful or not.
    static func markAttempt() {
        UserDefaults.standard.set(Date(), forKey: lastAttemptKey)
    }

    /// True when enough time has passed since the last attempt to try again.
    static var canAttempt: Bool {
        guard let last = UserDefaults.standard.object(forKey: lastAttemptKey) as? Date else { return true }
        return Date().timeIntervalSince(last) >= retryInterval
    }
}
