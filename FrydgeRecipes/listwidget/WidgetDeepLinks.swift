//
//  WidgetDeepLinks.swift
//  listwidget
//
//  Deep links the widgets and controls open in the main app, plus small
//  formatting helpers shared by every widget family. The app side of these
//  URLs is handled in FrydgeRecipesApp.handleRecipeImportDeepLink.
//

import Foundation

enum WidgetDeepLink {
    /// Opens the barcode scanner straight away (shopping context).
    static let scan = URL(string: "frydgerecipes://scan")!
    /// Opens the product search / add sheet without starting the camera.
    static let addProduct = URL(string: "frydgerecipes://add-product")!
    /// Jumps to the shopping list tab.
    static let shoppingList = URL(string: "frydgerecipes://shopping-list")!
    /// Opens the in-store basket (running total) over the shopping list.
    static let basket = URL(string: "frydgerecipes://basket")!

    /// Opens the detail sheet for one shopping item.
    static func item(_ item: WidgetSnapshotItem, storeName: String?) -> URL {
        var comps = URLComponents()
        comps.scheme = "frydgerecipes"
        comps.host = "item"
        comps.path = "/\(item.id)"
        var query = [URLQueryItem(name: "name", value: item.name)]
        if let storeName, !storeName.isEmpty {
            query.append(URLQueryItem(name: "store", value: storeName))
        }
        comps.queryItems = query
        return comps.url ?? shoppingList
    }
}

enum WidgetFormat {
    /// "$23.40" in the snapshot's currency.
    static func money(_ value: Double, currencyCode: String) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = currencyCode
        nf.maximumFractionDigits = 2
        nf.minimumFractionDigits = 2
        return nf.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    /// Quantity chip text: "×2" for count-like units, "500 g" otherwise.
    static func quantity(for item: WidgetSnapshotItem, in snapshot: WidgetSnapshot) -> String? {
        if let qty = snapshot.effectiveQuantity(for: item) {
            let number = qty.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(qty))
                : String(format: "%.1f", qty)
            let unit = (item.unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if item.isCountLike { return "×\(number)" }
            return "\(number) \(unit)"
        }
        if let display = item.displayQuantity, !display.isEmpty {
            return display.replacingOccurrences(of: "x", with: "×")
        }
        return nil
    }

    /// Price line for an item, appending the store when it differs from the
    /// widget's headline store.
    static func priceLine(for item: WidgetSnapshotItem, headlineStore: String?) -> String? {
        guard let price = item.priceText, !price.isEmpty else { return nil }
        let itemBrand = StoreBrand.resolve(item.priceStoreName)
        let headlineBrand = StoreBrand.resolve(headlineStore)
        if itemBrand.assetName == nil || itemBrand == headlineBrand {
            return price
        }
        return "\(price) · \(itemBrand.displayName)"
    }
}
