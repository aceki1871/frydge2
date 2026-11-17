//
//  Notifications.swift
//  FrydgeRecipes
//
//  Created by Josh on 13/01/2026.


import Foundation

extension Notification.Name {
    static let recipeDidSave    = Notification.Name("recipeDidSave")
    static let showLeftoverSheet = Notification.Name("frydge.showLeftoverSheet")
    /// Posted (userInfo["recipeID"]) when a notification asks the app to open a recipe.
    static let openRecipe        = Notification.Name("frydge.openRecipe")
    /// Posted (userInfo: ShoppingNotificationKeys entry) when the store-arrival
    /// notification asks the app to open a shopping item's detail sheet.
    static let openShoppingItem  = Notification.Name("frydge.openShoppingItem")
    /// Posted when the user arrives at a monitored supermarket (geofence
    /// entry, or the store-arrival notification was tapped). userInfo:
    /// `StoreArrivalKeys`. The app answers by switching on basket mode.
    static let storeArrived      = Notification.Name("frydge.storeArrived")
    /// Posted by the app delegate when a notification wants the shopping list tab.
    static let navigateToShoppingList = Notification.Name("NavigateToShoppingList")
}

/// userInfo keys for `.storeArrived`.
enum StoreArrivalKeys {
    /// Full monitored store name ("Pak’nSave Sylvia Park").
    static let storeName = "storeName"
    /// `Bool` — true when the user tapped the arrival notification (so the
    /// basket opens regardless of the foreground auto-open cooldown).
    static let fromNotification = "fromNotification"
    /// Standard-defaults key the delegate parks the store under so a cold
    /// launch from the notification still lands in the basket.
    static let pendingOpenBasket = "frydge.pendingOpenBasketStore"
}

/// Keys shared between the store-arrival shopping notification and the
/// ShoppingListNotificationExtension. The extension is a separate target and
/// mirrors these strings by hand in NotificationViewController.swift — keep
/// both in sync.
enum ShoppingNotificationKeys {
    /// userInfo: full store name as monitored ("Pak’nSave Sylvia Park").
    static let storeName = "storeName"
    /// userInfo: street address / vicinity line for the store.
    static let storeLocation = "storeLocation"
    /// userInfo: asset-catalog name of the brand mark (optional override).
    static let storeLogo = "storeLogo"
    /// userInfo: `[[String: String]]` rows with id, name, fullName, emoji,
    /// quantity, unit, price, imageURL.
    static let shoppingItems = "shoppingItems"

    /// App-group UserDefaults key the content extension writes when an item
    /// name is tapped: `["id", "name", "fullName", "store"]`.
    static let tappedItem = "notificationOpenShoppingItem_v1"
    /// Standard-defaults key the app delegate hands the tapped item to the
    /// SwiftUI app with, so a cold launch can still pick it up.
    static let pendingOpenItem = "frydge.pendingOpenShoppingItem"
}
