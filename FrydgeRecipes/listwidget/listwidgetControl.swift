//
//  listwidgetControl.swift
//  listwidget
//
//  Control Center / Lock Screen / Action button controls. Each one opens
//  Frydge at a deep link via a foreground App Intent.
//

import AppIntents
import SwiftUI
import WidgetKit

/// Opens the barcode scanner. Ideal on the Action button or Lock Screen.
struct FrydgeScanControl: ControlWidget {
    static let kind: String = "Clark-Online.Recipes.listwidget.scan"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: FrydgeOpenScannerIntent()) {
                Label("Scan Barcode", systemImage: "barcode.viewfinder")
            }
        }
        .displayName("Scan Barcode")
        .description("Open the Frydge barcode scanner to add a product.")
    }
}

/// Opens the add-product sheet (search without the camera).
struct FrydgeAddProductControl: ControlWidget {
    static let kind: String = "Clark-Online.Recipes.listwidget.add"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: FrydgeOpenAddProductIntent()) {
                Label("Add to List", systemImage: "cart.badge.plus")
            }
        }
        .displayName("Add to Shopping List")
        .description("Open Frydge ready to add a product to your shopping list.")
    }
}

/// Opens the in-store basket with the running total.
struct FrydgeBasketControl: ControlWidget {
    static let kind: String = "Clark-Online.Recipes.listwidget.basket"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: FrydgeOpenBasketIntent()) {
                Label("Basket", systemImage: "basket.fill")
            }
        }
        .displayName("Shopping Basket")
        .description("Open the Frydge in-store basket with your running total.")
    }
}
