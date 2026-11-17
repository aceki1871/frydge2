//
//  StoreChain.swift
//  FrydgeRecipes
//
//  One place that turns any store string — a geofence identifier
//  ("Woolworths Mt Wellington"), a worker offer ("PAK'nSAVE"), a receipt
//  header ("Countdown Glenfield") — into a stable chain key, so the rest of
//  the app can ask "is this the same shop?" without string-matching.
//
//  Moved out of ShoppingListView (where it was the private `InStoreBrand`)
//  so the in-store availability work can share it.
//

import Foundation

enum StoreChain {

    /// Stable lowercase key per chain. Countdown and Woolworths share a key
    /// because they're the same shelves under two names.
    static func key(for storeName: String) -> String {
        let s = storeName.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "'", with: "")
        if s.contains("pak") && s.contains("save") { return "paknsave" }
        if s.contains("woolworth") || s.contains("countdown") || s.contains("woolies") { return "woolworths" }
        if s.contains("new world") || s.contains("newworld") { return "newworld" }
        if s.contains("four square") || s.contains("foursquare") { return "foursquare" }
        if s.contains("tesco") { return "tesco" }
        if s.contains("sainsbury") { return "sainsburys" }
        if s.contains("waitrose") { return "waitrose" }
        if s.contains("co-op") || s.contains("coop") { return "coop" }
        if s.contains("morrison") { return "morrisons" }
        if s.contains("asda") { return "asda" }
        if s.contains("aldi") { return "aldi" }
        if s.contains("lidl") { return "lidl" }
        if s.contains("iceland") { return "iceland" }
        if s.contains("marks") && s.contains("spencer") || s.hasPrefix("m&s") { return "marksandspencer" }
        return s.split(separator: " ").first.map(String.init) ?? s
    }

    /// Brand name for headings ("Pak’nSave"), falling back to the full name.
    static func shortName(for storeName: String) -> String {
        switch key(for: storeName) {
        case "paknsave":        return "Pak’nSave"
        case "woolworths":      return storeName.lowercased().contains("countdown") ? "Countdown" : "Woolworths"
        case "newworld":        return "New World"
        case "foursquare":      return "Four Square"
        case "tesco":           return "Tesco"
        case "sainsburys":      return "Sainsbury’s"
        case "waitrose":        return "Waitrose"
        case "coop":            return "Co-op"
        case "morrisons":       return "Morrisons"
        case "asda":            return "Asda"
        case "aldi":            return "Aldi"
        case "lidl":            return "Lidl"
        case "iceland":         return "Iceland"
        case "marksandspencer": return "M&S"
        default:                return storeName
        }
    }

    /// Chains that carry the full grocery range. Used by the staple rule:
    /// a generic food (milk, eggs, onions) is assumed stocked at any of these
    /// even when no price or receipt says so. Pharmacies and the like are not
    /// in here on purpose.
    static let supermarketKeys: Set<String> = [
        "paknsave", "woolworths", "newworld", "foursquare",
        "tesco", "sainsburys", "waitrose", "coop", "morrisons",
        "asda", "aldi", "lidl", "iceland", "marksandspencer"
    ]

    static func isSupermarket(_ key: String) -> Bool {
        supermarketKeys.contains(key)
    }

    /// One entry per chain for the Profile "Shopping at" picker. NZ first
    /// (the home market), then UK.
    struct Pickable: Identifiable, Hashable {
        let key: String
        let name: String
        var id: String { key }
    }

    static let pickable: [Pickable] = [
        Pickable(key: "woolworths",      name: "Woolworths / Countdown"),
        Pickable(key: "paknsave",        name: "Pak’nSave"),
        Pickable(key: "newworld",        name: "New World"),
        Pickable(key: "foursquare",      name: "Four Square"),
        Pickable(key: "tesco",           name: "Tesco"),
        Pickable(key: "sainsburys",      name: "Sainsbury’s"),
        Pickable(key: "waitrose",        name: "Waitrose"),
        Pickable(key: "asda",            name: "Asda"),
        Pickable(key: "morrisons",       name: "Morrisons"),
        Pickable(key: "coop",            name: "Co-op"),
        Pickable(key: "aldi",            name: "Aldi"),
        Pickable(key: "lidl",            name: "Lidl"),
        Pickable(key: "iceland",         name: "Iceland"),
        Pickable(key: "marksandspencer", name: "M&S")
    ]

    /// Canonical store name for a chain key, used as the session's store name
    /// for a manual pick. Deliberately the plain brand ("Woolworths"), not the
    /// picker label ("Woolworths / Countdown"), so `shortName(for:)` and the
    /// logo lookup resolve it like any geofenced store name.
    static func displayName(forKey key: String) -> String {
        switch key {
        case "woolworths": return "Woolworths"
        default:
            return pickable.first { $0.key == key }?.name ?? key.capitalized
        }
    }
}
