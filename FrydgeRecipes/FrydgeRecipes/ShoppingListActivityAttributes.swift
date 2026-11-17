//
//  ShoppingListActivityAttributes.swift
//  FrydgeRecipes
//
//  Created by Josh on 26/04/2025.
//

import ActivityKit
import Foundation
import SwiftUI

struct ShoppingListActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var shoppingListItems: [String]
        var checkedItems: [String]

        /// The store currently being shopped. Lives in the content state — NOT
        /// only in the attributes — because attributes are immutable for the
        /// life of the activity. Driving from store A to store B must retarget
        /// the same activity (name, logo, prices) via a plain update.
        /// Optional so payloads without it (older worker pushes) still decode;
        /// views fall back to `attributes.storeName`.
        var storeName: String? = nil

        /// Food emoji per item string, so Live Activity rows look like the
        /// widget's rows. Optional: worker pushes don't send it, and rows
        /// simply omit the emoji when it's missing.
        var itemEmojis: [String: String]? = nil

        /// Item strings (same form as `shoppingListItems` entries) the store
        /// in `storeName` doesn't sell, per the app's in-store availability
        /// check. Rows for these render greyed out. Optional so older
        /// payloads and worker pushes decode unchanged.
        var unavailableItems: [String]? = nil

        /// Non-nil while a recipe is being cooked. The Live Activity then
        /// switches to cook mode (current step, live timer, "still to grab"
        /// strip) and takes priority over the plain shopping layout — on the
        /// Lock Screen too, so the cook stays on track with the phone locked
        /// or while nipping out to the shop for a missing ingredient.
        var cooking: CookingState? = nil
    }

    struct CookingState: Codable, Hashable {
        var recipeName: String
        var recipeEmoji: String
        var stepIndex: Int
        var stepCount: Int
        var stepText: String
        var startedAt: Date
        /// Set while the current step's timer is running. The Live Activity
        /// counts down from these on its own, so it keeps ticking even when
        /// the app is suspended in the background.
        var timerStartedAt: Date? = nil
        var timerEndsAt: Date? = nil
    }

    /// The store the activity was originally started for. Frozen by ActivityKit —
    /// prefer `content.state.storeName` when present.
    var storeName: String
}
