import Foundation

/// Three-way merge for a shared shopping list stored as one JSON blob on a
/// CloudKit anchor record.
///
/// Shared lists are written whole-list (`itemsJSON`), so two household members
/// editing at once produce `serverRecordChanged`. Before this merge the losing
/// save simply failed and that member's change evaporated. CloudKit hands back
/// the common ancestor, our client record and the server's current record, which
/// is enough to merge per item instead of picking a winner.
///
/// Rules, applied per item key (stable item id, or a name-derived key for lists
/// that predate ids):
/// - added on either side since the ancestor → kept
/// - deleted on either side since the ancestor → stays deleted; a synced deletion
///   wins over a concurrent stale edit, matching the personal-list policy
/// - present on both and edited here → this device's version wins
/// - present on both and unchanged here → the server's version is taken
///
/// Output order is this device's order, with items the other side added appended
/// in their order. With no ancestor available the result is a union; nothing is
/// dropped because deletions cannot be told apart from additions.
enum SharedListMerge {
    struct Keyed: Equatable {
        let key: String
        let item: SharedShoppingListItem
    }

    static func merge(base: [Keyed], ours: [Keyed], theirs: [Keyed]) -> [SharedShoppingListItem] {
        var baseByKey: [String: SharedShoppingListItem] = [:]
        for k in base where baseByKey[k.key] == nil { baseByKey[k.key] = k.item }

        var theirsByKey: [String: SharedShoppingListItem] = [:]
        for k in theirs where theirsByKey[k.key] == nil { theirsByKey[k.key] = k.item }

        var result: [SharedShoppingListItem] = []
        var seen: Set<String> = []

        for k in ours {
            guard seen.insert(k.key).inserted else { continue }

            if let theirItem = theirsByKey[k.key] {
                // On both sides. Keep ours if we changed it, otherwise take theirs
                // so another member's edit to an item we left alone survives.
                if let baseItem = baseByKey[k.key], baseItem == k.item {
                    result.append(theirItem)
                } else {
                    result.append(k.item)
                }
            } else if baseByKey[k.key] != nil {
                // Was in the ancestor, gone on the server: the other side deleted
                // it. Deletion wins over our stale copy.
                continue
            } else {
                // Not in the ancestor and not on the server: we added it.
                result.append(k.item)
            }
        }

        for k in theirs where !seen.contains(k.key) {
            seen.insert(k.key)
            // In the ancestor but missing from ours: we deleted it, stays deleted.
            if baseByKey[k.key] != nil { continue }
            // Otherwise the other side added it.
            result.append(k.item)
        }

        return result
    }
}
