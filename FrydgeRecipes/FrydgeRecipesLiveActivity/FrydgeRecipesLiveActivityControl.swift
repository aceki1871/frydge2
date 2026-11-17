//
//  FrydgeRecipesLiveActivityControl.swift
//  FrydgeRecipesLiveActivity
//
//  Created by Josh on 26/04/2025.
//

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// One source of truth for the App Group the app and extension share.
enum FrydgeAppGroup {
    static let primary = "group.Clark-Online.FrydgeRecipeAPN"
    static let checkedItemsKey = "checkedShoppingListItems"
    /// Keys the app may use for the current store; the first non-empty one wins.
    static let storeNameKeys = ["currentStoreName", "selectedStoreName",
                                "lastStoreName", "storeName"]

    /// The store the shopper is at, or "" when the app hasn't written one
    /// (the banner then reads "Nearest store").
    static func loadStoreName() -> String {
        guard let ud = UserDefaults(suiteName: primary) else { return "" }
        for key in storeNameKeys {
            if let value = ud.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return ""
    }
}

struct FrydgeRecipesLiveActivityControl: ControlWidget {
    static let kind: String = "Clark-Online.Recipes.FrydgeRecipesLiveActivity"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: Self.kind,
            provider: Provider()
        ) { value in
            // Tapping the control runs a LiveActivityIntent, which the system is
            // allowed to execute in the background — so the shopping-list Live
            // Activity starts on the Lock Screen without opening the app.
            ControlWidgetButton(
                action: StartShoppingListLiveActivityIntent(storeName: value.storeName)
            ) {
                Label(
                    value.hasItems ? value.label : value.emptyLabel,
                    systemImage: value.hasItems ? "cart.fill" : "cart"
                )
            }
        }
        .displayName("Shopping List")
        .description("Starts a shopping list Live Activity on your Lock Screen — no need to open the app.")
    }
}

extension FrydgeRecipesLiveActivityControl {
    struct Value {
        var hasItems: Bool
        var title: String
        /// The store to brand the banner with. Not `title`, which is the
        /// configured list name ("Shopping List") and matches no chain.
        var storeName: String
        var label: String
        var emptyLabel: String
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: ShoppingListConfiguration) -> Value {
            let configuredTitle = configuration.listName.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = configuredTitle.isEmpty ? "Shopping List" : configuredTitle
            return FrydgeRecipesLiveActivityControl.Value(
                hasItems: true,
                title: title,
                storeName: FrydgeAppGroup.loadStoreName(),
                label: "3 items",
                emptyLabel: "Empty"
            )
        }

        func currentValue(configuration: ShoppingListConfiguration) async throws -> Value {
            let count = FrydgeShoppingListControlStorage.loadStructuredList().count
            let configuredTitle = configuration.listName.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = configuredTitle.isEmpty ? "Shopping List" : configuredTitle
            let label = count == 0 ? "Empty" : "\(count) item\(count == 1 ? "" : "s")"
            return FrydgeRecipesLiveActivityControl.Value(
                hasItems: count > 0,
                title: title,
                storeName: FrydgeAppGroup.loadStoreName(),
                label: label,
                emptyLabel: "Empty"
            )
        }
    }
}

struct ShoppingListConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Shopping List Configuration"
    static let description: IntentDescription? = IntentDescription("Configure your shopping list control")

    @Parameter(title: "List Name", default: "Shopping List")
    var listName: String

    init() {
        self.listName = "Shopping List"
    }

    init(listName: String) {
        self.listName = listName
    }
}

