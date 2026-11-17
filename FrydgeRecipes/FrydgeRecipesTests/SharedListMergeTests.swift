//
//  SharedListMergeTests.swift
//  FrydgeRecipesTests
//
//  Two household members editing one shared shopping list at the same time
//  used to lose the second writer's change. These pin down the three-way merge
//  that resolves CloudKit's serverRecordChanged instead.
//

import Foundation
import Testing
@testable import FrydgeRecipes

struct SharedListMergeTests {

    private func item(_ name: String, quantity: String = "1", id: UUID = UUID()) -> SharedShoppingListItem {
        var i = SharedShoppingListItem(name: name)
        i.id = id
        i.quantity = quantity
        return i
    }

    private func keyed(_ items: [SharedShoppingListItem]) -> [SharedListMerge.Keyed] {
        items.map { SharedListMerge.Keyed(key: $0.id.uuidString, item: $0) }
    }

    @Test func additionsOnBothSidesSurvive() {
        let milk = item("Milk")
        let bread = item("Bread")
        let eggs = item("Eggs")

        let merged = SharedListMerge.merge(
            base: keyed([milk]),
            ours: keyed([milk, bread]),
            theirs: keyed([milk, eggs])
        )

        #expect(merged.map(\.name) == ["Milk", "Bread", "Eggs"])
    }

    @Test func remoteDeletionWinsOverStaleLocalCopy() {
        let milk = item("Milk")
        let bread = item("Bread")

        // They deleted bread; we still have it and added nothing.
        let merged = SharedListMerge.merge(
            base: keyed([milk, bread]),
            ours: keyed([milk, bread]),
            theirs: keyed([milk])
        )

        #expect(merged.map(\.name) == ["Milk"])
    }

    @Test func localDeletionIsNotResurrectedByServerCopy() {
        let milk = item("Milk")
        let bread = item("Bread")

        let merged = SharedListMerge.merge(
            base: keyed([milk, bread]),
            ours: keyed([milk]),
            theirs: keyed([milk, bread])
        )

        #expect(merged.map(\.name) == ["Milk"])
    }

    @Test func ourEditWinsWhenWeChangedTheItem() {
        let id = UUID()
        let base = item("Milk", quantity: "1", id: id)
        let ours = item("Milk", quantity: "2", id: id)
        let theirs = item("Milk", quantity: "3", id: id)

        let merged = SharedListMerge.merge(base: keyed([base]), ours: keyed([ours]), theirs: keyed([theirs]))

        #expect(merged.count == 1)
        #expect(merged[0].quantity == "2")
    }

    @Test func theirEditIsKeptWhenWeLeftTheItemAlone() {
        let id = UUID()
        let base = item("Milk", quantity: "1", id: id)
        let theirs = item("Milk", quantity: "3", id: id)

        let merged = SharedListMerge.merge(base: keyed([base]), ours: keyed([base]), theirs: keyed([theirs]))

        #expect(merged.count == 1)
        #expect(merged[0].quantity == "3")
    }

    @Test func noAncestorProducesUnionWithoutDrops() {
        let milk = item("Milk")
        let bread = item("Bread")

        let merged = SharedListMerge.merge(base: [], ours: keyed([milk]), theirs: keyed([bread]))

        #expect(Set(merged.map(\.name)) == ["Milk", "Bread"])
    }

    @Test func duplicateKeysAreCollapsed() {
        let milk = item("Milk")

        let merged = SharedListMerge.merge(base: [], ours: keyed([milk, milk]), theirs: keyed([milk]))

        #expect(merged.count == 1)
    }
}
