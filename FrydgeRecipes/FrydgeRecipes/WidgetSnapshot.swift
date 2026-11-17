//
//  WidgetSnapshot.swift
//  FrydgeRecipes (main app copy)
//
//  Mirrored in FrydgeRecipes/listwidget/WidgetSnapshot.swift so the widget
//  extension target can compile its own copy. Keep both files in sync.
//

import Foundation
import WidgetKit

public struct WidgetSnapshot: Codable, Equatable {
    public static let appGroupID = "group.Clark-Online.FrydgeRecipeAPN"
    public static let defaultsKey = "frydgeWidgetSnapshotV1"

    public var nearestStoreName: String?
    public var nearestStoreDistanceText: String?
    public var items: [WidgetSnapshotItem]
    /// IDs the user has tapped to "tick off" from the widget. The main app drains
    /// this set on foreground, removing matching shopping list items.
    public var tickedItemIDs: Set<String>
    /// Pending quantity changes made from the widget's +/- buttons, keyed by
    /// item ID. The main app drains these on foreground and applies them to
    /// the real shopping list; until then the widget shows them optimistically.
    public var quantityAdjustments: [String: Int]
    /// `appleUserID` of the account whose list this snapshot (and its queued
    /// ticks/adjustments) belongs to. The app refuses to apply queued actions
    /// written under a different account after an iCloud account switch.
    public var ownerUserID: String?
    public var updatedAt: Date

    public init(
        nearestStoreName: String? = nil,
        nearestStoreDistanceText: String? = nil,
        items: [WidgetSnapshotItem] = [],
        tickedItemIDs: Set<String> = [],
        quantityAdjustments: [String: Int] = [:],
        ownerUserID: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.nearestStoreName = nearestStoreName
        self.nearestStoreDistanceText = nearestStoreDistanceText
        self.items = items
        self.tickedItemIDs = tickedItemIDs
        self.quantityAdjustments = quantityAdjustments
        self.ownerUserID = ownerUserID
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case nearestStoreName, nearestStoreDistanceText, items, tickedItemIDs, quantityAdjustments, ownerUserID, updatedAt
    }

