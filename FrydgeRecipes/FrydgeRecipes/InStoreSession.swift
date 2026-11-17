//
//  InStoreSession.swift
//  FrydgeRecipes
//
//  The single answer to "which shop is Josh in right now?". Set when a
//  geofence fires, when the arrival notification is tapped, or when a chain
//  is picked by hand in Profile. Read by the shopping list (to grey out items
//  this chain doesn't sell), the basket, and ActivityManager (so the Live
//  Activity greys the same items even when the app was woken in the
//  background for the geofence).
//
//  Persisted in the app group so every reader sees the same store. Arrival
//  sessions lapse after a few hours — nobody is in Pak'nSave all day — while
//  a manual pick stays until it's cleared.
//

import Foundation
import Combine
import CoreLocation

@MainActor
final class InStoreSession: ObservableObject {

    static let shared = InStoreSession()

    enum Source: String, Codable {
        case geofence
        case notification
        case manual
    }

    struct ActiveStore: Codable, Equatable {
        /// Full name as monitored ("Woolworths Mt Wellington"), or the chain
        /// display name for a manual pick ("Pak’nSave").
        var storeName: String
        /// `StoreChain.key(for: storeName)`, cached so readers don't re-derive.
        var chainKey: String
        var source: Source
        var startedAt: Date

        /// Heading-friendly name: branch when we have it, chain otherwise.
        var displayName: String { storeName }
        var chainDisplayName: String { StoreChain.shortName(for: storeName) }
    }

    /// How long an arrival-triggered session is trusted before it's dropped.
    nonisolated static let arrivalLifetime: TimeInterval = 3 * 60 * 60

    nonisolated static let appGroupName = "group.Clark-Online.FrydgeRecipeAPN"
    nonisolated static let storageKey = "inStoreSession.v1"

    @Published private(set) var current: ActiveStore?

    var isActive: Bool { current != nil }
    var chainKey: String? { current?.chainKey }
    var storeName: String? { current?.storeName }

    private init() {
        current = Self.loadPersisted()
    }

    // MARK: - Mutations

    /// Starts (or retargets) the session. A new store replaces the old one so
    /// the session follows the shopper from shop to shop, the same way the
    /// Live Activity does. Empty names are ignored.
    func begin(storeName rawName: String, source: Source) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let store = ActiveStore(
            storeName: name,
            chainKey: StoreChain.key(for: name),
            source: source,
            startedAt: Date()
        )
        current = store
        Self.persist(store)
        print("[INSTORE] Session began: \(name) (\(store.chainKey)) via \(source.rawValue)")
    }

    /// Clears the session: finished the shop, tapped "Leave", or picked
    /// "Not shopping" in Profile.
    func end() {
        guard current != nil else { return }
        current = nil
        Self.persist(nil)
        print("[INSTORE] Session ended")
    }

    /// Drops an arrival session that has run past its lifetime. Call when a
    /// screen that shows store-specific UI appears.
    func refreshExpiry(now: Date = Date()) {
        guard let store = current, Self.isExpired(store, now: now) else { return }
        print("[INSTORE] Session for \(store.storeName) expired — clearing")
        current = nil
        Self.persist(nil)
    }

    // MARK: - Leaving by location

    /// A geofence exit (or an "outside" state answer) for the store we're
    /// shopping in ends the session, so the user never has to tap Leave.
    /// Manual picks are left alone: location can't know what the user meant.
    func endIfOutside(regionIdentifier: String) {
        guard let store = current, Self.leavesSession(store, exitedRegion: regionIdentifier) else { return }
        print("[INSTORE] Left \(store.storeName) — ending session")
        current = nil
        Self.persist(nil)
    }

    /// Ends an arrival session once a fresh fix puts the user well clear of
    /// the store. Covers When-In-Use installs, where iOS won't deliver a
    /// geofence exit while the app is closed, so the next time the shopping
    /// list has a location it can tidy up.
    func endIfLeft(location: CLLocation) {
        guard let store = current, store.source != .manual,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= Self.maxExitFixAccuracy,
              let coordinate = Self.coordinate(forStoreNamed: store.storeName) else { return }
        let distance = location.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        guard Self.hasLeft(distanceFromStore: distance) else { return }
        print("[INSTORE] \(Int(distance))m from \(store.storeName) — ending session")
        current = nil
        Self.persist(nil)
    }

    /// Beyond this distance from the store the shopper has clearly left.
    /// Wider than the arrival geofence so a fix wobbling near the boundary
    /// can't end a shop that's still going.
    nonisolated static let exitDistance: CLLocationDistance = RegionMonitoring.regionRadius + 400
    /// Fixes coarser than this can't place the user relative to the store.
    nonisolated static let maxExitFixAccuracy: CLLocationAccuracy = 300

    private static func coordinate(forStoreNamed name: String) -> CLLocationCoordinate2D? {
        guard let store = RegionMonitoring.allStores.first(where: { $0.name == name }) else { return nil }
        return CLLocationCoordinate2D(latitude: store.latitude, longitude: store.longitude)
    }

    // MARK: - Pure helpers (tested)

    nonisolated static func isExpired(_ store: ActiveStore, now: Date) -> Bool {
        switch store.source {
        case .manual:
            return false
        case .geofence, .notification:
            return now.timeIntervalSince(store.startedAt) > arrivalLifetime
        }
    }

    nonisolated static func leavesSession(_ store: ActiveStore, exitedRegion identifier: String) -> Bool {
        store.source != .manual && store.storeName == identifier
    }

    nonisolated static func hasLeft(distanceFromStore distance: CLLocationDistance) -> Bool {
        distance > exitDistance
    }

    // MARK: - Persistence (app group)

    nonisolated private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupName) ?? .standard
    }

    /// Reads the persisted session, discarding it if expired. Safe to call
    /// off the main actor (ActivityManager uses it).
    nonisolated static func loadPersisted(now: Date = Date()) -> ActiveStore? {
        guard let data = defaults.data(forKey: storageKey),
              let store = try? JSONDecoder().decode(ActiveStore.self, from: data) else {
            return nil
        }
        return isExpired(store, now: now) ? nil : store
    }

    nonisolated private static func persist(_ store: ActiveStore?) {
        if let store, let data = try? JSONEncoder().encode(store) {
            defaults.set(data, forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
        }
    }
}
