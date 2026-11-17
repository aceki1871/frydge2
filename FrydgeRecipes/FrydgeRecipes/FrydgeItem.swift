//
//  FridgeItem.swift
//  FrydgeRecipes
//
//  Created by Josh on 07/04/2025.
//


import Foundation

struct FrydgeItem: Identifiable, Codable {
    var id = UUID().uuidString
    var name: String
    var quantity: String
    var unit: String
    var expirationDate: Date
    var location: String  // Either "Fridge" or "Freezer"
}

