//
//  ProductViewModel.swift
//  FrydgeRecipes
//
//  Created by Josh on 25/10/2024.
//

import SwiftUI
import Combine
import Foundation

class ProductViewModel: ObservableObject {
    @Published var showConfirmation = false
    @Published var showFoodNameConfirmation = false
    @Published var showEdibleConfirmation = false
    @Published var productName: String = ""
    @Published var ingredientsList: String = ""
    @Published var quantity: String = ""

    /// Set when both OFF and UPC Item DB fail — triggers AI label-scan prompt in the UI.
    @Published var unfoundBarcode: String? = nil

    var isManualEntry = false

    // MARK: - Fetch Product Details from Barcode
    func fetchProductDetails(barcode: String) {
        Task {
            // 1. OpenFoodFacts — best food/packaged goods coverage
            if let product = try? await OpenFoodFactsService.shared.fetchByBarcode(barcode) {
                await MainActor.run { self.handleFetchedProduct(product) }
                return
            }

            // 2. UPC Item DB — broader coverage (non-food, household, NZ-specific barcodes)
            if let item = try? await UPCItemDBService.shared.lookup(barcode) {
                await MainActor.run { self.handleFetchedProduct(item) }
                return
            }

            // 3. Both failed — signal the caller to fall back to label scanning
            await MainActor.run { self.handleFetchError(barcodeNotFound: barcode) }
        }
    }

    private func handleFetchedProduct(_ product: ProductProtocol) {
        self.productName = product.productName ?? "Unknown"
        self.ingredientsList = product.ingredientsList ?? "No ingredients listed."
        self.quantity = product.quantityValue != nil ? "\(product.quantityValue!)" : "Unknown quantity"
        self.showFoodNameConfirmation = true
    }

    private func handleFetchError(barcodeNotFound barcode: String) {
        print("[ProductViewModel] Both OFF and UPC Item DB returned nothing for barcode: \(barcode)")
        unfoundBarcode = barcode
    }

    // MARK: - Save Product to Inventory
    func saveProduct(isEdible: Bool) {
        let productType = isEdible ? "Edible" : "Non-Edible"
        print("[INFO] Saving \(productName) as \(productType) to inventory with quantity \(quantity).")
        // Add saving logic to inventory here
    }

    // MARK: - Handle Manual Product Entry
    func handleManualEntry(productName: String, ingredients: String, quantity: String) {
        self.isManualEntry = true
        self.productName = productName
        self.ingredientsList = ingredients
        self.quantity = quantity
        self.showFoodNameConfirmation = true
    }
}
