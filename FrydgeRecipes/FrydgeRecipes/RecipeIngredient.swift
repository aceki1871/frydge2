//  RecipeIngredient.swift
//  FrydgeRecipes
//
//  Created by Josh on 21/10/2024.
//

import Foundation
import CloudKit

/// iOS 18 / Swift 6-ready model for a single recipe ingredient,
/// now including optional dietary tags (e.g. ["DF","GF","V"]).
struct RecipeIngredient: Identifiable, Codable {
    // MARK: Identity
    let id: UUID

    // MARK: Core fields
    var name: String
    var quantity: Double
    var unit: String

    // MARK: Dietary (optional)
    /// Optional dietary tags that this ingredient should satisfy (e.g., ["DF", "GF", "V"]).
    /// Empty set means "no dietary requirement" for this ingredient.
    var dietaryTags: Set<String> = []

    // MARK: Inits
    init(id: UUID = UUID(), name: String, quantity: Double, unit: String, dietaryTags: Set<String> = []) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.dietaryTags = dietaryTags
    }

    /// Initialize from a CloudKit record (recordType: "RecipeIngredient").
    init(record: CKRecord) {
        self.id = UUID(uuidString: record.recordID.recordName) ?? UUID()
        self.name = record["name"] as? String ?? "Unknown Ingredient"
        self.quantity = record["quantity"] as? Double ?? 0.0
        self.unit = record["unit"] as? String ?? "g"
        let tagsArray = record["dietaryTags"] as? [String] ?? []
        self.dietaryTags = Set(tagsArray)
    }

    // MARK: CloudKit helpers
    /// Stable record ID based on our UUID (so updates overwrite instead of duplicating).
    var ckRecordID: CKRecord.ID { CKRecord.ID(recordName: id.uuidString) }

    /// Build a CKRecord representing this ingredient for upsert into CloudKit.
    func toCKRecord() -> CKRecord {
        let record = CKRecord(recordType: "RecipeIngredient", recordID: ckRecordID)
        record["name"] = name as CKRecordValue
        record["quantity"] = quantity as CKRecordValue
        record["unit"] = unit as CKRecordValue
        record["dietaryTags"] = Array(dietaryTags) as CKRecordValue
        return record
    }

    /// Convenience reference to this ingredient's record.
    func toCKReference() -> CKRecord.Reference {
        CKRecord.Reference(recordID: ckRecordID, action: .none)
    }

    // MARK: Fetching helpers
    /// Fetch a batch of referenced RecipeIngredient records.
    static func fetchReferences(_ refs: [CKRecord.Reference]) async throws -> [RecipeIngredient] {
        var fetched: [RecipeIngredient] = []
        guard !refs.isEmpty else { return fetched }

        let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        let db = container.publicCloudDatabase

        for ref in refs {
            let record = try await db.record(for: ref.recordID)
            fetched.append(RecipeIngredient(record: record))
        }
        return fetched
    }
}
