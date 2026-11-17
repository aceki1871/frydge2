//
//  StandaloneBasketSheet.swift
//  FrydgeRecipes
//
//  Presents the in-store basket on its own, straight from the fridge screen,
//  without routing through the Shopping List tab. It reads the list from
//  `ShoppingListManager` directly (already in memory), so it opens instantly
//  and never waits on the shopping list screen's cloud/store refreshes.
//
//  Ticks are local until the user taps "Add N to Fridge"; the Shopping List
//  screen remains the place for the full price-driven list.
//

import SwiftUI

struct StandaloneBasketSheet: View {
    @EnvironmentObject private var shoppingListManager: ShoppingListManager
    @State private var checkedItems: Set<UUID> = []

    private var items: [ShoppingListItem] { shoppingListManager.shoppingListItems }

    var body: some View {
        ShoppingBasketSheet(
            items: items,
            offers: [:],
            totalText: totalText,
            checkedItems: $checkedItems,
            onToggle: toggle
        )
        .onChange(of: items.map(\.id)) { _, ids in
            // Drop ticks for items removed elsewhere (e.g. by a sync).
            checkedItems = checkedItems.intersection(ids)
        }
    }

    private func toggle(_ item: ShoppingListItem) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if checkedItems.contains(item.id) {
                checkedItems.remove(item.id)
            } else {
                checkedItems.insert(item.id)
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Instant estimate from prices the user has actually paid (receipts).
    /// Prefixed with "~" when only some items have a known price.
    private var totalText: String {
        guard !items.isEmpty else { return "Basket empty" }
        var total = 0.0
        var priced = 0
        for item in items {
            if let paid = ObservedPriceStore.shared.latest(for: item.name) {
                total += paid.price
                priced += 1
            }
        }
        guard priced > 0 else {
            return "\(items.count) item\(items.count == 1 ? "" : "s")"
        }
        let text = String(format: "$%.2f", total)
        return priced < items.count ? "~\(text)" : text
    }
}
