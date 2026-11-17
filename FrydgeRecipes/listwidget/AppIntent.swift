//
//  AppIntent.swift
//  listwidget
//
//  App Intents backing the interactive widget buttons and Control Center
//  controls. Background intents write into the shared widget snapshot; the
//  main app drains those changes on next foreground. Foreground intents just
//  open a deep link in the app.
//

import WidgetKit
import AppIntents
import Foundation

// MARK: - Tick off an item

/// Toggles a shopping list item ID in the widget snapshot's `tickedItemIDs` set.
/// The main app drains this set on foreground and removes matching items.
struct FrydgeWidgetTickItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Tick Shopping Item"
    static let description = IntentDescription("Mark a shopping list item as bought.")
    static let supportedModes: IntentModes = .background
    static let isDiscoverable: Bool = false

    @Parameter(title: "Item ID")
    var itemID: String

    init() {
        self.itemID = ""
    }

    init(itemID: String) {
        self.itemID = itemID
    }

    func perform() async throws -> some IntentResult {
        guard !itemID.isEmpty else { return .result() }

        WidgetSnapshot.mutate { snap in
            if snap.tickedItemIDs.contains(itemID) {
                snap.tickedItemIDs.remove(itemID)
            } else {
                snap.tickedItemIDs.insert(itemID)
            }
        }
        return .result()
    }
}

// MARK: - Adjust quantity

/// Queues a +1 / -1 quantity change for an item. Shown optimistically in the
/// widget and applied to the real list when the app next comes to the front.
struct FrydgeWidgetAdjustQuantityIntent: AppIntent {
    static let title: LocalizedStringResource = "Adjust Shopping Quantity"
    static let description = IntentDescription("Change how many of an item to buy.")
    static let supportedModes: IntentModes = .background
    static let isDiscoverable: Bool = false

    @Parameter(title: "Item ID")
    var itemID: String

    @Parameter(title: "Change")
    var delta: Int

    init() {
        self.itemID = ""
        self.delta = 0
    }

    init(itemID: String, delta: Int) {
        self.itemID = itemID
        self.delta = delta
    }

    func perform() async throws -> some IntentResult {
        guard !itemID.isEmpty, delta != 0 else { return .result() }

        WidgetSnapshot.mutate { snap in
            guard let item = snap.items.first(where: { $0.id == itemID }) else { return }
            let base = item.quantityValue ?? 1
            let current = snap.quantityAdjustments[itemID] ?? 0
            // Never let the effective quantity drop below one; use the tick
            // button to remove an item entirely.
            let proposed = base + Double(current + delta)
            guard proposed >= 1 else { return }
            let next = current + delta
            if next == 0 {
                snap.quantityAdjustments.removeValue(forKey: itemID)
            } else {
                snap.quantityAdjustments[itemID] = next
            }
        }
        return .result()
    }
}

// MARK: - Undo all ticks

/// Clears every tick queued from the widget (before the app has drained them).
struct FrydgeWidgetUntickAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Undo Widget Ticks"
    static let description = IntentDescription("Restore every item ticked off from the widget.")
    static let supportedModes: IntentModes = .background
    static let isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        WidgetSnapshot.mutate { snap in
            snap.tickedItemIDs.removeAll()
        }
        return .result()
    }
}

// MARK: - Open the app at a deep link

/// Opens the Frydge barcode scanner. Used by the Control Center control and
/// by widget buttons in families that don't support `Link`.
struct FrydgeOpenScannerIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan Barcode"
    static let description = IntentDescription("Opens the Frydge barcode scanner to add a product.")
    static let supportedModes: IntentModes = .foreground

    init() {}

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(WidgetDeepLink.scan))
    }
}

/// Opens the in-store basket (running total) in Frydge.
struct FrydgeOpenBasketIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Shopping Basket"
    static let description = IntentDescription("Opens the Frydge in-store basket with your running total.")
    static let supportedModes: IntentModes = .foreground

    init() {}

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(WidgetDeepLink.basket))
    }
}

/// Jumps to the shopping list tab in Frydge.
struct FrydgeOpenShoppingListIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Shopping List"
    static let description = IntentDescription("Opens your Frydge shopping list.")
    static let supportedModes: IntentModes = .foreground

    init() {}

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(WidgetDeepLink.shoppingList))
    }
}

/// Opens the add-product sheet in Frydge (search, no camera).
struct FrydgeOpenAddProductIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Shopping List"
    static let description = IntentDescription("Opens Frydge ready to add a product to your shopping list.")
    static let supportedModes: IntentModes = .foreground

    init() {}

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(WidgetDeepLink.addProduct))
    }
}