    /// Lenient decode so snapshots written by older builds (missing the newer
    /// keys) still load instead of resetting the widget to empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nearestStoreName = try c.decodeIfPresent(String.self, forKey: .nearestStoreName)
        nearestStoreDistanceText = try c.decodeIfPresent(String.self, forKey: .nearestStoreDistanceText)
        items = try c.decodeIfPresent([WidgetSnapshotItem].self, forKey: .items) ?? []
        tickedItemIDs = try c.decodeIfPresent(Set<String>.self, forKey: .tickedItemIDs) ?? []
        quantityAdjustments = try c.decodeIfPresent([String: Int].self, forKey: .quantityAdjustments) ?? [:]
        ownerUserID = try c.decodeIfPresent(String.self, forKey: .ownerUserID)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public static func read() -> WidgetSnapshot {
        guard let ud = UserDefaults(suiteName: appGroupID),
              let data = ud.data(forKey: defaultsKey) else {
            return WidgetSnapshot()
        }
        if let decoded = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) {
            return decoded
        }
        return WidgetSnapshot()
    }

    public static func write(_ snapshot: WidgetSnapshot) {
        withCrossProcessLock { writeUnlocked(snapshot) }
    }

    /// Read-modify-write under the cross-process lock, so a tick queued by the
    /// widget extension cannot be lost to the app publishing a fresh item list
    /// (or vice versa) between the read and the write.
    public static func mutate(_ change: (inout WidgetSnapshot) -> Void) {
        withCrossProcessLock {
            var snapshot = read()
            change(&snapshot)
            snapshot.updatedAt = Date()
            writeUnlocked(snapshot)
        }
    }

    private static func writeUnlocked(_ snapshot: WidgetSnapshot) {
        guard let ud = UserDefaults(suiteName: appGroupID),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        ud.set(data, forKey: defaultsKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Advisory file lock in the App Group container. The app, the widget
    /// extension, Siri intents and the share extension are separate processes;
    /// UserDefaults gives no atomicity across them, and process-local
    /// serialisation does not help. `flock` on one shared file does. Falls back
    /// to running unlocked if the container is unavailable.
    private static func withCrossProcessLock<T>(_ body: () -> T) -> T {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return body()
        }
        let lockURL = container.appendingPathComponent(".frydge-widget-snapshot.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        if flock(fd, LOCK_EX) != 0 { return body() }
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    // MARK: - Derived values shared by the widgets, watch and CarPlay

    /// Items not yet ticked off from the widget.
    public var remainingItems: [WidgetSnapshotItem] {
        items.filter { !tickedItemIDs.contains($0.id) }
    }

    /// Quantity as the widget should show it: the stored value plus any
    /// adjustment the user has queued from the widget but the app hasn't
    /// applied yet.
    public func effectiveQuantity(for item: WidgetSnapshotItem) -> Double? {
        guard let base = item.quantityValue else { return nil }
        let delta = Double(quantityAdjustments[item.id] ?? 0)
        return max(1, base + delta)
    }

    /// Estimated basket total for the remaining items, multiplied by quantity
    /// for count-style units. Returns nil when nothing has a price yet.
    public var estimatedTotal: (value: Double, currencyCode: String, pricedCount: Int)? {
        var total: Double = 0
        var priced = 0
        var currency = "NZD"
        for item in remainingItems {
            guard let unit = item.unitPriceValue else { continue }
            if let code = item.currencyCode, !code.isEmpty { currency = code }
            let multiplier: Double = {
                guard item.isCountLike, let qty = effectiveQuantity(for: item) else { return 1 }
                return qty
            }()
            total += unit * multiplier
            priced += 1
        }
        guard priced > 0 else { return nil }
        return (total, currency, priced)
    }
}

public struct WidgetSnapshotItem: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Pre-formatted quantity ("x2", "500g") for places that can't compute one.
    public var displayQuantity: String?
    public var priceText: String?
    public var priceStoreName: String?
    /// Numeric price behind `priceText`, so widgets can total the basket.
    public var priceValue: Double?
    public var currencyCode: String?
    /// Numeric quantity from the shopping list ("2" -> 2). Nil when not numeric.
    public var quantityValue: Double?
    /// Raw unit from the shopping list ("", "ea", "g", "kg", ...).
    public var unit: String?
    /// Food emoji resolved by the main app (the widget has no lookup table).
    public var emoji: String?

    public init(
        id: String,
        name: String,
        displayQuantity: String? = nil,
        priceText: String? = nil,
        priceStoreName: String? = nil,
        priceValue: Double? = nil,
        currencyCode: String? = nil,
        quantityValue: Double? = nil,
        unit: String? = nil,
        emoji: String? = nil
    ) {
        self.id = id
        self.name = name
        self.displayQuantity = displayQuantity
        self.priceText = priceText
        self.priceStoreName = priceStoreName
        self.priceValue = priceValue
        self.currencyCode = currencyCode
        self.quantityValue = quantityValue
        self.unit = unit
        self.emoji = emoji
    }

    /// Units where "+1" means one more pack/item, so quantity steppers make sense.
    public var isCountLike: Bool {
        let u = (unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["", "ea", "each", "x", "pk", "pack", "packs", "pcs", "piece", "pieces", "bunch", "can", "cans", "tin", "tins", "bottle", "bottles", "loaf", "loaves", "bag", "bags", "box", "jar", "punnet"].contains(u)
    }

    /// Price as a number: the stored value, or parsed from "$3.99"-style text.
    public var unitPriceValue: Double? {
        if let priceValue { return priceValue }
        guard let text = priceText else { return nil }
        let cleaned = text.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
        return Double(cleaned)
    }
}
