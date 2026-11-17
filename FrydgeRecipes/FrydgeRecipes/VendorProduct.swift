//
//  VendorProduct.swift
//  FrydgeRecipes
//
//  Created on 27/04/2026.
//

import Foundation
import CloudKit
import SwiftUI

/// Represents a product that a vendor is selling
struct VendorProduct: Identifiable, Codable {
    let id: String
    var name: String
    var description: String
    var price: Decimal
    var currency: String
    var vendorID: String
    var vendorName: String
    var imageURL: URL?
    var category: ProductCategory
    var isAvailable: Bool
    var createdDate: Date
    var updatedDate: Date
    
    enum ProductCategory: String, Codable, CaseIterable {
        case produce = "Produce"
        case meat = "Meat & Seafood"
        case dairy = "Dairy"
        case bakery = "Bakery"
        case pantry = "Pantry Items"
        case prepared = "Prepared Foods"
        case other = "Other"
    }
    
    init(id: String = UUID().uuidString,
         name: String = "",
         description: String = "",
         price: Decimal = 0,
         currency: String = "USD",
         vendorID: String = "",
         vendorName: String = "",
         imageURL: URL? = nil,
         category: ProductCategory = .other,
         isAvailable: Bool = true,
         createdDate: Date = Date(),
         updatedDate: Date = Date()) {
        self.id = id
        self.name = name
        self.description = description
        self.price = price
        self.currency = currency
        self.vendorID = vendorID
        self.vendorName = vendorName
        self.imageURL = imageURL
        self.category = category
        self.isAvailable = isAvailable
        self.createdDate = createdDate
        self.updatedDate = updatedDate
    }
    
    // Convert to CloudKit record
    func toCloudKitRecord() -> CKRecord {
        let record = CKRecord(recordType: "VendorProduct", recordID: CKRecord.ID(recordName: id))
        record["name"] = name as CKRecordValue
        record["description"] = description as CKRecordValue
        record["price"] = NSDecimalNumber(decimal: price) as CKRecordValue
        record["currency"] = currency as CKRecordValue
        record["vendorID"] = vendorID as CKRecordValue
        record["vendorName"] = vendorName as CKRecordValue
        record["category"] = category.rawValue as CKRecordValue
        record["isAvailable"] = isAvailable ? 1 : 0
        record["createdDate"] = createdDate as CKRecordValue
        record["updatedDate"] = updatedDate as CKRecordValue
        return record
    }
    
    // Initialize from CloudKit record
    init?(from record: CKRecord) {
        guard let name = record["name"] as? String,
              let description = record["description"] as? String,
              let priceNumber = record["price"] as? NSDecimalNumber,
              let currency = record["currency"] as? String,
              let vendorID = record["vendorID"] as? String,
              let vendorName = record["vendorName"] as? String,
              let categoryString = record["category"] as? String,
              let category = ProductCategory(rawValue: categoryString),
              let isAvailableInt = record["isAvailable"] as? Int,
              let createdDate = record["createdDate"] as? Date,
              let updatedDate = record["updatedDate"] as? Date else {
            return nil
        }
        
        self.id = record.recordID.recordName
        self.name = name
        self.description = description
        self.price = priceNumber.decimalValue
        self.currency = currency
        self.vendorID = vendorID
        self.vendorName = vendorName
        self.category = category
        self.isAvailable = isAvailableInt != 0
        self.createdDate = createdDate
        self.updatedDate = updatedDate
        
        // Handle image asset if present
        if let asset = record["image"] as? CKAsset,
           let fileURL = asset.fileURL {
            self.imageURL = fileURL
        }
    }
    
    var formattedPrice: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: price as NSDecimalNumber) ?? "\(price)"
    }
}
