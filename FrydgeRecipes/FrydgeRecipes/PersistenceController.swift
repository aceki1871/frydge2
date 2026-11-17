//
//  PersistenceController.swift
//  Recipes
//
//  Created by Josh on 06/10/2024.
//  Rewritten for NSPersistentCloudKitContainer — Phase 1 of the sync migration.
//

import CoreData
import CloudKit
import os

/// Backing store for the fridge and shopping list.
///
/// Replaces the hand-rolled CloudKit layer in `FrydgeManager` / `ShoppingListManager`,
/// which had four independent sources of truth, no change tokens, no push
/// subscriptions, per-device tombstones, and whole-list last-writer-wins.
/// `NSPersistentCloudKitContainer` provides change tokens, conflict resolution,
/// a durable offline queue and push-driven updates as built-in behaviour.
///
/// The store lives in the **App Group** container so the widget, Live Activity and
/// notification extensions can read it directly in a later phase, instead of going
/// through the mirrored UserDefaults snapshots.
struct PersistenceController {

    static let shared = PersistenceController()

    static let appGroupID = "group.Clark-Online.FrydgeRecipeAPN"
    static let cloudKitContainerID = "iCloud.com.Clark-Online.Recipe"
    private static let storeFileName = "FrydgeRecipesCoreData.sqlite"

    private static let log = Logger(subsystem: "com.Clark-Online.Recipes", category: "Persistence")

    let container: NSPersistentCloudKitContainer

    /// True when the on-disk store could not be opened and we fell back to memory.
    /// Callers should treat a degraded store as "do not destroy the user's data" —
    /// specifically, do not run the Phase 2 migration against it.
    private(set) var isDegraded: Bool = false

    // MARK: - Init

    /// - Parameters:
    ///   - inMemory: use a throwaway store (tests, previews).
    ///   - cloudKitEnabled: set false to open the same store with mirroring off.
    init(inMemory: Bool = false, cloudKitEnabled: Bool = true) {
        container = NSPersistentCloudKitContainer(name: "FrydgeRecipesCoreData")

        let description: NSPersistentStoreDescription

        if inMemory {
            description = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
            description.cloudKitContainerOptions = nil
        } else {
            description = NSPersistentStoreDescription(url: Self.storeURL())

            if cloudKitEnabled {
                let options = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: Self.cloudKitContainerID
                )
                options.databaseScope = .private
                description.cloudKitContainerOptions = options
            } else {
                description.cloudKitContainerOptions = nil
            }
        }

