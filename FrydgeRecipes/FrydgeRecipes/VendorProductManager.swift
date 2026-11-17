//
//  VendorProductManager.swift
//  FrydgeRecipes
//
//  Created on 27/04/2026.
//

import Foundation
import CloudKit
import SwiftUI

/// Manages vendor products in CloudKit
@MainActor
class VendorProductManager: ObservableObject {
    @Published var products: [VendorProduct] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
    private var database: CKDatabase {
        container.publicCloudDatabase
    }
    
    // MARK: - Fetch Products
    
    func fetchAllProducts() async {
        isLoading = true
        errorMessage = nil
        
        let query = CKQuery(recordType: "VendorProduct", predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "updatedDate", ascending: false)]
        
        do {
            let (matchResults, _) = try await database.records(matching: query)
            var fetchedProducts: [VendorProduct] = []
            
            for (_, result) in matchResults {
                switch result {
                case .success(let record):
                    if let product = VendorProduct(from: record) {
                        fetchedProducts.append(product)
                    }
                case .failure(let error):
                    print("[VendorProductManager] Error fetching record: \(error)")
                }
            }
            
            products = fetchedProducts
            isLoading = false
        } catch {
            errorMessage = "Failed to fetch products: \(error.localizedDescription)"
            isLoading = false
        }
    }
    
    func fetchProductsByVendor(vendorID: String) async {
        isLoading = true
        errorMessage = nil
        
        let predicate = NSPredicate(format: "vendorID == %@", vendorID)
        let query = CKQuery(recordType: "VendorProduct", predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "updatedDate", ascending: false)]
        
        do {
            let (matchResults, _) = try await database.records(matching: query)
            var fetchedProducts: [VendorProduct] = []
            
            for (_, result) in matchResults {
                switch result {
                case .success(let record):
                    if let product = VendorProduct(from: record) {
                        fetchedProducts.append(product)
                    }
                case .failure(let error):
                    print("[VendorProductManager] Error fetching record: \(error)")
                }
            }
            
            products = fetchedProducts
            isLoading = false
        } catch {
            errorMessage = "Failed to fetch vendor products: \(error.localizedDescription)"
            isLoading = false
        }
    }
    
    // MARK: - Save Product
    
    func saveProduct(_ product: VendorProduct, image: UIImage? = nil) async throws {
        isLoading = true
        errorMessage = nil
        
        let record = product.toCloudKitRecord()
        
        // Handle image upload if provided
        if let image = image {
            // Pixel- and byte-bounded before it becomes a CKAsset.
            let imageData = image.frydgeBoundedJPEG(maxPixelSize: ImageBudget.upload, quality: 0.7)
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            
            try imageData?.write(to: tempURL)
            let asset = CKAsset(fileURL: tempURL)
            record["image"] = asset
        }
        
        do {
            let savedRecord = try await database.save(record)
            
            // Update local products array
            if let savedProduct = VendorProduct(from: savedRecord) {
                if let index = products.firstIndex(where: { $0.id == savedProduct.id }) {
                    products[index] = savedProduct
                } else {
                    products.insert(savedProduct, at: 0)
                }
            }
            
            isLoading = false
        } catch {
            errorMessage = "Failed to save product: \(error.localizedDescription)"
            isLoading = false
            throw error
        }
    }
    
    // MARK: - Delete Product
    
    func deleteProduct(_ product: VendorProduct) async throws {
        isLoading = true
        errorMessage = nil
        
        let recordID = CKRecord.ID(recordName: product.id)
        
        do {
            try await database.deleteRecord(withID: recordID)
            products.removeAll { $0.id == product.id }
            isLoading = false
        } catch {
            errorMessage = "Failed to delete product: \(error.localizedDescription)"
            isLoading = false
            throw error
        }
    }
    
    // MARK: - Update Product Availability
    
    func toggleProductAvailability(_ product: VendorProduct) async throws {
        var updatedProduct = product
        updatedProduct.isAvailable.toggle()
        updatedProduct.updatedDate = Date()
        try await saveProduct(updatedProduct)
    }
}
