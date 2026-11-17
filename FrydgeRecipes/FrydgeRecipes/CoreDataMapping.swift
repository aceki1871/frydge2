//
//  CoreDataMapping.swift
//  FrydgeRecipes
//
//  Phase 1 of the sync migration.
//
//  Bridges the Core Data entities to the existing domain structs
//  (`StoredIngredient`, `ShoppingListItem`) so that Phase 3 can swap the backing
//  store underneath `FrydgeManager` / `ShoppingListManager` without touching the
//  3,487-line ShoppingListView or any other call site.
//
//  Nothing in this file is wired up yet — it is pure, side-effect-free mapping
//  plus fetch-request helpers. Phase 2 (migration) and Phase 3 (cutover) consume it.
//

import CoreData
import Foundation

// MARK: - Dietary tag encoding

/// `Set<String>` is not CloudKit-mirrorable, so tags are persisted as a JSON
/// array string. Kept in one place so both entities encode identically.
enum DietaryTagCoding {

    static func encode(_ tags: Set<String>) -> String {
        let normalized = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
            .sorted() // stable ordering — avoids spurious CloudKit writes
        guard let data = try? JSONEncoder().encode(normalized),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    static func decode(_ json: String?) -> Set<String> {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(array.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() })
    }
}

// MARK: - Photos

extension CDItemPhoto {

    /// Photo blobs ordered by `sortIndex`, newest-first ordering preserved by the caller.
    static func sorted(_ photos: NSSet?) -> [CDItemPhoto] {
        guard let photos = photos as? Set<CDItemPhoto> else { return [] }
        return photos.sorted { $0.sortIndex < $1.sortIndex }
    }

    static func blobs(_ photos: NSSet?) -> [Data] {
        sorted(photos).compactMap(\.data)
    }
}

// MARK: - CDFridgeItem <-> StoredIngredient

extension CDFridgeItem {

    /// Live (non-soft-deleted) items only.
    static func fetchRequestForActiveItems() -> NSFetchRequest<CDFridgeItem> {
        let request = NSFetchRequest<CDFridgeItem>(entityName: "CDFridgeItem")
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true,
                                                    selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))]
        return request
    }

    static func fetchRequest(forID id: UUID) -> NSFetchRequest<CDFridgeItem> {
        let request = NSFetchRequest<CDFridgeItem>(entityName: "CDFridgeItem")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return request
    }

    var isSoftDeleted: Bool { deletedAt != nil }

    /// Converts to the struct the existing views and managers already consume.
    ///
    /// Photo blobs are deliberately NOT loaded: with external binary storage each
    /// blob is a disk read, and this runs for every item at launch and on every
    /// remote-change reload. No view reads `userPhotoData` off the struct (the
    /// detail sheet uses `UserPhotoLibrary`); photo persistence goes through
    /// `writePhotosThroughToStore(id:photos:)` which targets `CDItemPhoto` rows
    /// directly.
    func toStoredIngredient() -> StoredIngredient {
        StoredIngredient(
            id: id ?? UUID(),
            name: name ?? "",
            quantity: quantity ?? "",
            unit: unit ?? "",
            expirationDate: expirationDate ?? Date(),
            location: location ?? "Fridge",
            dietaryTags: DietaryTagCoding.decode(dietaryTagsJSON),
            lifecycle: StoredIngredient.ItemLifecycle(rawValue: lifecycleRaw ?? "fridge") ?? .fridge,
            quantityUsed: quantityUsed,
            userPhotoData: []
        )
    }

    /// Writes struct values onto the managed object.
    ///
    /// Only assigns when the value actually differs — Core Data marks a property
    /// dirty on any assignment, and a dirty property is a CloudKit write. Blind
    /// assignment here would push the whole fridge on every UI refresh.
    ///
    /// - Parameter includingPhotos: photo rewriting is expensive AND the structs
    ///   coming from `toStoredIngredient()` carry no photo bytes — applying them
    ///   with photos on would wipe the stored photos. Defaults to false; only
    ///   pass true with a struct whose `userPhotoData` is authoritative.
    func apply(_ item: StoredIngredient, includingPhotos: Bool = false, in context: NSManagedObjectContext) {
        if id != item.id { id = item.id }
        if name != item.name { name = item.name }
        if quantity != item.quantity { quantity = item.quantity }
        if unit != item.unit { unit = item.unit }
        if expirationDate != item.expirationDate { expirationDate = item.expirationDate }
        if location != item.location { location = item.location }

        let tags = DietaryTagCoding.encode(item.dietaryTags)
        if dietaryTagsJSON != tags { dietaryTagsJSON = tags }

        if lifecycleRaw != item.lifecycle.rawValue { lifecycleRaw = item.lifecycle.rawValue }

        let clampedUsage = max(0, min(100, item.quantityUsed))
        if quantityUsed != clampedUsage { quantityUsed = clampedUsage }

        if createdAt == nil { createdAt = Date() }

        if includingPhotos {
            replacePhotos(with: item.userPhotoData, in: context)
        }

        // Object-level, NOT context.hasChanges: during a bulk reconcile the context
        // is dirty as soon as any one row changes, which would stamp updatedAt on
        // every other row and push the entire fridge to CloudKit on every save.
        if hasPersistentChangedValues { updatedAt = Date() }
    }

    /// Replaces the photo set only when the bytes actually changed.
    func replacePhotos(with blobs: [Data], in context: NSManagedObjectContext) {
        let existing = CDItemPhoto.sorted(photos)
        guard existing.map(\.data) != blobs.map(Optional.some) else { return }

        for photo in existing { context.delete(photo) }

        for (index, blob) in blobs.enumerated() {
            let photo = CDItemPhoto(context: context)
            photo.id = UUID()
            photo.data = blob
            photo.sortIndex = Int16(clamping: index)
            photo.createdAt = Date()
            photo.fridgeItem = self
        }
    }

    /// Soft delete. Deletion must be a synced fact — the old per-device
    /// `UserDefaults` tombstones expired after 7 days and let items resurrect.
    func softDelete() {
        guard deletedAt == nil else { return }
        deletedAt = Date()
        updatedAt = Date()
    }
}

