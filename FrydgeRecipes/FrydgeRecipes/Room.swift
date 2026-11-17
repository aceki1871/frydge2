//
//  Room.swift
//  FrydgeRecipes
//
//  Created by Josh on 02/11/2024.
//


import Foundation

struct Room: Identifiable, Codable {
    var id: UUID
    var name: String
    var items: [RoomItem]
    
    init(id: UUID = UUID(), name: String, items: [RoomItem]) {
        self.id = id
        self.name = name
        self.items = items
    }
}

struct RoomItem: Identifiable, Codable {
    var id: UUID
    var name: String
    var isChecked: Bool
    
    init(id: UUID = UUID(), name: String, isChecked: Bool = false) {
        self.id = id
        self.name = name
        self.isChecked = isChecked
    }
}
