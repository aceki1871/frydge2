//
//  FrydgeTickShoppingListItemIntent.swift
//  FrydgeRecipes
//
//  Siri / App Shortcuts entry points for the shopping list.
//
//  NOTE: The Live Activity tick intent is defined in
//  FrydgeRecipesLiveActivityBundle.swift (it must live in the extension).
//  This file holds the in-app intents: adding items by voice.
//
//  "Hey Siri, add to Frydge" → Siri asks "What should I add?" → user dictates
//  "milk, bread and eggs" → three items land on the shopping list.
//
//  An open-ended item name cannot be embedded in the trigger phrase itself —
//  Siri only supports in-phrase parameters for finite AppEnum/AppEntity values —
//  so the item is collected via the follow-up dialog instead.
//

import AppIntents
import Foundation

// MARK: - Add by voice

struct FrydgeAddShoppingItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Shopping List"
    static let description = IntentDescription(
        "Adds one or more items to your Frydge shopping list. Separate multiple items with commas.",
        categoryName: "Shopping List"
    )
    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Items",
        requestValueDialog: "What should I add to your shopping list?"
    )
    var items: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$items) to the shopping list")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Prefer the app's live manager; fall back to a fresh one when Siri
        // launched us in the background before any UI existed. Its init loads
        // the current list first, so the add merges rather than overwrites.
        let manager = ShoppingListManager.current ?? ShoppingListManager()

        // "milk, bread and eggs" → ["milk", "bread", "eggs"]
        let parts = items
            .replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else {
            return .result(dialog: "I didn't catch anything to add.")
        }

        for part in parts {
            manager.addToShoppingList(part)
        }

        let spoken = parts.count == 1
            ? parts[0]
            : ListFormatter.localizedString(byJoining: parts)
        return .result(dialog: "Added \(spoken) to your shopping list.")
    }
}

// MARK: - App Shortcuts (zero-setup Siri phrases)

struct FrydgeAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FrydgeAddShoppingItemIntent(),
            phrases: [
                "Add to \(.applicationName)",
                "Add to my \(.applicationName) list",
                "Add to my \(.applicationName) shopping list",
                "Add items to \(.applicationName)",
                "Add something to my \(.applicationName) shopping list",
            ],
            shortTitle: "Add to Shopping List",
            systemImageName: "cart.badge.plus"
        )
    }
}