// MARK: - CDShoppingItem <-> ShoppingListItem

extension CDShoppingItem {

    static func fetchRequestForActiveItems() -> NSFetchRequest<CDShoppingItem> {
        let request = NSFetchRequest<CDShoppingItem>(entityName: "CDShoppingItem")
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return request
    }

    static func fetchRequest(forID id: UUID) -> NSFetchRequest<CDShoppingItem> {
        let request = NSFetchRequest<CDShoppingItem>(entityName: "CDShoppingItem")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return request
    }

    var isSoftDeleted: Bool { deletedAt != nil }

    /// Photo blobs deliberately not loaded — see `toStoredIngredient()`.
    func toShoppingListItem() -> ShoppingListItem {
        ShoppingListItem(
            id: id ?? UUID(),
            name: name ?? "",
            quantity: quantity ?? "1",
            unit: unit ?? "",
            location: location ?? "Shopping",
            dietaryTags: DietaryTagCoding.decode(dietaryTagsJSON),
            createdAt: createdAt ?? Date(),
            userPhotoData: []
        )
    }

    func apply(_ item: ShoppingListItem, includingPhotos: Bool = false, in context: NSManagedObjectContext) {
        if id != item.id { id = item.id }
        if name != item.name { name = item.name }
        if quantity != item.quantity { quantity = item.quantity }
        if unit != item.unit { unit = item.unit }
        if location != item.location { location = item.location }

        let tags = DietaryTagCoding.encode(item.dietaryTags)
        if dietaryTagsJSON != tags { dietaryTagsJSON = tags }

        if createdAt != item.createdAt { createdAt = item.createdAt }

        if includingPhotos {
            replacePhotos(with: item.userPhotoData, in: context)
        }

        // Object-level, NOT context.hasChanges: during a bulk reconcile the context
        // is dirty as soon as any one row changes, which would stamp updatedAt on
        // every other row and push the entire fridge to CloudKit on every save.
        if hasPersistentChangedValues { updatedAt = Date() }
    }

    func replacePhotos(with blobs: [Data], in context: NSManagedObjectContext) {
        let existing = CDItemPhoto.sorted(photos)
        guard existing.map(\.data) != blobs.map(Optional.some) else { return }

        for photo in existing { context.delete(photo) }

        for (index, blob) in blobs.enumerated() {
            let photo = CDItemPhoto(context: context)
            photo.id = UUID()
            photo.data = blob
            photo.sortIndex = Int16(clamping: index)
            photo.createdAt = Date()
            photo.shoppingItem = self
        }
    }

    func softDelete() {
        guard deletedAt == nil else { return }
        deletedAt = Date()
        updatedAt = Date()
    }
}

// MARK: - Upsert helpers

extension NSManagedObjectContext {

    /// Finds an existing fridge item by UUID or creates one.
    ///
    /// The model deliberately has **no unique constraint** on `id` — CloudKit
    /// mirroring rejects unique constraints outright — so uniqueness is enforced
    /// here instead.
    func upsertFridgeItem(id: UUID) throws -> CDFridgeItem {
        if let existing = try fetch(CDFridgeItem.fetchRequest(forID: id)).first {
            return existing
        }
        let created = CDFridgeItem(context: self)
        created.id = id
        created.createdAt = Date()
        created.updatedAt = Date()
        return created
    }

    func upsertShoppingItem(id: UUID) throws -> CDShoppingItem {
        if let existing = try fetch(CDShoppingItem.fetchRequest(forID: id)).first {
            return existing
        }
        let created = CDShoppingItem(context: self)
        created.id = id
        created.createdAt = Date()
        created.updatedAt = Date()
        return created
    }

    /// Purges soft-deleted rows whose tombstone is older than `olderThan`.
    ///
    /// Safe in a way the old design was not: by the time a row is purged, the
    /// delete has already propagated through CloudKit to every device as a real
    /// synced change, so there is no copy left anywhere to resurrect it.
    func purgeSoftDeleted(olderThan interval: TimeInterval = 30 * 24 * 60 * 60) throws {
        let cutoff = Date().addingTimeInterval(-interval)

        let fridge = NSFetchRequest<CDFridgeItem>(entityName: "CDFridgeItem")
        fridge.predicate = NSPredicate(format: "deletedAt != nil AND deletedAt < %@", cutoff as NSDate)
        for item in try fetch(fridge) { delete(item) }

        let shopping = NSFetchRequest<CDShoppingItem>(entityName: "CDShoppingItem")
        shopping.predicate = NSPredicate(format: "deletedAt != nil AND deletedAt < %@", cutoff as NSDate)
        for item in try fetch(shopping) { delete(item) }

        let planned = NSFetchRequest<CDPlannedRecipe>(entityName: "CDPlannedRecipe")
        planned.predicate = NSPredicate(format: "deletedAt != nil AND deletedAt < %@", cutoff as NSDate)
        for item in try fetch(planned) { delete(item) }

        let recurring = NSFetchRequest<CDRecurringItem>(entityName: "CDRecurringItem")
        recurring.predicate = NSPredicate(format: "deletedAt != nil AND deletedAt < %@", cutoff as NSDate)
        for item in try fetch(recurring) { delete(item) }
    }
}
