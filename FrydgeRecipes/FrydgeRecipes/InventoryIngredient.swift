//
//  InventoryIngredient.swift
//  FrydgeRecipes
//
//  Created by Josh on 21/10/2024.
//


import Foundation
import CloudKit

struct InventoryIngredient: Identifiable, Codable {
    let id: UUID
    var name: String
    var quantity: Double
    var unit: String

    init(name: String, quantity: Double, unit: String) {
        self.id = UUID()
        self.name = name
        self.quantity = quantity
        self.unit = unit
    }

    init(record: CKRecord) {
        self.id = UUID()
        self.name = record["name"] as? String ?? "Unknown Ingredient"
        self.quantity = record["quantity"] as? Double ?? 0.0
        self.unit = record["unit"] as? String ?? "g"
    }

    func toCKReference() -> CKRecord.Reference {
        return CKRecord.Reference(recordID: CKRecord.ID(recordName: self.id.uuidString), action: .none)
    }
}