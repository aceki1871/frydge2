//
//  RecipeUploadQueueTests.swift
//  FrydgeRecipesTests
//
//  Regression tests for the durable offline recipe upload queue. The original
//  implementation fired uploads and then cleared the whole queue without
//  waiting, and the version the app actually called was an empty stub.
//

import Testing
import Foundation
import CloudKit
@testable import FrydgeRecipes

/// Stand-in for the public CloudKit database. Records which record names were
/// saved and fails any IDs it is told to.
final class FakeRecipeRecordSaver: RecipeRecordSaving, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [String] = []
    private var failing: Set<String> = []

    var savedRecordNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return saved
    }

    func fail(_ ids: String...) {
        lock.lock(); defer { lock.unlock() }
        failing.formUnion(ids)
    }

    func recover(_ ids: String...) {
        lock.lock(); defer { lock.unlock() }
        failing.subtract(ids)
    }

    func saveRecipeRecord(_ record: CKRecord) async throws {
        lock.lock(); defer { lock.unlock() }
        let name = record.recordID.recordName
        if failing.contains(name) {
            throw CKError(.networkFailure)
        }
        saved.append(name)
    }
}

struct RecipeUploadQueueTests {

    // MARK: - Helpers

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecipeUploadQueueTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRecipe(_ name: String, id: String = UUID().uuidString) -> CloudRecipe {
        CloudRecipe(name: name, ingredients: ["1 egg"], pan: "", id: id)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "RecipeUploadQueueTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Durability

    @Test func enqueuedRecipeSurvivesRestart() {
        let dir = makeDirectory()
        let recipe = makeRecipe("Offline omelette")

        let first = RecipeUploadQueue(directory: dir, saver: FakeRecipeRecordSaver())
        first.enqueue(recipe)
        #expect(first.pendingCount == 1)

        // "Restart": a fresh instance over the same directory.
        let second = RecipeUploadQueue(directory: dir, saver: FakeRecipeRecordSaver())
        #expect(second.pendingCount == 1)
        #expect(second.pending.first?.recipe.id == recipe.id)
        #expect(second.pending.first?.recipe.name == "Offline omelette")
    }

    @Test func reEnqueuingSameRecipeReplacesEarlierEntry() {
        let queue = RecipeUploadQueue(directory: makeDirectory(), saver: FakeRecipeRecordSaver())
        let id = UUID().uuidString

        queue.enqueue(makeRecipe("Draft 1", id: id))
        queue.enqueue(makeRecipe("Draft 2", id: id))

        #expect(queue.pendingCount == 1)
        #expect(queue.pending.first?.recipe.name == "Draft 2")
    }

    // MARK: - Drain outcomes

    @Test func successfulUploadRemovesEntryAndIsNotRepeated() async {
        let saver = FakeRecipeRecordSaver()
        let queue = RecipeUploadQueue(directory: makeDirectory(), saver: saver)
        let recipe = makeRecipe("Toast")
        queue.enqueue(recipe)

        let first = await queue.drain()
        #expect(first.succeeded(recipe.id))
        #expect(queue.pendingCount == 0)

        let second = await queue.drain()
        #expect(second.uploaded.isEmpty)
        #expect(saver.savedRecordNames == [recipe.id])
    }

    @Test func failedUploadStaysQueuedWithAttemptRecorded() async {
        let saver = FakeRecipeRecordSaver()
        let queue = RecipeUploadQueue(directory: makeDirectory(), saver: saver)
        let recipe = makeRecipe("Soup")
        saver.fail(recipe.id)
        queue.enqueue(recipe)

        let summary = await queue.drain()

        #expect(!summary.succeeded(recipe.id))
        #expect(summary.failed[recipe.id] != nil)
        #expect(queue.pendingCount == 1)
        #expect(queue.pending.first?.attempts == 1)
        #expect(queue.pending.first?.lastError != nil)
        #expect(saver.savedRecordNames.isEmpty)
    }

    @Test func partialFailureKeepsOnlyTheFailedEntry() async {
        let saver = FakeRecipeRecordSaver()
        let queue = RecipeUploadQueue(directory: makeDirectory(), saver: saver)
        let good = makeRecipe("Good")
        let bad = makeRecipe("Bad")
        saver.fail(bad.id)
        queue.enqueue(good)
        queue.enqueue(bad)

        let summary = await queue.drain()

        #expect(summary.succeeded(good.id))
        #expect(!summary.succeeded(bad.id))
        #expect(queue.pending.map(\.id) == [bad.id])
        #expect(saver.savedRecordNames == [good.id])
    }

    @Test func retryAfterFailureSucceedsAndClearsQueue() async {
        let saver = FakeRecipeRecordSaver()
        let dir = makeDirectory()
        let recipe = makeRecipe("Retry me")
        saver.fail(recipe.id)

        let queue = RecipeUploadQueue(directory: dir, saver: saver)
        queue.enqueue(recipe)
        _ = await queue.drain()
        #expect(queue.pendingCount == 1)

        // Connectivity returns and the app relaunches.
        saver.recover(recipe.id)
        let relaunched = RecipeUploadQueue(directory: dir, saver: saver)
        let summary = await relaunched.drain()

        #expect(summary.succeeded(recipe.id))
        #expect(relaunched.pendingCount == 0)
        #expect(saver.savedRecordNames == [recipe.id])
    }

    @Test func offlineDrainLeavesQueueUntouched() async {
        let saver = FakeRecipeRecordSaver()
        let queue = RecipeUploadQueue(directory: makeDirectory(), saver: saver, isNetworkAvailable: { false })
        queue.enqueue(makeRecipe("No signal"))

        let summary = await queue.drain()

        #expect(summary.skipped)
        #expect(queue.pendingCount == 1)
        #expect(queue.pending.first?.attempts == 0)
        #expect(saver.savedRecordNames.isEmpty)
    }

    // MARK: - Legacy migration

    @Test func legacyFormatsMigrateAndMalformedEntriesAreQuarantined() throws {
        let defaults = makeDefaults()
        let formatA = makeRecipe("Format A")
        let formatBID = UUID().uuidString

        let legacyRecipes: [[String: Any]] = [
            // Format A: JSON blob under "recipe" (CloudRecipe.saveRecipeLocally).
            ["recipe": try JSONEncoder().encode(formatA), "imageData": Data([0xFF, 0xD8])],
            // Format B: flat dictionary (Networking.saveRecipeLocally via toDictionary()).
            [
                "id": formatBID,
                "name": "Format B",
                "serves": "2",
                "ingredients": ["flour", "water"],
                "pan": "skillet",
                "instructions": "Mix",
                "stepsJSON": "",
                "location": "Pantry",
                "dietaryTags": ["vegan"],
            ],
            // Garbage: must be kept for inspection, not dropped.
            ["unexpected": 42],
        ]
        defaults.set(legacyRecipes, forKey: RecipeUploadQueue.legacyRecipesKey)
        defaults.set([["id": "x", "newImageData": [Data()]]], forKey: RecipeUploadQueue.legacyUpdatesKey)

        let queue = RecipeUploadQueue(directory: makeDirectory(), saver: FakeRecipeRecordSaver())
        queue.migrateLegacyUserDefaults(defaults)

        let ids = Set(queue.pending.map(\.id))
        #expect(ids == [formatA.id, formatBID])

        let migratedB = queue.pending.first { $0.id == formatBID }
        #expect(migratedB?.recipe.name == "Format B")
        #expect(migratedB?.recipe.ingredients == ["flour", "water"])
        #expect(migratedB?.recipe.dietaryTags == ["vegan"])

        let migratedA = queue.pending.first { $0.id == formatA.id }
        #expect(migratedA?.imageData == Data([0xFF, 0xD8]))

        // One malformed recipe entry + one offlineUpdates entry.
        #expect(queue.quarantined.count == 2)
        #expect(queue.quarantined.allSatisfy { $0.payload != nil })

        #expect(defaults.object(forKey: RecipeUploadQueue.legacyRecipesKey) == nil)
        #expect(defaults.object(forKey: RecipeUploadQueue.legacyUpdatesKey) == nil)
    }

    @Test func migrationWithNothingToMigrateIsANoOp() {
        let defaults = makeDefaults()
        let queue = RecipeUploadQueue(directory: makeDirectory(), saver: FakeRecipeRecordSaver())
        queue.migrateLegacyUserDefaults(defaults)
        #expect(queue.pendingCount == 0)
        #expect(queue.quarantined.isEmpty)
    }

    // MARK: - Corrupt storage

    @Test func corruptPendingFileIsQuarantinedNotDiscarded() throws {
        let dir = makeDirectory()
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: dir.appendingPathComponent("pending.json"))

        let queue = RecipeUploadQueue(directory: dir, saver: FakeRecipeRecordSaver())

        #expect(queue.pendingCount == 0)
        #expect(queue.quarantined.count == 1)
        #expect(queue.quarantined.first?.payload == corrupt)

        // And the queue is usable again afterwards.
        queue.enqueue(makeRecipe("After corruption"))
        #expect(RecipeUploadQueue(directory: dir, saver: FakeRecipeRecordSaver()).pendingCount == 1)
    }
}
