//
//  ShoppingItem.swift
//  FrydgeRecipes
//
//  Created by Josh on 04/11/2024.
//


import Foundation

struct ShoppingItem: Identifiable, Codable {
    var id: UUID
    var name: String
    var isChecked: Bool = false

    init(id: UUID = UUID(), name: String, isChecked: Bool = false) {
        self.id = id
        self.name = name
        self.isChecked = isChecked
    }
}
