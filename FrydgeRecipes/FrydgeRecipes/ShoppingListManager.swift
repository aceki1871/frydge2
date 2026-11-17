import Foundation
import Combine
import CloudKit
import CoreData
import WidgetKit
import UIKit

// MARK: - Model

struct ShoppingListItem: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var quantity: String
    var unit: String
    var location: String
    var dietaryTags: Set<String>
    var createdAt: Date
    var userPhotoData: [Data]

    init(
        id: UUID = UUID(),
        name: String,
        quantity: String = "1",
        unit: String = "",
        location: String = "Shopping",
        dietaryTags: Set<String> = [],
        createdAt: Date = Date(),
        userPhotoData: [Data] = []
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.location = location
        self.dietaryTags = dietaryTags
        self.createdAt = createdAt
        self.userPhotoData = userPhotoData
    }

    enum CodingKeys: String, CodingKey {
        case id, name, quantity, unit, location, dietaryTags, createdAt, userPhotoData
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        quantity = try c.decode(String.self, forKey: .quantity)
        unit = try c.decode(String.self, forKey: .unit)
        location = try c.decode(String.self, forKey: .location)
        dietaryTags = try c.decode(Set<String>.self, forKey: .dietaryTags)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        userPhotoData = (try? c.decode([Data].self, forKey: .userPhotoData)) ?? []
    }

    /// Photo bytes are excluded from encoding on purpose — same rationale as
    /// `StoredIngredient.encode(to:)`: the JSON file is a rollback backup, and
    /// photos live in Core Data (`CDItemPhoto`), synced via CloudKit. The
    /// decoder still reads photos from old files for the upgrade migration.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(quantity, forKey: .quantity)
        try c.encode(unit, forKey: .unit)
        try c.encode(location, forKey: .location)
        try c.encode(dietaryTags, forKey: .dietaryTags)
        try c.encode(createdAt, forKey: .createdAt)
    }

    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return n }
        if u.isEmpty { return "\(n) x\(q)" }
        return "\(n) \(q)\(u)"
    }

    /// At-a-glance short label with quantity, e.g. "Popcorn ×2".
    /// The full `name` remains available in the item detail sheet.
    var shorthandDisplay: String {
        let short = ProductShorthand.short(for: name)
        let q = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty || q == "1" { return short }
        if u.isEmpty { return "\(short) ×\(q)" }
        return "\(short) \(q)\(u)"
    }

    var normalizedKey: String {
        name
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

@MainActor
final class ShoppingListManager: ObservableObject {

    /// The app's live instance, for App Intents (Siri) which can't reach the
    /// SwiftUI environment. Weak: the App's @StateObject owns the lifetime.
    static private(set) weak var current: ShoppingListManager?

    // MARK: - Published

    @Published var shoppingListItems: [ShoppingListItem] = []

    // MARK: - Storage keys

    private let appGroupName = "group.Clark-Online.FrydgeRecipeAPN"
    private let shoppingListKey = "shoppingList_structured_v1" // internal per-user key
    private let widgetStructuredShoppingListKey = "shoppingListItemsJSON" // widget/live activity key
    private let widgetLegacyShoppingListKey = "shoppingList" // widget/live activity legacy fallback
    private var cancellables: Set<AnyCancellable> = []
    
    private struct WidgetShoppingListItem: Codable, Hashable, Identifiable {
        let id: String
        let name: String
        let quantity: String
        let unit: String

        var displayString: String {
            let name = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let qty  = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
            let unit = self.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            if unit.lowercased() == "ea", !qty.isEmpty {
                return name.isEmpty ? "x\(qty)" : "\(name) x\(qty)"
            }
            var parts = [name]
            if !qty.isEmpty { parts.append(qty) }
            if !unit.isEmpty { parts.append(unit) }
            return parts.filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    // MARK: - CloudKit

    /// Retained only to resolve the iCloud user record ID for per-user local file
    /// scoping. All record-level CloudKit work is now handled by
    /// NSPersistentCloudKitContainer via PersistenceController.
    private let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")

    // MARK: - Stable install-scoped ID (pre-iCloud resolution)

    /// Prevents "local" bucket being shared across different iCloud users on the same device.
    private var installScopedID: String {
        let key = "installScopedShoppingID"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty { return existing }
        let created = "install_" + UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        UserDefaults(suiteName: appGroupName)?.set(created, forKey: key)
        return created
    }

    /// Stable per-user id derived from CloudKit user recordID recordName.
    /// Falls back to installScopedID until CloudKit is available.
    private var userID: String {
        if let v = UserDefaults.standard.string(forKey: "appleUserID"), !v.isEmpty { return v }
        if let v = UserDefaults(suiteName: appGroupName)?.string(forKey: "appleUserID"), !v.isEmpty { return v }
        return installScopedID
    }

    private var fileName: String { "shoppingList_\(userID).json" }
    private var appGroupShoppingListKey: String { "\(shoppingListKey)_\(userID)" }

    // Revision tracking removed.
    //
    // The old design compared a local `updatedAt` against the cloud record's and
    // skipped the pull when local was newer. That is what silently discarded
    // additions made on another device while this one was offline (P0-4).
    // Core Data merges per property; there is no whole-list revision to compare.

    // MARK: - Init

    init() {
        Self.current = self
        loadShoppingList()
        loadFromFile()
        cleanupShoppingList()
        convertExistingItemsToPackSizes()
        setupActiveSync()
        attachFridgeRecalculation(FrydgeManager.shared)

        // Resolve iCloud user id (so we stop being install-scoped and become truly per-user).
        Task { await resolveAndPersistAppleUserIDIfNeeded() }
    }

    /// iCloud account switched while installed. `AccountChangeMonitor` has
    /// already replaced the stored `appleUserID`; drop the previous user's list
    /// from memory and re-read the App Group payload and store under the new
    /// identity. The old account's data is never merged into the new one.
    func handleAccountChange() {
        applyWithoutPersisting([])
        // Always clear the widget snapshot, even when the list was already empty.
        writeAppGroupSnapshotNow([])
        lastPersistedIDs = []
        loadShoppingList()
        loadFromFile()
        cleanupShoppingList()
        refreshWidgetSnapshots()
    }

    // MARK: - Public API (core list ops)

    func addToShoppingList(
        name: String,
        quantity: String = "1",
        unit: String = "",
        location: String = "Shopping",
        dietaryTags: Set<String> = []
    ) {
        var cleanName = canonicalDisplayString(name)
        var cleanQuantity = canonicalDisplayString(quantity)
        let cleanUnit = canonicalDisplayString(unit)
        guard !cleanName.isEmpty else { return }

        // A name like "Onion 2" with no real quantity means the count was never
        // parsed out; move it into the quantity so the list never shows "Onion 2 x1".
        if cleanUnit.isEmpty, cleanQuantity.isEmpty || cleanQuantity == "1",
           let split = RecipeIngredientParser.splitTrailingCount(cleanName) {
            cleanName = split.name
            cleanQuantity = split.quantity
        }

        // Round to a purchasable pack size on the way in, so every entry path
        // (recipes, Siri, scans, manual adds) lands on a buyable amount.
        let sized = packSized(name: cleanName, quantity: cleanQuantity, unit: cleanUnit)

        // De-dupe by normalized name (your current behaviour) but keep structured fields if already exists
        let key = normalizeKey(cleanName)
        if let idx = shoppingListItems.firstIndex(where: { $0.normalizedKey == key }) {
            // Merge: prefer existing id; update quantity/unit if provided; union dietary
            var existing = shoppingListItems[idx]
            if !sized.quantity.isEmpty { existing.quantity = sized.quantity }
            if !sized.unit.isEmpty { existing.unit = sized.unit }
            if !canonicalDisplayString(location).isEmpty { existing.location = canonicalDisplayString(location) }
            existing.dietaryTags = existing.dietaryTags.union(dietaryTags.map { $0.uppercased() })
            shoppingListItems[idx] = existing
        } else {
            let item = ShoppingListItem(
                name: cleanName,
                quantity: sized.quantity.isEmpty ? "1" : sized.quantity,
                unit: sized.unit,
                location: canonicalDisplayString(location).isEmpty ? "Shopping" : canonicalDisplayString(location),
                dietaryTags: Set(dietaryTags.map { $0.uppercased() })
            )
            shoppingListItems.append(item)
        }

        cleanupShoppingList()
        markLocalChanged()
        saveShoppingListToUserDefaults()
        saveToFile()
        refreshWidgetSnapshots()

        // Warn if this is something the user said they can't or won't eat
        // (Profile → Dietary). Covers manual adds, Siri, scans and recipes.
        DietaryRestrictionStore.shared.notifyIfFlagged(name: cleanName, addedTo: .shoppingList)
    }

    /// Restores items from a Your Data backup file. Items already on the list
    /// (same id, or same normalised name) are skipped; the rest are added as
    /// saved. Returns how many were added.
    @discardableResult
    func restoreFromBackup(_ items: [ShoppingListItem]) -> Int {
        let existingIDs = Set(shoppingListItems.map(\.id))
        var existingKeys = Set(shoppingListItems.map(\.normalizedKey))
        var added = 0
        for item in items {
            guard !existingIDs.contains(item.id), !existingKeys.contains(item.normalizedKey),
                  !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            shoppingListItems.append(item)
            existingKeys.insert(item.normalizedKey)
            added += 1
        }
        guard added > 0 else { return 0 }
        cleanupShoppingList()
        markLocalChanged()
        saveShoppingListToUserDefaults()
        saveToFile()
        refreshWidgetSnapshots()
        return added
    }

    /// Convenience for legacy call-sites that pass one string like "Cheese 1kg"
    func addToShoppingList(_ raw: String) {
        let formatted = canonicalDisplayString(raw)
        guard !formatted.isEmpty else { return }
        // Keep it simple: treat as "name" only; quantity/unit parsing can be added later if you want
        addToShoppingList(name: formatted)
    }

    // MARK: - Pack sizing

    /// Rounds a raw quantity up to a purchasable NZ pack size when the
    /// ingredient is known (eggs → 6/10/12 carton, 50 g butter → 250 g block).
    /// Unknown items and incomparable units pass through unchanged.
    private func packSized(name: String, quantity: String, unit: String) -> (quantity: String, unit: String) {
        guard let value = FridgeUnits.parse(quantity),
              let buy = PackSizeRules.purchaseDisplay(name: name, needed: value, unit: unit) else {
            return (quantity, unit)
        }
        return buy
    }

    /// Converts entries already on the list (saved by older versions, or synced
    /// from a device without pack sizing) to purchasable pack sizes. Rounding
    /// is idempotent — an already-rounded amount maps to itself — so this runs
    /// on every launch and only persists when something actually changed.
    private func convertExistingItemsToPackSizes() {
        var changed = false
        for idx in shoppingListItems.indices {
            let item = shoppingListItems[idx]
            let sized = packSized(name: item.name, quantity: item.quantity, unit: item.unit)
            if sized.quantity != item.quantity || sized.unit != item.unit {
                shoppingListItems[idx].quantity = sized.quantity
                shoppingListItems[idx].unit = sized.unit
                changed = true
            }
        }
        guard changed else { return }
        markLocalChanged()
        saveShoppingListToUserDefaults()
        saveToFile()
        refreshWidgetSnapshots()
        Task { await syncToCloud() }
    }

    func removeFromShoppingList(id: UUID) {
        let before = shoppingListItems.count
        shoppingListItems.removeAll { $0.id == id }
        guard shoppingListItems.count != before else { return }

        cleanupShoppingList()
        markLocalChanged()
        saveShoppingListToUserDefaults()
        saveToFile()
        refreshWidgetSnapshots()
        Task { await syncToCloud() }
    }

    /// Legacy removal (best-effort) — remove by normalized name
    func removeFromShoppingList(_ itemName: String) {
        let targetKey = normalizeKey(itemName)
        let before = shoppingListItems.count
        shoppingListItems.removeAll { $0.normalizedKey == targetKey }
        if shoppingListItems.count == before {
            let canonicalTargetKey = normalizeKey(canonicalDisplayString(itemName))
            shoppingListItems.removeAll { $0.normalizedKey == canonicalTargetKey }
        }

        cleanupShoppingList()
        markLocalChanged()
        saveShoppingListToUserDefaults()
        saveToFile()
        refreshWidgetSnapshots()
        Task { await syncToCloud() }
    }

    func clearShoppingList() {
        shoppingListItems.removeAll()
        markLocalChanged()
        saveShoppingListToUserDefaults()
        saveToFile()
        refreshWidgetSnapshots()
        Task { await syncToCloud() }
    }

    func updateUserPhotos(for id: UUID, photos: [Data]) {
        guard let idx = shoppingListItems.firstIndex(where: { $0.id == id }) else { return }
        shoppingListItems[idx].userPhotoData = photos
        markLocalChanged()
        saveShoppingListToUserDefaults()
        saveToFile()

        // Photos are written here rather than in the general write-through: with
        // external binary storage, comparing blobs faults every one of them into
        // memory, and this is the only place photos actually change.
        writePhotosThroughToStore(id: id, photos: photos)
    }

    func itemsNeeded() -> [ShoppingListItem] {
        shoppingListItems
    }

    /// Removes any items the user ticked off via the widget. Called on app
    /// foreground / init. Clears the snapshot's ticked set after applying.
    func drainWidgetTicks() {
        let snapshot = WidgetSnapshot.read()
        let tickedIDs = snapshot.tickedItemIDs
        let adjustments = snapshot.quantityAdjustments
        guard !tickedIDs.isEmpty || !adjustments.isEmpty else { return }

        // Actions queued under a different iCloud account (the snapshot was
        // published before an account switch) are discarded, never applied to
        // this account's list.
        if let owner = snapshot.ownerUserID, owner != userID {
            WidgetSnapshot.mutate {
                $0.tickedItemIDs.removeAll()
                $0.quantityAdjustments.removeAll()
            }
            return
        }

        var changed = false

        // 1) Quantity +/- taps from the widget. Applied before ticks so a
        //    ticked item's adjustment is simply discarded with it.
        for (idString, delta) in adjustments where delta != 0 {
            guard let uuid = UUID(uuidString: idString),
                  let idx = shoppingListItems.firstIndex(where: { $0.id == uuid }) else { continue }
            let raw = shoppingListItems[idx].quantity.trimmingCharacters(in: .whitespacesAndNewlines)
            let current = FridgeUnits.parse(raw) ?? Double(raw) ?? 1
            let updated = max(1, current + Double(delta))
            let formatted = updated.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(updated))
                : String(format: "%.1f", updated)
            if formatted != raw {
                shoppingListItems[idx].quantity = formatted
                changed = true
            }
        }

        // 2) Ticked-off items leave the list.
        let tickedUUIDs: Set<UUID> = Set(tickedIDs.compactMap { UUID(uuidString: $0) })
        if !tickedUUIDs.isEmpty {
            let before = shoppingListItems.count
            shoppingListItems.removeAll { tickedUUIDs.contains($0.id) }
            if shoppingListItems.count != before { changed = true }
        }

        // Consume exactly what was applied. A tick or +/- tap queued by the
        // widget between our read and this write survives for the next drain
        // instead of being wiped; an adjustment that grew meanwhile keeps the
        // unapplied remainder.
        WidgetSnapshot.mutate {
            $0.tickedItemIDs.subtract(tickedIDs)
            for (id, applied) in adjustments {
                let remaining = ($0.quantityAdjustments[id] ?? 0) - applied
                if remaining == 0 {
                    $0.quantityAdjustments.removeValue(forKey: id)
                } else {
                    $0.quantityAdjustments[id] = remaining
                }
            }
        }

        if changed {
            markLocalChanged()
            saveShoppingListToUserDefaults()
            saveToFile()
            refreshWidgetSnapshots()
            Task { await syncToCloud() }
        }
    }

    func isInShoppingList(_ itemName: String) -> Bool {
        let key = normalizeKey(itemName)
        return shoppingListItems.contains(where: { $0.normalizedKey == key })
    }

    // MARK: - Frydge -> Shopping (live recalculation)

    /// Remaining stock per fridge item id, in base units, from the last publish.
    private var fridgeBaseline: [UUID: Double] = [:]
    private var fridgeBaselineSeeded = false

    /// The fridge streams several publishes while it loads at launch (memory →
    /// Core Data → CloudKit merge). Anything inside this window is baseline,
    /// not newly bought stock — otherwise launch would look like a shopping
    /// spree and wrongly clear the list. Missing a real gain in this window is
    /// harmless (the item just stays on the list).
    private let fridgeWatchStart = Date()
    private var fridgeSettleWindow: TimeInterval { 10 }

    /// Watches the fridge so the shopping list recalculates the moment stock
    /// arrives (barcode/receipt scan, manual add, another device via sync):
    /// newly gained stock is deducted from matching entries, fully covered
    /// entries come off the list, and the widget reloads immediately.
    private func attachFridgeRecalculation(_ frydgeManager: FrydgeManager) {
        frydgeManager.$storedIngredients
            .sink { [weak self] items in
                Task { @MainActor [weak self] in self?.applyFridgeChange(items) }
            }
            .store(in: &cancellables)
    }

    private func applyFridgeChange(_ stored: [StoredIngredient]) {
        // Remaining stock = quantity × (1 − used%), in base units (g/ml/each).
        var current: [UUID: (base: Double, groupKey: String, name: String)] = [:]
        for item in stored where item.lifecycle == .fridge {
            guard let base = FridgeUnits.baseAmount(quantity: item.quantity, unit: item.unit) else { continue }
            let remainingRatio = max(0, min(1, 1 - item.quantityUsed / 100))
            current[item.id] = (base.value * remainingRatio, base.groupKey, item.name)
        }

        defer {
            fridgeBaseline = current.mapValues(\.base)
            fridgeBaselineSeeded = true
        }

        // The first publish just seeds the baseline: stock already in the
        // fridge was accounted for when items went onto the list.
        guard fridgeBaselineSeeded,
              Date().timeIntervalSince(fridgeWatchStart) > fridgeSettleWindow else { return }

        // Positive deltas only — cooking deductions must never eat the list.
        var gains: [(name: String, groupKey: String, amount: Double)] = []
        for (id, info) in current {
            let previous = fridgeBaseline[id] ?? 0
            if info.base > previous + 0.0001 {
                gains.append((info.name, info.groupKey, info.base - previous))
            }
        }
        guard !gains.isEmpty, !shoppingListItems.isEmpty else { return }

        var changed = false
        var removeIDs = Set<UUID>()

        for idx in shoppingListItems.indices {
            let item = shoppingListItems[idx]
            guard let listBase = FridgeUnits.baseAmount(quantity: item.quantity, unit: item.unit),
                  listBase.value > 0 else { continue }

            // Consume matching gains; each gain is spent at most once.
            var remaining = listBase.value
            var consumedAny = false
            for gainIdx in gains.indices {
                guard gains[gainIdx].amount > 0.0001,
                      gains[gainIdx].groupKey == listBase.groupKey,
                      IngredientMatcher.matches(gains[gainIdx].name, item.name) else { continue }
                let consumed = min(remaining, gains[gainIdx].amount)
                remaining -= consumed
                gains[gainIdx].amount -= consumed
                consumedAny = true
                if remaining <= 0.0001 { break }
            }
            guard consumedAny else { continue }

            if remaining <= 0.0001 {
                removeIDs.insert(item.id)
                changed = true
            } else {
                let baseUnit: String
                switch listBase.groupKey {
                case "weight": baseUnit = "g"
                case "volume": baseUnit = "ml"
                case "count":  baseUnit = ""
                default:       baseUnit = item.unit
                }
                let display = PackSizeRules.purchaseDisplay(name: item.name, needed: remaining, unit: baseUnit)
                    ?? FridgeUnits.display(quantity: FridgeUnits.format(remaining), unit: baseUnit)
                if display.quantity != item.quantity || display.unit != item.unit {
                    shoppingListItems[idx].quantity = display.quantity
                    shoppingListItems[idx].unit = display.unit
                    changed = true
                }
            }
        }

        if !removeIDs.isEmpty {
            shoppingListItems.removeAll { removeIDs.contains($0.id) }
        }
        guard changed else { return }

        markLocalChanged()
        saveShoppingListToUserDefaults()
        saveToFile()
        refreshWidgetSnapshots()
        Task { await syncToCloud() }
    }

    // MARK: - Shopping -> Frydge (the point of the refactor)

    /// Call this when the user ticks an item as "bought".
    /// This pushes the item into FrydgeManager while keeping location + dietary tags.
    /// Then it removes it from the shopping list.
    func purchaseItem(_ id: UUID, into frydgeManager: FrydgeManager) async {
        guard let item = shoppingListItems.first(where: { $0.id == id }) else { return }

        let expirationDate = StoredIngredient.defaultExpiry(for: item.name)

        // Add into Frydge as a structured product (keeps dietary + location)
        // NOTE: your FrydgeManager.addProduct merges by name/unit/lifecycle; that’s fine for “fridge”.
        frydgeManager.addProduct(
            name: item.name,
            quantity: item.quantity,
            unit: item.unit,
            expirationDate: expirationDate,
            location: item.location.isEmpty ? "Fridge" : item.location,
            dietaryTags: item.dietaryTags,
            lifecycle: .fridge
        )

        // Remove from shopping list after successful add
        removeFromShoppingList(id: id)
    }

    // MARK: - Normalization / Formatting

    private func normalizeKey(_ s: String) -> String {
        canonicalDisplayString(s).lowercased()
    }

    private func canonicalDisplayString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Change tracking

    /// Retained as a no-op — several call sites still invoke it. There is no
    /// whole-list revision counter any more; Core Data tracks per-object change.
    private func markLocalChanged() {}

    // MARK: - App Group Persistence (Widget/Extension) — per-user

    private func writeAppGroupSnapshotNow(_ items: [ShoppingListItem]? = nil) {
        guard let ud = UserDefaults(suiteName: appGroupName) else { return }
        let items = items ?? shoppingListItems

        // Internal per-user structured payload used by the main app.
        if let data = try? JSONEncoder().encode(items) {
            ud.set(data, forKey: appGroupShoppingListKey)
        }

        // Shared snapshot for widgets / live activities.
        let widgetItems = items.map {
            WidgetShoppingListItem(
                id: $0.id.uuidString,
                name: $0.name,
                quantity: $0.quantity,
                unit: $0.unit
            )
        }

        if let data = try? JSONEncoder().encode(widgetItems),
           let json = String(data: data, encoding: .utf8) {
            ud.set(json, forKey: widgetStructuredShoppingListKey)
        } else {
            ud.removeObject(forKey: widgetStructuredShoppingListKey)
        }

        // Legacy fallback for older widget readers.
        let legacy = widgetItems.map { $0.displayString }
        ud.set(legacy, forKey: widgetLegacyShoppingListKey)

        // Top-10 snapshot used by the home/lock-screen widgets. Prices are filled in
        // asynchronously by WidgetPriceFetcher; this write preserves any existing prices
        // for items that survive across updates.
        let existingByID: [String: WidgetSnapshotItem] = {
            let snapshot = WidgetSnapshot.read()
            return Dictionary(snapshot.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }()

        let topTen = items.prefix(10).map { item -> WidgetSnapshotItem in
            let id = item.id.uuidString
            let qty = item.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
            let unit = item.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayQuantity: String? = {
                if qty.isEmpty { return nil }
                if unit.isEmpty { return "x\(qty)" }
                if unit.lowercased() == "ea" { return "x\(qty)" }
                return "\(qty)\(unit)"
            }()
            let existing = existingByID[id]
            return WidgetSnapshotItem(
                id: id,
                name: item.name,
                displayQuantity: displayQuantity,
                priceText: existing?.priceText,
                priceStoreName: existing?.priceStoreName,
                priceValue: existing?.priceValue,
                currencyCode: existing?.currencyCode,
                quantityValue: FridgeUnits.parse(qty) ?? Double(qty),
                unit: unit,
                emoji: FoodEmoji.emoji(for: item.name)
            )
        }

        WidgetSnapshot.mutate { snap in
            snap.items = Array(topTen)
            // Scope queued widget actions to this account (see drainWidgetTicks).
            snap.ownerUserID = userID
            // Quantity changes queued from the widget only make sense for items
            // still on the list; drop any that point at removed items.
            let liveIDs = Set(topTen.map(\.id))
            snap.quantityAdjustments = snap.quantityAdjustments.filter { liveIDs.contains($0.key) }
        }

        // Kick the price fetcher to refresh anything missing/stale.
        Task { await WidgetPriceFetcher.shared.refresh(for: Array(topTen)) }

        // Keep live activity in sync whenever the list is written.
        ActivityManager.updateActivity()

        // Push updated summary to Apple Watch if paired.
        WatchDataSender.shared.sendCurrentData(from: WidgetSnapshot.read())
    }
    private func refreshWidgetSnapshots() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    func loadShoppingList() {
        guard let ud = UserDefaults(suiteName: appGroupName) else {
            shoppingListItems = []
            return
        }

        // New structured payload
        if let data = ud.data(forKey: appGroupShoppingListKey),
           let decoded = try? JSONDecoder().decode([ShoppingListItem].self, from: data) {
            shoppingListItems = decoded
            return
        }

        // Legacy fallback: previous versions stored [String] in app group.
        // Try to migrate if present (best-effort).
        let legacyKey = "shoppingList_\(userID)" // old key shape sometimes used in prior code
        if let legacy = ud.array(forKey: legacyKey) as? [String], !legacy.isEmpty {
            shoppingListItems = legacy
                .map { canonicalDisplayString($0) }
                .filter { !$0.isEmpty }
                .map { ShoppingListItem(name: $0) }
            cleanupShoppingList()
            markLocalChanged()
            saveShoppingListToUserDefaults()
            saveToFile()
            refreshWidgetSnapshots()
            return
        }

        shoppingListItems = []
    }

    // MARK: - JSON File Persistence (per-user)

    private func localFileURL(forFileName name: String? = nil) -> URL {
        let file = name ?? fileName

        // Prefer App Group container (works for app + extensions)
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName) {
            return groupURL.appendingPathComponent(file)
        }

        // Fallback: Documents (main app)
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return docs.appendingPathComponent(file)
        }

        // Last resort: temp (should never be hit, but prevents crashes)
        return FileManager.default.temporaryDirectory.appendingPathComponent(file)
    }

    /// Set when a disk write fails (device locked, disk full, App Group container
    /// unavailable). Retried on the next successful save opportunity — never by
    /// re-entering this function, which previously recursed without bound and
    /// overflowed the stack on any persistent write failure.
    private var pendingDiskSave = false

    /// Rollback backup only. Read solely by `seedFromBackupJSON()` on the first
    /// launch after upgrading.
    private func writeBackupJSON(_ items: [ShoppingListItem]? = nil) {
        do {
            let data = try JSONEncoder().encode(items ?? shoppingListItems)
            try data.write(to: localFileURL(), options: [.atomic])
            pendingDiskSave = false
        } catch {
            // Do NOT retry inline. Mark dirty and let the next mutation or
            // foreground pass try again; the App Group UserDefaults snapshot
            // still carries the list for the widget in the meantime.
            pendingDiskSave = true
            print("[ERROR] Saving shopping list backup failed: \(error.localizedDescription)")
            writeAppGroupSnapshotNow(items)
            refreshWidgetSnapshots()
        }
    }

    /// Name retained — many call sites depend on it. Persists to Core Data (the
    /// source of truth) and writes the JSON rollback backup.
    // MARK: Coalesced persistence

    /// Every mutation used to write the App Group payload, backup file, Core Data,
    /// widgets, Live Activity and Watch synchronously on the main thread — twice,
    /// once from the call site and once from the Combine sink — before SwiftUI
    /// could redraw. Now the old entry points just mark the list dirty and one
    /// write runs shortly after, so taps render immediately and bursts (adding a
    /// whole recipe) cost a single save.
    private var flushTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.flushNow()
        }
    }

    /// Writes the current list immediately if a save is pending.
    func flushNow() {
        guard flushTask != nil else { return }
        flushTask?.cancel()
        flushTask = nil
        persist(shoppingListItems)
    }

    /// Don't lose a pending edit if the app is suspended inside the debounce window.
    private func observeLifecycleForFlush() {
        let names: [Notification.Name] = [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification
        ]
        lifecycleObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushNow() }
            }
        }
    }

    private func saveShoppingListToUserDefaults() { scheduleFlush() }
    private func saveToFile() { scheduleFlush() }

    /// Persists one specific snapshot of the list (App Group payload, rollback
    /// backup and Core Data).
    private func persist(_ items: [ShoppingListItem]) {
        writeAppGroupSnapshotNow(items)
        writeBackupJSON(items)
        writeThroughToStore(items)
    }

    /// Call on foreground to flush a save that previously failed.
    func retryPendingDiskSaveIfNeeded() {
        guard pendingDiskSave else { return }
        saveToFile()
    }

    // MARK: Upgrade seeding state

    /// Set once the Core Data store has been confirmed as the source of truth for
    /// this user. From then on an empty active fetch means "the list is empty"
    /// (the user cleared it, or deletions synced in) and the JSON backup is never
    /// used to reseed it. Scoped by user so a different account on the same
    /// device gets its own first-launch seed.
    private var seedCompletedKey: String { "coreDataSeedCompleted.shopping.\(userID)" }

    private var seedCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: seedCompletedKey) }
        set { UserDefaults.standard.set(newValue, forKey: seedCompletedKey) }
    }

    /// Core Data wins. The JSON file and App Group payload are consulted only on
    /// the first launch after upgrading, before the store has ever held data.
    private func loadFromFile() {
        if coreDataAvailable {
            do {
                let rows = try storeContext.fetch(CDShoppingItem.fetchRequestForActiveItems())
                if !rows.isEmpty {
                    applyWithoutPersisting(rows.map { $0.toShoppingListItem() })
                    seedCompleted = true
                    return
                }
                if seedCompleted {
                    // Genuinely empty. Do not resurrect the backup.
                    applyWithoutPersisting([])
                    return
                }
            } catch {
                // Degraded read: keep whatever the App Group payload gave us as
                // an in-memory fallback. Do not seed into a store we cannot read.
                print("[STORE ERROR] initial shopping fetch failed: \(error.localizedDescription)")
                return
            }
        }
        seedFromBackupJSON()
    }

    /// One-way upgrade path: read the legacy JSON and push it into Core Data.
    /// Marks the seed complete only after the store accepted the rows, so an
    /// interrupted or failed import is retried on the next launch and the
    /// backup file is never the only copy that gets consumed.
    private func seedFromBackupJSON() {
        let url = localFileURL()
        guard let data = try? Data(contentsOf: url) else {
            // Nothing to seed: the store is legitimately empty for this user.
            if coreDataAvailable { seedCompleted = true }
            return
        }

        if let decoded = try? JSONDecoder().decode([ShoppingListItem].self, from: data), !decoded.isEmpty {
            shoppingListItems = decoded
            lastPersistedIDs = []
            guard writeThroughToStore() else { return }
            // Legacy backups embedded photo bytes in the JSON; the write-through
            // skips photos by design, so persist them into CDItemPhoto once here.
            for item in decoded where !item.userPhotoData.isEmpty {
                writePhotosThroughToStore(id: item.id, photos: item.userPhotoData)
            }
            seedCompleted = true
            print("[MIGRATE] Seeded \(decoded.count) shopping items into Core Data.")
            return
        }

        // Legacy file migration: [String]
        if let legacy = try? JSONDecoder().decode([String].self, from: data), !legacy.isEmpty {
            shoppingListItems = legacy
                .map { canonicalDisplayString($0) }
                .filter { !$0.isEmpty }
                .map { ShoppingListItem(name: $0) }
            cleanupShoppingList()
            lastPersistedIDs = []
            guard writeThroughToStore() else { return }
            saveShoppingListToUserDefaults()
            seedCompleted = true
            print("[MIGRATE] Seeded legacy [String] shopping list into Core Data.")
            return
        }

        // File exists but holds no items: nothing to migrate.
        if coreDataAvailable { seedCompleted = true }
    }

    private func cleanupShoppingList() {
        // Normalize fields, remove empties, de-dupe by normalized name
        shoppingListItems = shoppingListItems
            .map { item in
                var x = item
                x.name = canonicalDisplayString(x.name)
                x.quantity = canonicalDisplayString(x.quantity)
                x.unit = canonicalDisplayString(x.unit)
                x.location = canonicalDisplayString(x.location)
                x.dietaryTags = Set(x.dietaryTags.map { canonicalDisplayString($0).uppercased() }.filter { !$0.isEmpty })
                if x.quantity.isEmpty { x.quantity = "1" }
                if x.location.isEmpty { x.location = "Shopping" }
                // Repair entries saved before trailing counts were parsed ("Onion 2" ×1).
                if x.unit.isEmpty, x.quantity == "1",
                   let split = RecipeIngredientParser.splitTrailingCount(x.name) {
                    x.name = split.name
                    x.quantity = split.quantity
                }
                return x
            }
            .filter { !$0.name.isEmpty }

        var seen: Set<String> = []
        var deduped: [ShoppingListItem] = []
        deduped.reserveCapacity(shoppingListItems.count)

        for item in shoppingListItems {
            let k = item.normalizedKey
            guard !k.isEmpty else { continue }
            if !seen.contains(k) {
                seen.insert(k)
                deduped.append(item)
            }
        }

        shoppingListItems = deduped
    }

    // MARK: - User scoping + safe migration

    private func resolveAndPersistAppleUserIDIfNeeded() async {
        // If we already have a real user id, nothing to do.
        if let existing = UserDefaults.standard.string(forKey: "appleUserID"),
           !existing.isEmpty,
           !existing.hasPrefix("install_") {
            return
        }

        do {
            let recordID = try await container.userRecordID()
            let appleUserID = recordID.recordName

            let previous = UserDefaults.standard.string(forKey: "appleUserID") ?? ""

            // Persist
            UserDefaults.standard.set(appleUserID, forKey: "appleUserID")
            UserDefaults(suiteName: appGroupName)?.set(appleUserID, forKey: "appleUserID")

            // If user changed, do NOT auto-merge old install/local data into new user.
            if !previous.isEmpty, previous != appleUserID, !previous.hasPrefix("install_") {
                shoppingListItems = []
                markLocalChanged()
                saveShoppingListToUserDefaults()
                saveToFile()
                refreshWidgetSnapshots()
            }

            // Load scoped (real-user) data
            loadShoppingList()
            loadFromFile()

            // Optional one-time migrate: only from install-scoped bucket, and only if scoped list is empty
            if shoppingListItems.isEmpty {
                let installKey = "\(shoppingListKey)_\(installScopedID)"
                let installFile = "shoppingList_\(installScopedID).json"

                let installData = UserDefaults(suiteName: appGroupName)?.data(forKey: installKey)
                let installItemsFromDefaults: [ShoppingListItem] =
                    (installData.flatMap { try? JSONDecoder().decode([ShoppingListItem].self, from: $0) }) ?? []

                let installItemsFromFile: [ShoppingListItem] = (try? Data(contentsOf: localFileURL(forFileName: installFile)))
                    .flatMap { try? JSONDecoder().decode([ShoppingListItem].self, from: $0) } ?? []

                let merged = installItemsFromDefaults + installItemsFromFile
                if !merged.isEmpty {
                    shoppingListItems = merged
                    cleanupShoppingList()
                    markLocalChanged()
                    saveShoppingListToUserDefaults()
                    saveToFile()
                    Task { await syncToCloud() }
                }

                // Clear install-scoped storage so it can’t “come back”
                UserDefaults(suiteName: appGroupName)?.removeObject(forKey: installKey)
                try? FileManager.default.removeItem(at: localFileURL(forFileName: installFile))
            }

        } catch {
            // best-effort
        }
    }

    // MARK: - Persistence & Sync (Core Data + CloudKit mirroring)
    //
    // PHASE 3b CUTOVER.
    //
    // Deleted from here: the whole-list `CKAsset` blob. The entire shopping list —
    // every item, every photo — used to be one JSON blob in one CKRecord named
    // "ShoppingList", pushed with last-writer-wins. Two devices editing while one
    // was offline meant one device's additions were silently destroyed (P0-4), and
    // renaming a single item re-uploaded every photo on every item.
    //
    // Now: one Core Data row per item, merged per property by CloudKit.
    //
    // SOURCE OF TRUTH IS CORE DATA. The JSON file and the App Group UserDefaults
    // payload are still written — the latter is what the widget, Live Activity and
    // notification extension read, and that pipeline is untouched.

    private var storeContext: NSManagedObjectContext {
        PersistenceController.shared.container.viewContext
    }

    private var coreDataAvailable: Bool {
        !PersistenceController.shared.isDegraded
    }

    /// True while `reloadFromStore()` is assigning, so the Combine sink in
    /// `setupActiveSync()` does not immediately write the freshly-pulled data back
    /// into the store. Without this the remote-change observer and the save sink
    /// feed each other in a loop.
    private var isApplyingRemoteChange = false

    /// Assigns the array without triggering a persist round-trip.
    private func applyWithoutPersisting(_ items: [ShoppingListItem]) {
        lastPersistedIDs = Set(items.map(\.id))
        // Store change notifications fire for unrelated writes too; an identical
        // list must not republish or rewrite anything.
        guard items != shoppingListItems else { return }
        isApplyingRemoteChange = true
        shoppingListItems = items
        // Snapshot only. Going through the scheduled flush would write the
        // store again and trigger another reload — a feedback loop.
        writeAppGroupSnapshotNow(items)
        refreshWidgetSnapshots()
        isApplyingRemoteChange = false
    }

    private func startObservingRemoteChanges() {
        guard coreDataAvailable else { return }

        NotificationCenter.default
            .publisher(for: .NSPersistentStoreRemoteChange)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reloadFromStore() }
            }
            .store(in: &cancellables)
    }

    /// Rebuilds the published array from Core Data. The only path that refreshes
    /// the list from persistence.
    func reloadFromStore() {
        guard coreDataAvailable else { return }
        do {
            let rows = try storeContext.fetch(CDShoppingItem.fetchRequestForActiveItems())
            applyWithoutPersisting(rows.map { $0.toShoppingListItem() })
            // A successful read makes the store authoritative from here on.
            seedCompleted = true
            // Keep the rollback backup in step with the store so a stale file
            // can never reseed items that were deleted on another device.
            writeBackupJSON()
            // Items synced from a device without pack sizing get converted here.
            // Idempotent, so an already-converted list is a no-op (no sync loop).
            convertExistingItemsToPackSizes()
        } catch {
            print("[STORE ERROR] shopping reload failed: \(error.localizedDescription)")
        }
    }

    /// IDs that were in the array the last time it was loaded from, or
    /// persisted to, the store. Deletions are derived from this snapshot rather
    /// than from "whatever is in the store right now": a row that arrived from
    /// another device but has not reached the array yet is not something the
    /// user removed, and must not be soft-deleted by a save of the stale array.
    private var lastPersistedIDs: Set<UUID> = []

    /// Pushes an array into Core Data.
    ///
    /// - Upserts every item present.
    /// - Soft-deletes only the IDs that were in `lastPersistedIDs` and are now
    ///   absent, i.e. items the user removed since the last snapshot.
    /// - A row another device already soft-deleted stays deleted when the local
    ///   array still holds it from before the deletion synced (deletion wins over
    ///   a stale edit). An ID that is new to this device is an explicit re-add
    ///   and is restored.
    ///
    /// Returns `false` when the store refused the save; the change stays in the
    /// array and is retried on the next save opportunity.
    @discardableResult
    private func writeThroughToStore(_ items: [ShoppingListItem]? = nil) -> Bool {
        guard coreDataAvailable else { return false }
        let items = items ?? shoppingListItems
        let ctx = storeContext
        do {
            let present = Set(items.map(\.id))
            var survivors = present

            for item in items {
                let row = try ctx.upsertShoppingItem(id: item.id)
                if row.deletedAt != nil {
                    if lastPersistedIDs.contains(item.id) {
                        // Deleted elsewhere since we last saw it: the synced
                        // deletion wins. The next reload drops it from the array.
                        survivors.remove(item.id)
                        continue
                    }
                    row.deletedAt = nil  // explicit re-add / restore
                }
                row.apply(item, includingPhotos: false, in: ctx)
            }

            let removed = lastPersistedIDs.subtracting(present)
            if !removed.isEmpty {
                for row in try ctx.fetch(CDShoppingItem.fetchRequestForActiveItems()) {
                    guard let id = row.id, removed.contains(id) else { continue }
                    row.softDelete()
                }
            }

            guard PersistenceController.shared.saveIfNeeded(ctx) else {
                pendingDiskSave = true
                return false
            }
            lastPersistedIDs = survivors
            return true
        } catch {
            print("[STORE ERROR] shopping write-through failed: \(error.localizedDescription)")
            pendingDiskSave = true
            return false
        }
    }

    /// Photos as separate external-storage rows, written only when they change.
    private func writePhotosThroughToStore(id: UUID, photos: [Data]) {
        guard coreDataAvailable else { return }
        let ctx = storeContext
        do {
            let row = try ctx.upsertShoppingItem(id: id)
            row.replacePhotos(with: photos, in: ctx)
            if row.hasPersistentChangedValues || ctx.hasChanges { row.updatedAt = Date() }
            PersistenceController.shared.saveIfNeeded(ctx)
        } catch {
            print("[STORE ERROR] shopping photo write-through failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Compatibility shims

    /// Was: overwrite the whole-list CKAsset blob.
    func syncToCloud() async {
        writeThroughToStore()
    }

    /// Was: fetch the blob and replace the list if the cloud revision was newer.
    func syncFromCloud() async {
        reloadFromStore()
    }

    // MARK: - Combine

    private func setupActiveSync() {
        $shoppingListItems
            .dropFirst()
            .sink { [weak self] emitted in
                guard let self, !self.isApplyingRemoteChange else { return }
                // `@Published` emits from `willSet`, so `self.shoppingListItems`
                // still holds the PREVIOUS value here. The flush is deferred, so
                // it reads the property after the assignment has landed.
                self.scheduleFlush()
            }
            .store(in: &cancellables)
        observeLifecycleForFlush()

        // The 1.5s debounced push to the CKAsset blob is gone. Core Data batches
        // and schedules its own CloudKit exports.
        startObservingRemoteChanges()
    }
}
