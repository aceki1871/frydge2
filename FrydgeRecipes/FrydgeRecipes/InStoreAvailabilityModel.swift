//
//  InStoreAvailabilityModel.swift
//  FrydgeRecipes
//
//  Per-item "can I get this at the store I'm in?" state for the shopping
//  list screen. ShoppingListView already fetches every chain's offers for
//  each item (Mine and shared); this keeps the full set instead of just the
//  cheapest, runs the resolver against the active `InStoreSession`, and
//  publishes one answer per item id.
//
//  Also writes a small app-group snapshot of the greyed-out item names so
//  ActivityManager can grey the same rows in the Live Activity without
//  redoing any of the lookups.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class InStoreAvailabilityModel: ObservableObject {

    private struct OfferSet {
        let name: String
        let offers: [StockAvailability.StoreOffer]
        let usedPreferredShortcut: Bool
    }

    /// Resolved availability per shopping item id (Mine and shared), for the
    /// chain in the current session. Empty when no session is active.
    @Published private(set) var availability: [UUID: StoreAvailability] = [:]

    private var offerSets: [UUID: OfferSet] = [:]
    private let overrides = StoreAvailabilityOverrides.shared

    // MARK: - Feeding offers

    /// Records the full offer set for an item. Call once per item each time
    /// its store lookup completes.
    func record(id: UUID, name: String, offers: [StockAvailability.StoreOffer], usedPreferredShortcut: Bool) {
        offerSets[id] = OfferSet(name: name, offers: offers, usedPreferredShortcut: usedPreferredShortcut)
        scheduleRecompute()
    }

    /// Lookups for a whole list land within a few hundred milliseconds of
    /// each other. Recomputing on every arrival resolved every item (and
    /// rewrote the app-group snapshot) once per item, so coalesce the burst
    /// into a single pass.
    private var recomputeScheduled = false

    private func scheduleRecompute() {
        guard !recomputeScheduled else { return }
        recomputeScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            self.recomputeScheduled = false
            self.recompute()
        }
    }

    /// Forgets every offer set (the screen is about to refetch).
    func reset() {
        offerSets.removeAll()
        availability.removeAll()
        writeSnapshot(chainKey: nil, unavailableNames: [])
    }

    // MARK: - Resolving

    func recompute() {
        guard let store = InStoreSession.shared.current else {
            if !availability.isEmpty { availability.removeAll() }
            writeSnapshot(chainKey: nil, unavailableNames: [])
            return
        }

        var next: [UUID: StoreAvailability] = [:]
        next.reserveCapacity(offerSets.count)
        var unavailableNames: Set<String> = []

        for (id, set) in offerSets {
            let result = StoreAvailabilityResolver.resolve(
                itemName: set.name,
                chainKey: store.chainKey,
                offers: set.offers,
                offersCameFromPreferredShortcut: set.usedPreferredShortcut,
                receipts: ObservedPriceStore.shared.matches(for: set.name),
                override: overrides.value(for: set.name, chain: store.chainKey)
            )
            next[id] = result
            if result.isGreyed {
                unavailableNames.insert(StoreAvailabilityResolver.normalizedItemKey(set.name))
            }
        }

        availability = next
        writeSnapshot(chainKey: store.chainKey, unavailableNames: Array(unavailableNames).sorted())
    }

    // MARK: - Reading

    var isActive: Bool { InStoreSession.shared.current != nil }

    func availability(for id: UUID) -> StoreAvailability? {
        availability[id]
    }

    /// True only while a store session is active and this item resolved as
    /// not sold there.
    func isGreyed(_ id: UUID) -> Bool {
        availability[id]?.isGreyed ?? false
    }

    func isUnsure(_ id: UUID) -> Bool {
        availability[id]?.isUnsure ?? false
    }

    /// "9 of 12 here" style counts for a set of item ids.
    func counts(for ids: [UUID]) -> (here: Int, notHere: Int, total: Int) {
        var notHere = 0
        for id in ids where isGreyed(id) { notHere += 1 }
        return (ids.count - notHere, notHere, ids.count)
    }

    /// Stable partition: keeps the caller's order but moves greyed rows to
    /// the end, so the walk-round-the-shop order survives for the items you
    /// can actually get.
    func sinkingGreyed<T: Identifiable>(_ items: [T]) -> [T] where T.ID == UUID {
        guard isActive, !availability.isEmpty else { return items }
        var front: [T] = []
        var back: [T] = []
        for item in items {
            if isGreyed(item.id) { back.append(item) } else { front.append(item) }
        }
        return front + back
    }

    // MARK: - User corrections

    /// Swipe "Not here" (false) / "They have it" (true) for the current chain.
    func setOverride(_ available: Bool, itemName: String) {
        guard let store = InStoreSession.shared.current else { return }
        overrides.set(available, for: itemName, chain: store.chainKey)
        recompute()
    }

    func clearOverride(itemName: String) {
        guard let store = InStoreSession.shared.current else { return }
        overrides.clear(for: itemName, chain: store.chainKey)
        recompute()
    }

    func hasOverride(itemName: String) -> Bool {
        guard let store = InStoreSession.shared.current else { return false }
        return overrides.value(for: itemName, chain: store.chainKey) != nil
    }

    // MARK: - Live Activity handoff

    private func writeSnapshot(chainKey: String?, unavailableNames: [String]) {
        InStoreAvailabilitySnapshot.write(chainKey.map {
            InStoreAvailabilitySnapshot(chainKey: $0, unavailableNames: unavailableNames, updatedAt: Date())
        })
    }
}

