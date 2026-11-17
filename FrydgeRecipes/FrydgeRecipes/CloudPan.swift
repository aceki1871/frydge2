//
//  CloudPan.swift
//  FrydgeRecipes
//
//  Created by Josh on 16/10/2024.
//


import Foundation
import CloudKit

struct CloudPan: Identifiable, Codable {
    let id: UUID
    var name: String
    /// The record's real CloudKit identity, when this pan came from a fetched
    /// CKRecord. Nil for pans created locally (custom text entries) that have
    /// never been saved.
    var recordName: String?

    // Initializer to create a pan from a CKRecord
    init(record: CKRecord) {
        self.id = UUID()
        self.name = record["name"] as? String ?? "Unknown Pan"
        self.recordName = record.recordID.recordName
    }

    // Initializer for manual creation
    init(name: String) {
        self.id = UUID()
        self.name = name
        self.recordName = nil
    }

    // Convert to CKReference for saving to CloudKit
    func toCKReference() -> CKRecord.Reference? {
        guard let recordName else { return nil }
        return CKRecord.Reference(recordID: CKRecord.ID(recordName: recordName), action: .none)
    }
}