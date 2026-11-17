//
//  StoreAvailabilityTests.swift
//  FrydgeRecipes Tests
//
//  Chain-key normalisation, the in-store availability resolver, and
//  in-store session expiry.
//

import Testing
import Foundation
import CoreLocation
@testable import FrydgeRecipes

// MARK: - StoreChain

@Suite("StoreChain keys")
struct StoreChainTests {

    @Test("Countdown and Woolworths share a key")
    func countdownIsWoolworths() {
        #expect(StoreChain.key(for: "Countdown Glenfield") == "woolworths")
        #expect(StoreChain.key(for: "Woolworths Mt Wellington") == "woolworths")
        #expect(StoreChain.key(for: "woolies") == "woolworths")
    }

    @Test("Pak'nSave spellings collapse")
    func paknsaveVariants() {
        #expect(StoreChain.key(for: "Pak’nSave Sylvia Park") == "paknsave")
        #expect(StoreChain.key(for: "PAK'nSAVE") == "paknsave")
        #expect(StoreChain.key(for: "pak n save") == "paknsave")
    }

    @Test("Unknown chains fall back to the first word")
    func unknownFallsBack() {
        #expect(StoreChain.key(for: "Bin Inn Ponsonby") == "bin")
    }

    @Test("Supermarket set excludes pharmacies")
    func supermarketSet() {
        #expect(StoreChain.isSupermarket("woolworths"))
        #expect(StoreChain.isSupermarket("tesco"))
        #expect(!StoreChain.isSupermarket("chemist"))
    }

    @Test("Short names")
    func shortNames() {
        #expect(StoreChain.shortName(for: "Countdown Glenfield") == "Countdown")
        #expect(StoreChain.shortName(for: "Woolworths Mt Wellington") == "Woolworths")
        #expect(StoreChain.shortName(for: "Some Dairy") == "Some Dairy")
    }
}

// MARK: - Resolver

@Suite("StoreAvailabilityResolver")
struct StoreAvailabilityResolverTests {

    private func offer(_ store: String, price: Double = 4.5) -> StockAvailability.StoreOffer {
        StockAvailability.StoreOffer(
            store: store,
            productURL: URL(string: "https://example.com/p")!,
            currencyCode: "NZD",
            price: price,
            promoText: nil,
            isProbablyMatch: true,
            storeCoordinate: nil,
            distanceMeters: nil,
            productTitle: "Test product",
            imageURL: nil,
            detailsText: nil
        )
    }

    private func receipt(_ store: String?, daysAgo: Double) -> ObservedPrice {
        ObservedPrice(
            name: "Test",
            normalizedKey: "test",
            price: 3.0,
            store: store,
            date: Date().addingTimeInterval(-daysAgo * 86_400),
            promoText: nil
        )
    }

    @Test("User override wins over everything")
    func overrideWins() {
        let yes = StoreAvailabilityResolver.resolve(
            itemName: "Milk", chainKey: "paknsave",
            offers: [offer("Woolworths")], offersCameFromPreferredShortcut: false,
            receipts: [], override: true
        )
        #expect(yes == .confirmed(.user))

        let no = StoreAvailabilityResolver.resolve(
            itemName: "Milk", chainKey: "paknsave",
            offers: [offer("Pak'nSave")], offersCameFromPreferredShortcut: false,
            receipts: [receipt("Pak'nSave Royal Oak", daysAgo: 1)], override: false
        )
        #expect(no == .unavailable)
    }

    @Test("Recent receipt from this chain confirms")
    func receiptConfirms() {
        let result = StoreAvailabilityResolver.resolve(
            itemName: "Whittaker's Peanut Slab", chainKey: "woolworths",
            offers: [], offersCameFromPreferredShortcut: false,
            receipts: [receipt("Countdown Glenfield", daysAgo: 10)], override: nil
        )
        #expect(result == .confirmed(.receipt))
    }

    @Test("Old receipt no longer confirms")
    func staleReceiptIgnored() {
        let result = StoreAvailabilityResolver.resolve(
            itemName: "Whittaker's Peanut Slab", chainKey: "woolworths",
            offers: [], offersCameFromPreferredShortcut: false,
            receipts: [receipt("Countdown Glenfield", daysAgo: 400)], override: nil
        )
        #expect(result == .unknown)
    }

    @Test("Worker offer from this chain confirms")
    func offerConfirms() {
        let result = StoreAvailabilityResolver.resolve(
            itemName: "Whittaker's Peanut Slab", chainKey: "paknsave",
            offers: [offer("Woolworths"), offer("PAK'nSAVE")], offersCameFromPreferredShortcut: false,
            receipts: [], override: nil
        )
        #expect(result == .confirmed(.price))
    }