        // BOTH are mandatory for CloudKit mirroring. Without history tracking the
        // store cannot compute what to push; without remote-change notifications
        // the UI never learns that a pull landed.
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        // Lightweight migration — this model will gain versions.
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true

        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }

        if let error = loadError {
            // The previous implementation called fatalError() here, which is the
            // Xcode template default and wrong for shipping code: a corrupt store
            // or a failed migration crashed the app on launch with no recovery.
            Self.log.error("Persistent store failed to load: \(String(describing: error))")
            isDegraded = true
            Self.loadInMemoryFallback(into: container)
        }

        configureViewContext()
    }

    // MARK: - Store location

    private static func storeURL() -> URL {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            return groupURL.appendingPathComponent(storeFileName)
        }

        log.warning("App Group container unavailable; falling back to app-local Application Support.")

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent(storeFileName)
    }

    /// Last resort so the app still launches with a working (empty, non-persisted)
    /// stack rather than crashing. Data written here is discarded on quit.
    private static func loadInMemoryFallback(into container: NSPersistentCloudKitContainer) {
        let fallback = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
        fallback.cloudKitContainerOptions = nil
        container.persistentStoreDescriptions = [fallback]
        container.loadPersistentStores { _, error in
            if let error {
                log.fault("In-memory fallback ALSO failed: \(String(describing: error))")
            } else {
                log.notice("Running on in-memory fallback store — data will not persist.")
            }
        }
    }

    // MARK: - Contexts

    private func configureViewContext() {
        let ctx = container.viewContext
        ctx.automaticallyMergesChangesFromParent = true
        ctx.name = "viewContext"

        // Property-level merge: a remote edit to `name` and a local edit to
        // `quantity` on the same item both survive. This is the piece the old
        // whole-list CKAsset design could not do — there, one device's entire
        // list silently replaced the other's.
        ctx.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)

        ctx.transactionAuthor = "app"
        ctx.undoManager = nil
        ctx.shouldDeleteInaccessibleFaults = true
    }

    /// Background context for imports, migration and batch work.
    func newBackgroundContext() -> NSManagedObjectContext {
        let ctx = container.newBackgroundContext()
        ctx.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        ctx.automaticallyMergesChangesFromParent = true
        ctx.transactionAuthor = "background"
        ctx.undoManager = nil
        return ctx
    }

    /// Saves only when there is something to save, and never throws into the caller.
    @discardableResult
    func saveIfNeeded(_ context: NSManagedObjectContext) -> Bool {
        guard context.hasChanges else { return true }
        do {
            try context.save()
            return true
        } catch {
            Self.log.error("Context save failed: \(String(describing: error))")
            context.rollback()
            return false
        }
    }

    // MARK: - Account deletion

    /// Hard-deletes every row of every entity in the model, on the view context.
    ///
    /// Used only by account deletion. Rows are deleted individually rather than
    /// with `NSBatchDeleteRequest` because batch deletes bypass the CloudKit
    /// mirror; per-object deletes are exported as CKRecord deletions, so the
    /// user's private-database copy is removed too, not just the local cache.
    ///
    /// Returns the number of rows deleted, or `nil` if the store is degraded or
    /// the save failed (in which case nothing was removed).
    @MainActor
    @discardableResult
    func deleteAllSyncedData() -> Int? {
        guard !isDegraded else { return nil }
        let ctx = container.viewContext
        var count = 0
        do {
            for entity in container.managedObjectModel.entities {
                guard let name = entity.name else { continue }
                let request = NSFetchRequest<NSManagedObject>(entityName: name)
                request.includesPropertyValues = false
                for object in try ctx.fetch(request) {
                    ctx.delete(object)
                    count += 1
                }
            }
        } catch {
            Self.log.error("Account deletion fetch failed: \(String(describing: error))")
            ctx.rollback()
            return nil
        }
        return saveIfNeeded(ctx) ? count : nil
    }

    // MARK: - CloudKit schema

    #if DEBUG
    /// Pushes the Core Data model up as a CloudKit schema.
    ///
    /// Run this ONCE from a debug build signed with the right team, then open the
    /// CloudKit Console and **Deploy Schema to Production**. Release builds cannot
    /// create schema — if you skip this, sync silently does nothing for real users.
    func initializeCloudKitSchema() {
        do {
            try container.initializeCloudKitSchema(options: [.printSchema])
            Self.log.notice("CloudKit schema initialized. Now deploy it to Production in the CloudKit Console.")
        } catch {
            Self.log.error("CloudKit schema init failed: \(String(describing: error))")
        }
    }
    #endif

    // MARK: - Previews

    static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let ctx = controller.container.viewContext

        let milk = CDFridgeItem(context: ctx)
        milk.id = UUID()
        milk.name = "Milk"
        milk.quantity = "2"
        milk.unit = "L"
        milk.location = "Fridge"
        milk.lifecycleRaw = "fridge"
        milk.expirationDate = Calendar.current.date(byAdding: .day, value: 5, to: Date())
        milk.createdAt = Date()
        milk.updatedAt = Date()

        let bread = CDShoppingItem(context: ctx)
        bread.id = UUID()
        bread.name = "Bread"
        bread.quantity = "1"
        bread.location = "Shopping"
        bread.createdAt = Date()
        bread.updatedAt = Date()

        controller.saveIfNeeded(ctx)
        return controller
    }()
}
