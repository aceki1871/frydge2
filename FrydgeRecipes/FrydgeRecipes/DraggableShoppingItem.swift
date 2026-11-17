//
//  DraggableShoppingItem.swift
//  FrydgeRecipes
//
//  Created on 29/04/2026.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Draggable Shopping Item Type

/// UTType for shopping list items to enable drag-and-drop
extension UTType {
    static let shoppingListItem = UTType(exportedAs: "com.clark-online.frydgerecipes.shoppingitem")
    static let fridgeItem = UTType(exportedAs: "com.clark-online.frydgerecipes.fridgeitem")
}

// MARK: - Draggable Fridge Item (Mine ⇄ Shared frydge)

/// Payload dragged when moving a fridge item between the personal ("Mine") fridge
/// and a shared frydge. `fromSharedAnchorRecordName` is nil for a Mine item, or the
/// owning shared-frydge anchor's record name when dragged out of a shared frydge.
struct DraggableFridgeItem: Codable, Transferable {
    let id: String            // StoredIngredient UUID (Mine) or CKRecord name (shared)
    let name: String
    let quantity: String
    let unit: String
    let location: String
    let dietaryTags: [String]
    let expirationDate: Date
    let fromSharedAnchorRecordName: String?
    /// StoredIngredient.ItemLifecycle raw value; optional so payloads from
    /// builds without the field still decode.
    let lifecycle: String?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .fridgeItem)
    }

    init(
        id: String,
        name: String,
        quantity: String,
        unit: String,
        location: String,
        dietaryTags: [String],
        expirationDate: Date,
        fromSharedAnchorRecordName: String?,
        lifecycle: String? = nil
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.location = location
        self.dietaryTags = dietaryTags
        self.expirationDate = expirationDate
        self.fromSharedAnchorRecordName = fromSharedAnchorRecordName
        self.lifecycle = lifecycle
    }

    /// Build from a personal (Mine) stored item.
    init(from item: StoredIngredient) {
        self.init(
            id: item.id.uuidString,
            name: item.name,
            quantity: item.quantity,
            unit: item.unit,
            location: item.location,
            dietaryTags: Array(item.dietaryTags),
            expirationDate: item.expirationDate,
            fromSharedAnchorRecordName: nil,
            lifecycle: item.lifecycle.rawValue
        )
    }
}

// MARK: - Transferable Shopping Item

/// Wrapper to make shopping items draggable
struct DraggableShoppingItem: Codable, Transferable {
    let id: UUID
    let name: String
    let quantity: String
    let unit: String
    let location: String
    let dietaryTags: [String]
    
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .shoppingListItem)
    }
    
    init(from item: ShoppingListItem) {
        self.id = item.id
        self.name = item.name
        self.quantity = item.quantity
        self.unit = item.unit
        self.location = item.location
        self.dietaryTags = Array(item.dietaryTags)
    }
    
    func toShoppingListItem() -> ShoppingListItem {
        ShoppingListItem(
            id: id,
            name: name,
            quantity: quantity,
            unit: unit,
            location: location,
            dietaryTags: Set(dietaryTags)
        )
    }
    
    func toSharedShoppingListItem() -> SharedShoppingListItem {
        SharedShoppingListItem(
            name: name,
            quantity: quantity,
            unit: unit,
            location: location,
            dietaryTags: dietaryTags
        )
    }
}

// MARK: - Drop Target for Shared Lists

struct SharedListDropTarget: Identifiable {
    let id: UUID
    let anchorID: String
    let name: String
    
    init(anchorID: String, name: String) {
        self.id = UUID()
        self.anchorID = anchorID
        self.name = name
    }
}

// MARK: - Drag State Manager

@MainActor
class DragState: ObservableObject {
    @Published var isDragging = false
    @Published var draggedItem: DraggableShoppingItem?
    @Published var dropTargetHighlighted: String? = nil
    
    func startDrag(_ item: DraggableShoppingItem) {
        isDragging = true
        draggedItem = item
    }
    
    func endDrag() {
        isDragging = false
        draggedItem = nil
        dropTargetHighlighted = nil
    }
    
    func highlightTarget(_ targetID: String) {
        dropTargetHighlighted = targetID
    }
    
    func clearHighlight() {
        dropTargetHighlighted = nil
    }
}