/// Starts the shopping-list Live Activity from the Control Center control.
///
/// Because this conforms to `LiveActivityIntent`, the system launches the app
/// process (without bringing it to the foreground), runs `perform()`, and lets
/// it call `Activity.request` — the one sanctioned way to start a Live Activity
/// while the app isn't in the foreground.
struct StartShoppingListLiveActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Shopping List"
    static let description = IntentDescription("Starts a shopping list Live Activity on your Lock Screen.")
    static let openAppWhenRun: Bool = false
    static let isDiscoverable: Bool = true

    @Parameter(title: "Store Name")
    var storeName: String

    init() {
        self.storeName = ""
    }

    init(storeName: String) {
        self.storeName = storeName
    }

    func perform() async throws -> some IntentResult {
        // Respect the user's Live Activities permission.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return .result()
        }

        // Don't start a duplicate if a shopping Live Activity is already running.
        let alreadyRunning = Activity<ShoppingListActivityAttributes>.activities.contains {
            $0.activityState == .active || $0.activityState == .stale
        }
        guard !alreadyRunning else { return .result() }

        // Build the initial list from the shared App Group storage.
        let items = FrydgeShoppingListControlStorage.loadStructuredList().map { $0.displayString }

        let attributes = ShoppingListActivityAttributes(storeName: storeName)
        let content = ActivityContent(
            state: ShoppingListActivityAttributes.ContentState(
                shoppingListItems: items,
                checkedItems: []
            ),
            staleDate: nil
        )

        _ = try Activity<ShoppingListActivityAttributes>.request(
            attributes: attributes,
            content: content,
            pushType: nil
        )

        return .result()
    }
}

struct OpenShoppingListIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Open shopping list"
    static let openAppWhenRun = true

    @Parameter(title: "List Label")
    var name: String

    @Parameter(title: "List has items")
    var value: Bool

    init() {
        self.name = ""
        self.value = false
    }

    init(_ name: String) {
        self.name = name
        self.value = false
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        return .result()
    }
}

enum FrydgeShoppingListControlStorage {
    static let appGroupSuiteName = FrydgeAppGroup.primary
    static let legacyShoppingListKey = "shoppingList"
    static let structuredShoppingListKey = "shoppingListItemsJSON"
    static let legacySharedShoppingListKey = "sharedShoppingList"
    static let structuredSharedShoppingListKey = "sharedShoppingListItemsJSON"

    struct WidgetShoppingItem: Codable, Hashable, Identifiable {
        let id: String
        let name: String
        let quantity: String
        let unit: String

        var displayString: String {
            let name = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let qty  = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
            let unit = self.unit.trimmingCharacters(in: .whitespacesAndNewlines)

            // Format "ea" units as "x1", "x2", etc. instead of "1 ea"
            if unit.lowercased() == "ea", !qty.isEmpty {
                return name.isEmpty ? "x\(qty)" : "\(name) x\(qty)"
            }

            var parts = [name]
            if !qty.isEmpty { parts.append(qty) }
            if !unit.isEmpty { parts.append(unit) }
            return parts.filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private static func dedupe(_ list: [WidgetShoppingItem]) -> [WidgetShoppingItem] {
        var seen: Set<String> = []
        var out: [WidgetShoppingItem] = []
        out.reserveCapacity(list.count)

        for item in list {
            let key = item.displayString
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(item)
        }

        return out
    }

    static func loadStructuredList() -> [WidgetShoppingItem] {
        guard let ud = UserDefaults(suiteName: appGroupSuiteName) else { return [] }

        func decodeStructured(_ key: String) -> [WidgetShoppingItem] {
            if let json = ud.string(forKey: key),
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([WidgetShoppingItem].self, from: data) {
                return decoded
            }

            if let data = ud.data(forKey: key),
               let decoded = try? JSONDecoder().decode([WidgetShoppingItem].self, from: data) {
                return decoded
            }

            return []
        }

        func decodeLegacy(_ key: String) -> [WidgetShoppingItem] {
            let legacy = (ud.array(forKey: key) as? [String]) ?? []
            return legacy.map {
                WidgetShoppingItem(
                    id: UUID().uuidString,
                    name: $0,
                    quantity: "",
                    unit: ""
                )
            }
        }

        let mineStructured = decodeStructured(structuredShoppingListKey)
        let sharedStructured = decodeStructured(structuredSharedShoppingListKey)
        let mineLegacy = decodeLegacy(legacyShoppingListKey)
        let sharedLegacy = decodeLegacy(legacySharedShoppingListKey)

        let combinedStructured = mineStructured + sharedStructured
        if !combinedStructured.isEmpty {
            return dedupe(combinedStructured)
        }

        return dedupe(mineLegacy + sharedLegacy)
    }
}
