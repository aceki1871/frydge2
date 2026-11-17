//
//  FridgeScanService.swift
//  FrydgeRecipes
//
//  Uses Apple's on-device Foundation Models (Apple Intelligence, iOS 26+) to
//  identify food items visible in a single photo of a fridge's contents, so
//  the whole fridge can be added in one go instead of item by item.
//

import Foundation
import CoreGraphics
#if canImport(FoundationModels)
import FoundationModels
#endif

@available(iOS 26.0, *)
@Generable(description: "A single food item visible in a photo of a fridge's contents")
struct DetectedFridgeItem {
    @Guide(description: "The food name as a shopper would recognise it, e.g. 'Milk', 'Carrots', 'Leftover pasta'. Skip brand names unless the product is only identifiable by its brand.")
    var name: String

    @Guide(description: "Approximate quantity visible, e.g. '2', '1 bottle', '500g'. Use '1' if unclear.")
    var quantity: String
}

@available(iOS 26.0, *)
@Generable(description: "Food items identified in a photo of a fridge's contents")
struct FridgeScanResult {
    @Guide(description: "Every distinct food item clearly visible in the photo, one entry per item or group of identical items")
    var items: [DetectedFridgeItem]
}

@available(iOS 26.0, *)
final class FridgeScanService {
    static let shared = FridgeScanService()
    private init() {}

    /// Identifies food items visible in a photo of the inside of a fridge.
    /// Returns an empty array if Apple Intelligence is unavailable or nothing is recognised.
    func scan(_ image: CGImage) async -> [DetectedFridgeItem] {
        guard FrydgeIntelligence.isAvailable else {
            print("[FridgeScanService] Apple Intelligence not available.")
            return []
        }

        let session = LanguageModelSession(instructions: """
            You identify food items visible in a photo of the inside of a fridge.
            List every distinct food item you can clearly see, with its approximate quantity.
            Group identical items together into one entry rather than listing duplicates separately.
            Ignore non-food items, unreadable packaging, and anything not clearly visible.
            Never invent items that aren't visible in the photo.
            """)

        do {
            let response = try await session.respond(generating: FridgeScanResult.self) {
                "Identify the food items in this photo of a fridge:"
                Attachment(image)
            }
            return response.content.items.filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        } catch {
            print("[FridgeScanService] Scan error: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - Availability check (callable from non-available contexts)

enum FridgeScanAvailability {
    /// Returns true if the device can use FridgeScanService.
    static var isSupported: Bool {
        FrydgeIntelligence.isAvailable
    }
}