    @Test("Other chains only: branded item is unavailable, staple is likely")
    func otherChainsOnly() {
        let branded = StoreAvailabilityResolver.resolve(
            itemName: "Whittaker's Peanut Slab", chainKey: "paknsave",
            offers: [offer("Woolworths"), offer("New World")], offersCameFromPreferredShortcut: false,
            receipts: [], override: nil
        )
        #expect(branded == .unavailable)

        let staple = StoreAvailabilityResolver.resolve(
            itemName: "Milk", chainKey: "paknsave",
            offers: [offer("Woolworths")], offersCameFromPreferredShortcut: false,
            receipts: [], override: nil
        )
        #expect(staple == .likely)
    }

    @Test("Preferred-product shortcut never produces unavailable")
    func shortcutIsNotANegative() {
        let result = StoreAvailabilityResolver.resolve(
            itemName: "Whittaker's Peanut Slab", chainKey: "paknsave",
            offers: [offer("Woolworths")], offersCameFromPreferredShortcut: true,
            receipts: [], override: nil
        )
        #expect(result == .unknown)
    }

    @Test("No data: staple likely, otherwise unknown")
    func noData() {
        let staple = StoreAvailabilityResolver.resolve(
            itemName: "Eggs", chainKey: "woolworths",
            offers: [], offersCameFromPreferredShortcut: false,
            receipts: [], override: nil
        )
        #expect(staple == .likely)

        let odd = StoreAvailabilityResolver.resolve(
            itemName: "Zxqv widget", chainKey: "woolworths",
            offers: [], offersCameFromPreferredShortcut: false,
            receipts: [], override: nil
        )
        #expect(odd == .unknown)
    }

    @Test("Branded products are not staples")
    func brandedNotStaple() {
        #expect(StoreAvailabilityResolver.isStaple(itemName: "Milk 2L", chainKey: "woolworths"))
        #expect(StoreAvailabilityResolver.isStaple(itemName: "Chicken thighs", chainKey: "woolworths"))
        #expect(!StoreAvailabilityResolver.isStaple(itemName: "Anchor Milk 2L", chainKey: "woolworths"))
        #expect(!StoreAvailabilityResolver.isStaple(itemName: "Whittaker's Peanut Slab", chainKey: "woolworths"))
        #expect(!StoreAvailabilityResolver.isStaple(itemName: "Tim Tams", chainKey: "woolworths"))
    }

    @Test("Staples are not assumed at non-supermarkets")
    func stapleNeedsSupermarket() {
        let result = StoreAvailabilityResolver.resolve(
            itemName: "Milk", chainKey: "chemist",
            offers: [], offersCameFromPreferredShortcut: false,
            receipts: [], override: nil
        )
        #expect(result == .unknown)
    }

    @Test("Normalised item key")
    func normalisedKey() {
        #expect(StoreAvailabilityResolver.normalizedItemKey("  Anchor™ Milk, 2L ") == "anchor milk 2l")
        #expect(StoreAvailabilityOverrides.key(itemName: "Milk", chain: "paknsave") == "paknsave|milk")
    }
}

// MARK: - Session expiry

@Suite("InStoreSession expiry")
struct InStoreSessionExpiryTests {

    private func store(_ source: InStoreSession.Source, ageHours: Double) -> InStoreSession.ActiveStore {
        InStoreSession.ActiveStore(
            storeName: "Woolworths Mt Wellington",
            chainKey: "woolworths",
            source: source,
            startedAt: Date().addingTimeInterval(-ageHours * 3600)
        )
    }

    @Test("Geofence session lapses after the lifetime")
    func geofenceExpires() {
        #expect(!InStoreSession.isExpired(store(.geofence, ageHours: 2.5), now: Date()))
        #expect(InStoreSession.isExpired(store(.geofence, ageHours: 3.5), now: Date()))
    }

    @Test("Notification session lapses the same way")
    func notificationExpires() {
        #expect(InStoreSession.isExpired(store(.notification, ageHours: 4), now: Date()))
    }

    @Test("Manual pick never lapses")
    func manualNeverExpires() {
        #expect(!InStoreSession.isExpired(store(.manual, ageHours: 48), now: Date()))
    }
}

// MARK: - Offer cache location key

@Suite("StockAvailability location cache key")
struct StockAvailabilityLocationKeyTests {

    @Test("Nearby fixes share a key")
    func nearbyFixesShareKey() {
        // Woolworths Mt Wellington and a point ~300 m across the car park.
        let a = CLLocationCoordinate2D(latitude: -36.9105, longitude: 174.8396)
        let b = CLLocationCoordinate2D(latitude: -36.9120, longitude: 174.8410)
        #expect(StockAvailability.locationCacheKey(for: a) == StockAvailability.locationCacheKey(for: b))
    }

    @Test("Distant fixes get different keys")
    func distantFixesDiffer() {
        let mtWellington = CLLocationCoordinate2D(latitude: -36.9105, longitude: 174.8396)
        let glenfield = CLLocationCoordinate2D(latitude: -36.7800, longitude: 174.7230)
        #expect(StockAvailability.locationCacheKey(for: mtWellington) != StockAvailability.locationCacheKey(for: glenfield))
    }

    @Test("No location has a stable key")
    func noLocation() {
        #expect(StockAvailability.locationCacheKey(for: nil) == "n/a")
    }
}