// MARK: - Snapshot shared with ActivityManager

/// What the shopping list concluded about the current chain, stored in the
/// app group so the Live Activity can grey the same items. Names are
/// `StoreAvailabilityResolver.normalizedItemKey` values.
struct InStoreAvailabilitySnapshot: Codable, Equatable {
    var chainKey: String
    var unavailableNames: [String]
    var updatedAt: Date

    nonisolated static let appGroupName = "group.Clark-Online.FrydgeRecipeAPN"
    nonisolated static let storageKey = "inStoreAvailability.v1"

    nonisolated private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupName) ?? .standard
    }

    nonisolated static func read() -> InStoreAvailabilitySnapshot? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(InStoreAvailabilitySnapshot.self, from: data)
    }

    nonisolated static func write(_ snapshot: InStoreAvailabilitySnapshot?) {
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
        }
    }
}

// MARK: - Shared in-store UI pieces

/// The row-level treatment for an item the current store doesn't sell:
/// faded and desaturated, still tappable.
struct InStoreGreyedModifier: ViewModifier {
    let isGreyed: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isGreyed ? 0.4 : 1)
            .saturation(isGreyed ? 0.2 : 1)
            .animation(.easeInOut(duration: 0.25), value: isGreyed)
    }
}

extension View {
    func inStoreGreyed(_ isGreyed: Bool) -> some View {
        modifier(InStoreGreyedModifier(isGreyed: isGreyed))
    }
}

/// Caption under an item name replacing the price line while in a store.
struct InStoreAvailabilityCaption: View {
    let availability: StoreAvailability
    let chainName: String

    var body: some View {
        switch availability {
        case .unavailable:
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 10))
                Text("Not at \(chainName)")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        case .unknown:
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10))
                Text("Unsure \(chainName) has this")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        case .likely, .confirmed:
            EmptyView()
        }
    }
}

/// Top-of-list card while a store session is active.
struct InStoreBanner: View {
    let store: InStoreSession.ActiveStore
    let here: Int
    let notHere: Int
    /// Location normally ends an arrival session on its own. The button is
    /// only for manual picks, or when we have no location to go on.
    var showsLeave: Bool = true
    let onLeave: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            StoreBranding.logo(for: store.storeName)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.source == .manual ? "Shopping at" : "You're at")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(store.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(summaryLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if showsLeave {
                Button("Leave", action: onLeave)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .notepadGlass(cornerRadius: 18)
        .padding(.horizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var summaryLine: String {
        let total = here + notHere
        if total == 0 { return "Nothing on the list yet" }
        if notHere == 0 { return "All \(total) item\(total == 1 ? "" : "s") here" }
        return "\(here) of \(total) here · \(notHere) not here"
    }
}
