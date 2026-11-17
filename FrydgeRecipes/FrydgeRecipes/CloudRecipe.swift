import Foundation
import CloudKit
import UIKit

struct CloudRecipe: Identifiable, Codable, Hashable {
    // MARK: - Core

    var id: String
    var name: String
    var serves: String
    var ingredients: [String]
    var pan: String
    var instructions: String

    // MARK: - Newer fields used by RecipeEditorView

    var steps: [RecipeStep]
    var location: String
    var dietaryTags: [String]

    /// Display name of the person who created the recipe.
    /// Persisted in CloudKit field "authorName".
    var authorName: String?

    /// CloudKit's system creator (`creatorUserRecordID.recordName`). For the
    /// current user's own records CloudKit reports `CKCurrentUserDefaultName`.
    /// `nil` for recipes created locally and not yet round-tripped.
    var creatorRecordName: String?

    /// True when the current iCloud user made this recipe and may edit or
    /// delete the original. Anyone else gets their own copy ("version") when
    /// they edit, and never a delete button.
    var isOwnedByCurrentUser: Bool {
        guard let creator = creatorRecordName else {
            // No creator and no server timestamp: a local, unsynced recipe of ours.
            // No creator but a server timestamp: a stale cache entry from before
            // this field existed — treat as someone else's until it refreshes.
            return creationDate == nil
        }
        if creator == CKCurrentUserDefaultName { return true }
        if let me = UserDefaults.standard.string(forKey: "appleUserID"), !me.isEmpty, me == creator {
            return true
        }
        return false
    }

    /// Per-ingredient tags + location persisted as JSON string.
    /// Field name in CloudKit: "ingredientsMetaJSON"
    var ingredientsMetaJSON: String?

    // MARK: - Image

    /// Optional remote image reference (persisted).
    /// Field name in CloudKit: "imageSourceURL"
    var imageSourceURL: String?
    var imageCredit: ImageCredit? = nil

    /// CloudKit asset reference if loaded from CloudKit.
    /// (Note: CKAsset isn't Codable; not included in Codable encoding.)
    var imageAsset: CKAsset?

    /// Used when creating/saving a recipe from UI
    /// (Not persisted in Codable; image is stored via CKAsset / offline imageData wrapper)
    var image: UIImage?

    // MARK: - Timestamps

    var creationDate: Date?
    var modificationDate: Date?

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case serves
        case ingredients
        case pan
        case instructions
        case steps
        case location
        case dietaryTags
        case ingredientsMetaJSON
        case imageSourceURL
        case imageCredit
        case creationDate
        case modificationDate
        case authorName
        case creatorRecordName
    }

    // MARK: - Init (app)

    init(
        name: String,
        serves: String = "4",
        ingredients: [String],
        pan: String,
        instructions: String = "",
        steps: [RecipeStep] = [],
        image: UIImage? = nil,
        id: String = UUID().uuidString,
        location: String = "Fridge",
        dietaryTags: [String] = [],
        ingredientsMetaJSON: String? = nil,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        imageAsset: CKAsset? = nil,
        imageSourceURL: String? = nil,
        authorName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.serves = serves
        self.ingredients = ingredients
        self.pan = pan
        self.instructions = instructions
        self.steps = steps
        self.image = image
        self.location = location
        self.dietaryTags = dietaryTags
        self.ingredientsMetaJSON = ingredientsMetaJSON
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.imageAsset = imageAsset
        self.imageSourceURL = imageSourceURL
        self.authorName = authorName
    }

    // MARK: - Init (CloudKit)

    init(from record: CKRecord) {
        self.id = record.recordID.recordName
        self.name = record["name"] as? String ?? "Unnamed Recipe"
        self.serves = record["serves"] as? String ?? "4"
        self.ingredients = record["ingredients"] as? [String] ?? []
        self.pan = record["pan"] as? String ?? ""
        self.instructions = record["instructions"] as? String ?? ""

        self.location = record["location"] as? String ?? "Fridge"
        self.dietaryTags = record["dietaryTags"] as? [String] ?? []

        self.ingredientsMetaJSON = record["ingredientsMetaJSON"] as? String

        // ✅ NEW: persisted remote image reference
        self.imageSourceURL = record["imageSourceURL"] as? String

        // Steps JSON -> [RecipeStep]
        if let stepsJSON = record["stepsJSON"] as? String,
           let data = stepsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([RecipeStep].self, from: data) {
            self.steps = decoded
        } else {
            self.steps = []
        }

        self.imageAsset = record["image"] as? CKAsset
        self.image = nil

        self.creationDate = record.creationDate
        self.modificationDate = record.modificationDate

        self.authorName = record["authorName"] as? String
        self.creatorRecordName = record.creatorUserRecordID?.recordName
    }

    // MARK: - CloudKit mapping

    func toCKRecord() -> CKRecord {
        let record = CKRecord(recordType: "Recipe", recordID: CKRecord.ID(recordName: self.id))

        record["name"] = self.name as CKRecordValue
        record["serves"] = self.serves as CKRecordValue
        record["ingredients"] = self.ingredients as CKRecordValue
        record["pan"] = self.pan as CKRecordValue
        record["instructions"] = self.instructions as CKRecordValue

        record["location"] = self.location as CKRecordValue
        record["dietaryTags"] = self.dietaryTags as CKRecordValue

        if let ingredientsMetaJSON = self.ingredientsMetaJSON {
            record["ingredientsMetaJSON"] = ingredientsMetaJSON as CKRecordValue
        } else {
            record["ingredientsMetaJSON"] = nil
        }

        if let data = try? JSONEncoder().encode(self.steps),
           let json = String(data: data, encoding: .utf8) {
            record["stepsJSON"] = json as CKRecordValue
        } else {
            record["stepsJSON"] = nil
        }

        // Image: prefer provided UIImage; otherwise keep existing asset if present
        // NOTE: relies on UIImage.toCKAsset() extension existing elsewhere in the target.
        if let img = self.image, let asset = img.toCKAsset() {
            record["image"] = asset
        } else if let asset = self.imageAsset {
            record["image"] = asset
        }

        if let author = self.authorName?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            record["authorName"] = author as CKRecordValue
        }

        return record
    }

    // MARK: - CloudKit save

    /// Saves a recipe through `RecipeUploadQueue`. The recipe is persisted on
    /// disk first and uploaded second; the queue entry is removed only once
    /// CloudKit confirms the save, so a crash or dropped connection between the
    /// two cannot lose it. Retries are idempotent because the record name is
    /// the recipe's stable ID.
    ///
    /// The completion reports `.failure(RecipeUploadDeferred)` when the save
    /// did not complete in this pass. That is not data loss: the recipe stays
    /// queued and is retried on launch, foreground and reconnect.
    static func saveNewRecipe(_ recipe: CloudRecipe, image: UIImage?, completion: @escaping (Result<Void, Error>) -> Void) {
        var r = recipe
        if r.image == nil { r.image = image }
        RecipeUploadQueue.shared.enqueue(r, image: image)

        Task {
            let summary = await RecipeUploadQueue.shared.drain()
            let result: Result<Void, Error>
            if summary.succeeded(recipe.id) {
                result = .success(())
            } else {
                let message = summary.failed[recipe.id]
                    ?? "Saved on this device; it will upload when iCloud is reachable."
                result = .failure(RecipeUploadDeferred(message: message))
            }
            await MainActor.run { completion(result) }
        }
    }
}

/// Returned by `CloudRecipe.saveNewRecipe` when the upload is queued rather
/// than confirmed. The recipe is safe on disk; this only means "not yet".
struct RecipeUploadDeferred: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
