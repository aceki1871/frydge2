//
//  FridgeScanView.swift
//  FrydgeRecipes
//
//  Point the camera at the inside of the fridge and bulk-add everything
//  Apple Intelligence can identify in one photo. Reuses the same capture
//  flow as CookAlongView's "check my cooking" camera and the same review
//  list as ShoppingListScanView, so items can be unchecked or renamed
//  before anything is added.
//

import SwiftUI

struct FridgeScanView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var frydgeManager: FrydgeManager

    @State private var isCameraPresented = true
    @State private var isCaptured = false
    @State private var capturedImage: UIImage? = nil
    @State private var isProcessing = false
    @State private var scannedItems: [ScannedShoppingItem] = []
    @State private var hasScanned = false

    var body: some View {
        NavigationStack {
            Group {
                if isProcessing {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Looking in your fridge…")
                            .foregroundColor(.secondary)
                    }
                } else if hasScanned {
                    ShoppingListScanConfirmationView(
                        items: $scannedItems,
                        onConfirm: {
                            addSelectedItems()
                            dismiss()
                        },
                        onRescan: {
                            scannedItems = []
                            hasScanned = false
                            capturedImage = nil
                            isCameraPresented = true
                        }
                    )
                } else {
                    Color.clear
                }
            }
            .navigationTitle("Scan Your Fridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $isCameraPresented) {
            CameraCaptureView(isImageCaptured: $isCaptured, capturedImage: $capturedImage)
                .ignoresSafeArea()
        }
        .onChange(of: capturedImage) { _, image in
            guard let image else { return }
            isCameraPresented = false
            isProcessing = true
            Task {
                let detected = await detectItems(in: image)
                await MainActor.run {
                    scannedItems = detected.map { ScannedShoppingItem(name: $0.0, quantity: $0.1) }
                    hasScanned = true
                    isProcessing = false
                }
            }
        }
    }

    /// Returns `(name, quantity)` pairs so the result stays usable even on
    /// OS versions below the FoundationModels availability gate.
    private func detectItems(in image: UIImage) async -> [(String, String)] {
        guard let cgImage = image.cgImage else { return [] }
        if #available(iOS 26.0, *) {
            let detected = await FridgeScanService.shared.scan(cgImage)
            return detected.map { ($0.name, $0.quantity) }
        }
        return []
    }

    private func addSelectedItems() {
        for item in scannedItems where item.isSelected {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            frydgeManager.addProduct(
                name: name,
                quantity: item.quantity.isEmpty ? "1" : item.quantity,
                unit: "",
                expirationDate: StoredIngredient.defaultExpiry(for: name),
                location: "Fridge",
                dietaryTags: [],
                lifecycle: .fridge
            )
        }
    }
}
