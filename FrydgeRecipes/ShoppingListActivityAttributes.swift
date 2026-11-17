//
//  ShoppingListActivityAttributes.swift
//  FrydgeRecipesLiveActivityExtension
//
//  Shared ActivityAttributes for shopping list Live Activities
//

import Foundation
import ActivityKit

/// Activity attributes for the shopping list Live Activity
struct ShoppingListActivityAttributes: ActivityAttributes {
    /// Name of the store where the user is shopping
    let storeName: String
    
    /// Content state that can be updated during the Live Activity
    struct ContentState: Codable, Hashable {
        /// List of shopping items to display
        var shoppingListItems: [String]
        
        /// Items that have been checked off
        var checkedItems: [String]
    }
}
