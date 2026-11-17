//
//  StoreAvailabilityResolver.swift
//  FrydgeRecipes
//
//  Decides whether a shopping-list item can be bought at the chain the
//  shopper is standing in. Pure: everything it needs is passed in, so it's
//  unit-tested without network or stores.
//
//  Signals, strongest first:
//    1. The user said so (swipe "Not here" / "They have it").
//    2. A receipt from this chain lists the item (recent).
//    3. The price worker returned an offer from this chain.
//    4. The worker returned offers for OTHER chains only → this chain doesn't
//       list it… unless it's a staple, which every supermarket stocks even
//       when the worker's product search misses it.
//    5. No data at all → staple ? likely : unknown.
//
//  Caveat on (4): `StockAvailability.fetchOffers` short-circuits to a single
//  user-preferred product when one is saved, which would make every other
//  chain look like it doesn't stock the item. Callers pass
//  `offersCameFromPreferredShortcut` so the resolver can refuse to draw
//  that conclusion.
//

import Foundation
import Combine

enum StoreAvailability: Equatable {
    enum Source: Equatable {
        case receipt
        case price
        case user
    }

    case confirmed(Source)
    /// Generic grocery at a supermarket chain: assumed on the shelf.
    case likely
    /// This chain doesn't list it (or the user said it doesn't). Grey it out.
    case unavailable
    /// Nothing to go on. Shown normally with an "unsure" hint.
    case unknown

    var isGreyed: Bool { self == .unavailable }
    var isUnsure: Bool { self == .unknown }
}

enum StoreAvailabilityResolver {

    /// Receipts older than this no longer prove a chain still stocks something.
    static let receiptLookback: TimeInterval = 180 * 24 * 60 * 60

    static func resolve(
        itemName: String,
        chainKey: String,
        offers: [StockAvailability.StoreOffer],
        offersCameFromPreferredShortcut: Bool,
        receipts: [ObservedPrice],
        override: Bool?,
        now: Date = Date()
    ) -> StoreAvailability {
        // 1. User correction wins outright.
        if let override {
            return override ? .confirmed(.user) : .unavailable
        }

        // 2. Bought it here before (recently).
        let recentHere = receipts.contains { record in
            guard let store = record.store, !store.isEmpty else { return false }
            guard now.timeIntervalSince(record.date) <= receiptLookback else { return false }
            return StoreChain.key(for: store) == chainKey
        }
        if recentHere { return .confirmed(.receipt) }

        // 3. The worker lists it at this chain.
        let listedHere = offers.contains { StoreChain.key(for: $0.store) == chainKey }
        if listedHere { return .confirmed(.price) }

        let staple = isStaple(itemName: itemName, chainKey: chainKey)

        // 4. Listed elsewhere but not here — a real negative, unless the
        //    offer set was collapsed to one preferred product.
        if !offers.isEmpty, !offersCameFromPreferredShortcut {
            return staple ? .likely : .unavailable
        }

        // 5. No usable data.
        return staple ? .likely : .unknown
    }

    /// A staple is a generic food the recipe-matching lexicon recognises
    /// ("milk", "onions", "chicken thighs"), at a chain that carries a full
    /// grocery range. Every meaningful word has to be a known food word:
    /// "Anchor Milk" and "Whittaker's Peanut Slab" contain a food but are a
    /// specific product, so they stay `unknown` until a price, a receipt or
    /// the shopper confirms the chain carries them.
    static func isStaple(itemName: String, chainKey: String) -> Bool {
        guard StoreChain.isSupermarket(chainKey) else { return false }
        guard IngredientMatcher.category(for: itemName) != nil else { return false }

        // `tokens` already drops quantities, units and noise words and
        // normalises spelling/synonyms, so what's left is brand words and
        // food words. Any token the lexicon can't place marks a brand.
        let tokens = IngredientMatcher.tokens(itemName)
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { token in
            IngredientMatcher.entry(for: token) != nil
                || IngredientMatcher.derivedFood(token) != nil
        }
    }

    /// Lowercased, punctuation stripped, whitespace collapsed. Shared by the
    /// override store and the Live Activity handoff so keys always agree.
    static func normalizedItemKey(_ name: String) -> String {
        name.lowercased()
            .folding(options: [.diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - User corrections

/// "Not here" / "They have it" swipes, keyed by chain + item so a correction
/// made on a shared list applies to the same item on Mine and vice versa.
/// App-group backed so the Live Activity handoff sees them too.
@MainActor
final class StoreAvailabilityOverrides: ObservableObject {

    static let shared = StoreAvailabilityOverrides()

    nonisolated static let appGroupName = "group.Clark-Online.FrydgeRecipeAPN"
    nonisolated static let storageKey = "storeAvailabilityOverrides.v1"

    @Published private(set) var values: [String: Bool] = [:]

    private init() {
        values = Self.loadPersisted()
    }

    nonisolated static func key(itemName: String, chain: String) -> String {
        "\(chain)|\(StoreAvailabilityResolver.normalizedItemKey(itemName))"
    }

    func value(for itemName: String, chain: String) -> Bool? {
        values[Self.key(itemName: itemName, chain: chain)]
    }

    func set(_ available: Bool, for itemName: String, chain: String) {
        values[Self.key(itemName: itemName, chain: chain)] = available
        persist()
    }

    func clear(for itemName: String, chain: String) {
        values.removeValue(forKey: Self.key(itemName: itemName, chain: chain))
        persist()
    }

    // MARK: Persistence

    nonisolated private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupName) ?? .standard
    }

    nonisolated static func loadPersisted() -> [String: Bool] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func persist() {
        let snapshot = values
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            Self.defaults.set(data, forKey: Self.storageKey)
        }
    }
}
