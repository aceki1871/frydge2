import Foundation
import CloudKit
import UIKit
import SwiftSoup // We'll use SwiftSoup for parsing (no need for Regex hacks)

struct StoreProduct {
    let name: String
    let imageUrl: String?
    let price: String?
    let isAvailable: Bool
}

// Helper function to determine if a CKError is retryable
extension CKError {
    var isRetryable: Bool {
        let retryableErrors: [CKError.Code] = [
            .networkUnavailable,
            .networkFailure,
            .serviceUnavailable,
            .requestRateLimited,
            .zoneBusy,
            .operationCancelled
        ]
        return retryableErrors.contains(self.code)
    }

    /// Short, human-readable explanation for common sharing/sync failures, so the UI
    /// never has to show a raw "The operation couldn't be completed. (CKErrorDomain
    /// error 3.)" to someone trying to accept or create a share.
    var friendlyMessage: String {
        switch code {
        case .networkUnavailable, .networkFailure:
            return "No internet connection. Check your connection and try again."
        case .notAuthenticated:
            return "Sign in to iCloud in Settings to use sharing."
        case .quotaExceeded:
            return "iCloud storage is full."
        case .serviceUnavailable, .zoneBusy, .requestRateLimited:
            return "iCloud is temporarily busy. Try again in a moment."
        case .tooManyParticipants:
            return "This share has reached its participant limit."
        case .alreadyShared:
            return "This item is already shared."
        default:
            return localizedDescription
        }
    }
}

/// Retries a CloudKit operation with backoff when the failure is transient
/// (network blips, iCloud service hiccups) rather than surfacing a raw
/// CKErrorDomain error to the user on the first hiccup.
func withCloudKitRetry<T>(
    attempts: Int = 3,
    delay: UInt64 = 500_000_000,
    _ operation: () async throws -> T
) async throws -> T {
    do {
        return try await operation()
    } catch let error as CKError where error.isRetryable && attempts > 1 {
        try await Task.sleep(nanoseconds: delay)
        return try await withCloudKitRetry(attempts: attempts - 1, delay: delay * 2, operation)
    }
}

// MARK: - Main Networking class
final class Networking {
    static let shared = Networking()

    // MARK: - Woolworths Product Scrape
    func fetchStoreProducts(for searchTerm: String, completion: @escaping ([StoreProduct]) -> Void) {
        let encodedQuery = searchTerm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://www.woolworths.co.nz/shop/searchproducts?searchTerm=\(encodedQuery)") else {
            completion([])
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                guard let data = data, error == nil,
                      let html = String(data: data, encoding: .utf8) else {
                    print("[ERROR] Failed to fetch Woolworths search page.")
                    completion([])
                    return
                }

                do {
                    let doc = try SwiftSoup.parse(html)
                    let productElements = try doc.select("div.product-tile")

                    var products: [StoreProduct] = []

                    for element in productElements {
                        let titleElement = try? element.select("div.product-title span").first()
                        let imageElement = try? element.select("img.product-image").first()
                        let priceElement = try? element.select("span.price").first()

                        let name = try titleElement?.text() ?? "Unnamed Product"
                        let imageUrl = try imageElement?.attr("src")
                        let price = try priceElement?.text()

                        let isAvailable = name.localizedCaseInsensitiveContains(searchTerm)

                        let product = StoreProduct(
                            name: name,
                            imageUrl: imageUrl,
                            price: price,
                            isAvailable: isAvailable
                        )

                        products.append(product)
                    }

                    print("[INFO] Found \(products.count) products matching '\(searchTerm)'.")
                    completion(products)

                } catch {
                    print("[ERROR] HTML Parsing failed: \(error.localizedDescription)")
                    completion([])
                }
            }
        }
        task.resume()
    }

    // NOTE: The Foodvisor image-analysis call that used to live here shipped a
    // third-party API key inside the binary and had no callers. Any future
    // image recognition must go through the Cloudflare Worker so the key stays
    // server-side, and must be preceded by an explicit consent prompt before a
    // user's photo leaves the device.

    // MARK: - CloudKit Permission Check
    func checkCloudKitPermissions(completion: @escaping (Bool) -> Void) {
        let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        container.accountStatus { status, error in
            if status == .available {
                completion(true)
            } else {
                if let error = error {
                    print("CloudKit error: \(error.localizedDescription)")
                }
                completion(false)
            }
        }
    }

    // MARK: - Image Helpers
    func fixImageOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return normalizedImage
    }

    func compressImage(_ image: UIImage, compressionQuality: CGFloat = 0.6) -> Data? {
        return image.frydgeBoundedJPEG(quality: compressionQuality)
    }

    // MARK: - Remove Image from CloudKit
    func removeImageFromCloud(recipeID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        let publicDatabase = container.publicCloudDatabase
        let recordID = CKRecord.ID(recordName: recipeID)

        publicDatabase.fetch(withRecordID: recordID) { fetchedRecord, error in
            DispatchQueue.main.async {
                if let fetchedRecord = fetchedRecord {
                    fetchedRecord["imageUrls"] = [] as CKRecordValue

                    publicDatabase.save(fetchedRecord) { _, saveError in
                        if let saveError = saveError {
                            print("[ERROR] Failed to remove image: \(saveError.localizedDescription)")
                            completion(.failure(saveError))
                        } else {
                            print("[INFO] Image removed successfully!")
                            completion(.success(()))
                        }
                    }
                } else if let error = error {
                    print("[ERROR] Failed to fetch record for image removal: \(error.localizedDescription)")
                    completion(.failure(error))
                }
            }
        }
    }

    // Offline persistence and retry for recipe saves live in RecipeUploadQueue.
    // The UserDefaults-backed helpers that used to sit here were never drained
    // (the sync method was a stub), so queued recipes never reached CloudKit.

    // MARK: - Save Recipe to CloudKit
    func saveRecipe(_ recipe: CloudRecipe, image: UIImage?, completion: @escaping (Result<Void, Error>) -> Void) {
        let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        let publicDatabase = container.publicCloudDatabase
        let record = recipe.toCKRecord()

        // Helper function to handle final CloudKit save
        func saveToCloudKit(record: CKRecord) {
            publicDatabase.save(record) { _, error in
                DispatchQueue.main.async {
                    if let ckError = error as? CKError, ckError.isRetryable {
                        print("[WARNING] Retriable CloudKit error: \(ckError.localizedDescription)")
                        RecipeUploadQueue.shared.enqueue(recipe, image: image)
                        completion(.failure(ckError))
                    } else if let error = error {
                        print("[ERROR] Failed to save recipe to CloudKit: \(error.localizedDescription)")
                        RecipeUploadQueue.shared.enqueue(recipe, image: image)
                        completion(.failure(error))
                    } else {
                        print("[INFO] Recipe saved successfully to CloudKit.")
                        completion(.success(()))
                    }
                }
            }
        }

        // Nested update logic for saveRecipe if you ever want to call from here
        func updateRecipe(
            _ recipe: CloudRecipe,
            newImages: [UIImage],
            removedImages: [CKAsset],
            completion: @escaping (Result<Void, Error>) -> Void
        ) {
            let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
            let publicDatabase = container.publicCloudDatabase
            let recordID = CKRecord.ID(recordName: recipe.id)

            publicDatabase.fetch(withRecordID: recordID) { fetchedRecord, error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("[ERROR] Failed to fetch record for update: \(error.localizedDescription)")
                        completion(.failure(error))
                        return
                    }

                    guard let record = fetchedRecord else {
                        print("[ERROR] Record not found.")
                        completion(.failure(NSError(domain: "RecordFetchError", code: 0, userInfo: nil)))
                        return
                    }

                    // Update fields
                    record["name"] = recipe.name as CKRecordValue
                    record["ingredients"] = recipe.ingredients as CKRecordValue
                    record["pan"] = recipe.pan as CKRecordValue
                    record["instructions"] = recipe.instructions as CKRecordValue

                    // Handle image updates
                    self.handleImageUpdates(for: record, newImages: newImages, removedImages: removedImages) { result in
                        switch result {
                        case .success:
                            publicDatabase.save(record) { _, saveError in
                                if let saveError = saveError {
                                    print("[ERROR] Failed to save updated record: \(saveError.localizedDescription)")
                                    completion(.failure(saveError))
                                } else {
                                    print("[INFO] Recipe updated successfully.")
                                    completion(.success(()))
                                }
                            }
                        case .failure(let imageError):
                            print("[ERROR] Failed to update images: \(imageError.localizedDescription)")
                            completion(.failure(imageError))
                        }
                    }
                }
            }
        }
        
        // Helper Function to Upload Images
        func uploadImages(
            _ images: [UIImage],
            compressionQuality: CGFloat = 0.6,
            completion: @escaping (Result<[CKAsset], Error>) -> Void
        ) {
            var uploadedAssets: [CKAsset] = []
            let dispatchGroup = DispatchGroup()

            for image in images {
                dispatchGroup.enter()
                if let compressedData = self.compressImage(image, compressionQuality: compressionQuality) {
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                    do {
                        try compressedData.write(to: tempURL)
                        uploadedAssets.append(CKAsset(fileURL: tempURL))
                    } catch {
                        print("[ERROR] Failed to write image to temporary file: \(error.localizedDescription)")
                    }
                }
                dispatchGroup.leave()
            }

            dispatchGroup.notify(queue: .main) {
                if uploadedAssets.count == images.count {
                    completion(.success(uploadedAssets))
                } else {
                    completion(.failure(NSError(domain: "ImageUploadError", code: 0, userInfo: nil)))
                }
            }
        }

        // MARK: - Update Recipe Metadata
        func updateRecipeMetadata(_ recipe: CloudRecipe, completion: @escaping (Result<Void, Error>) -> Void) {
            let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
            let publicDatabase = container.publicCloudDatabase
            let recordID = CKRecord.ID(recordName: recipe.id)

            print("[DEBUG] Attempting to update metadata for recipeID: \(recipe.id)")

            publicDatabase.fetch(withRecordID: recordID) { fetchedRecord, error in
                if let error = error as? CKError, error.code == .unknownItem {
                    print("[ERROR] Record not found. Cannot update metadata: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                } else if let fetchedRecord = fetchedRecord {
                    guard self.isOwnedByCurrentUser(fetchedRecord) else {
                        DispatchQueue.main.async { completion(.failure(RecipeOwnershipError())) }
                        return
                    }
                    fetchedRecord["name"] = recipe.name as CKRecordValue
                    fetchedRecord["ingredients"] = recipe.ingredients as CKRecordValue
                    fetchedRecord["pan"] = recipe.pan as CKRecordValue
                    fetchedRecord["instructions"] = recipe.instructions as CKRecordValue

                    if let imageAsset = recipe.imageAsset {
                        fetchedRecord["imageAsset"] = imageAsset as CKRecordValue
                    }

                    publicDatabase.save(fetchedRecord) { _, saveError in
                        DispatchQueue.main.async {
                            if let saveError = saveError {
                                print("[ERROR] Failed to update metadata: \(saveError.localizedDescription)")
                                completion(.failure(saveError))
                            } else {
                                print("[INFO] Metadata updated successfully.")
                                completion(.success(()))
                            }
                        }
                    }
                } else if let error = error {
                    DispatchQueue.main.async {
                        print("[ERROR] Failed to fetch record for update: \(error.localizedDescription)")
                        completion(.failure(error))
                    }
                }
            }
        }

        // Handle image if provided
        if let image = image {
            guard let compressedData = compressImage(image, compressionQuality: 0.6) else {
                print("[ERROR] Failed to compress image.")
                RecipeUploadQueue.shared.enqueue(recipe, image: image)
                completion(.failure(NSError(domain: "ImageCompressionError", code: 0, userInfo: nil)))
                return
            }

            let filename = "\(recipe.id).jpg"
            let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)

            do {
                try compressedData.write(to: fileURL)
                record["image"] = CKAsset(fileURL: fileURL)
                print("[INFO] Image saved to documents directory: \(fileURL.path)")
            } catch {
                print("[ERROR] Failed to write image to documents directory: \(error.localizedDescription)")
                RecipeUploadQueue.shared.enqueue(recipe, image: image)
                completion(.failure(error))
                return
            }
        }

        saveToCloudKit(record: record)
    }

    // MARK: - Delete Recipe from CloudKit
    /// Deletes a recipe the current user created. Originals by other people are
    /// refused here (and should also be refused by the CloudKit security role:
    /// Recipe → Creator: write, Authenticated: create, World: read).
    func deleteRecipe(_ recipeID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        let publicDatabase = container.publicCloudDatabase
        let recordID = CKRecord.ID(recordName: recipeID)

        publicDatabase.fetch(withRecordID: recordID) { [weak self] fetched, fetchError in
            if let fetchError {
                DispatchQueue.main.async { completion(.failure(fetchError)) }
                return
            }
            guard let self, let fetched, self.isOwnedByCurrentUser(fetched) else {
                DispatchQueue.main.async { completion(.failure(RecipeOwnershipError())) }
                return
            }

            publicDatabase.delete(withRecordID: recordID) { _, error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("Error deleting recipe: \(error.localizedDescription)")
                        completion(.failure(error))
                    } else {
                        print("Recipe successfully deleted!")
                        completion(.success(()))
                    }
                }
            }
        }
    }

    // MARK: - Retry Logic Wrapper
    func retryOperation<T>(
        maxRetries: Int,
        delay: TimeInterval = 2.0,
        operation: @escaping (@escaping (Result<T, Error>) -> Void) -> Void,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        var retries = maxRetries
        func attempt() {
            operation { result in
                switch result {
                case .success:
                    completion(result)
                case .failure(let error):
                    if retries > 0 {
                        retries -= 1
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                            attempt()
                        }
                    } else {
                        completion(.failure(error))
                    }
                }
            }
        }
        attempt()
    }

    // MARK: - Fetch Recipes from CloudKit (iOS 17.7 Compliant)
    func fetchRecipes() async throws -> [CloudRecipe] {
        let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        let publicDatabase = container.publicCloudDatabase
        let query = CKQuery(recordType: "Recipe", predicate: NSPredicate(value: true))

        do {
            let (matchResults, _) = try await publicDatabase.records(matching: query)

            let fetchedRecords = matchResults.compactMap { _, result in
                switch result {
                case .success(let record):
                    return record
                case .failure(let error):
                    print("Error fetching record: \(error.localizedDescription)")
                    return nil
                }
            }

            let recipes = fetchedRecords.compactMap { CloudRecipe(from: $0) }
            print("[INFO] Successfully fetched \(recipes.count) recipes from CloudKit.")
            return recipes
        } catch {
            print("Error fetching recipes: \(error.localizedDescription)")
            throw error
        }
    }
}

// MARK: - Ownership guard

/// Thrown when a write targets a Recipe record the current user didn't create.
/// Originals belong to their author; everyone else edits their own copy.
struct RecipeOwnershipError: LocalizedError {
    var errorDescription: String? {
        "You can only change recipes you created. Make your own version instead."
    }
}

extension Networking {
    /// True when the fetched public-DB record was created by the current iCloud
    /// user. CloudKit reports the caller's own records as `CKCurrentUserDefaultName`.
    func isOwnedByCurrentUser(_ record: CKRecord) -> Bool {
        guard let creator = record.creatorUserRecordID?.recordName else { return false }
        if creator == CKCurrentUserDefaultName { return true }
        if let me = UserDefaults.standard.string(forKey: "appleUserID"), !me.isEmpty {
            return me == creator
        }
        return false
    }
}

// MARK: - Extension for update helpers
extension Networking {

    func updateRecipe(
        _ recipe: CloudRecipe,
        newImages: [UIImage],
        removedImages: [CKAsset],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        let publicDatabase = container.publicCloudDatabase
        let recordID = CKRecord.ID(recordName: recipe.id)

        publicDatabase.fetch(withRecordID: recordID) { [weak self] fetchedRecord, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    print("[ERROR] Failed to fetch record for update: \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }

                guard let record = fetchedRecord else {
                    print("[ERROR] Record not found for recipe ID: \(recipe.id)")
                    completion(.failure(NSError(domain: "RecordFetchError", code: 0, userInfo: nil)))
                    return
                }

                guard self.isOwnedByCurrentUser(record) else {
                    completion(.failure(RecipeOwnershipError()))
                    return
                }

                record["name"] = recipe.name as CKRecordValue
                record["ingredients"] = recipe.ingredients as CKRecordValue
                record["pan"] = recipe.pan as CKRecordValue
                record["instructions"] = recipe.instructions as CKRecordValue

                self.handleImageUpdates(for: record, newImages: newImages, removedImages: removedImages) { result in
                    switch result {
                    case .success:
                        publicDatabase.save(record) { _, saveError in
                            if let saveError = saveError {
                                print("[ERROR] Failed to save updated record: \(saveError.localizedDescription)")
                                completion(.failure(saveError))
                            } else {
                                print("[INFO] Recipe updated successfully.")
                                completion(.success(()))
                            }
                        }
                    case .failure(let imageError):
                        print("[ERROR] Failed to update images: \(imageError.localizedDescription)")
                        completion(.failure(imageError))
                    }
                }
            }
        }
    }

    func createTemporaryFile(for data: Data) -> URL? {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        do {
            try data.write(to: tempURL)
            return tempURL
        } catch {
            print("[ERROR] Failed to create temporary file: \(error.localizedDescription)")
            return nil
        }
    }

    func updateRecordFields(record: CKRecord, with recipe: CloudRecipe) {
        record["name"] = recipe.name as CKRecordValue
        record["ingredients"] = recipe.ingredients as CKRecordValue
        record["pan"] = recipe.pan as CKRecordValue
        record["instructions"] = recipe.instructions as CKRecordValue
    }

    private func saveRecipeToCloudKit(_ recipe: CloudRecipe, completion: @escaping (Result<Void, Error>) -> Void) {
        let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        let publicDatabase = container.publicCloudDatabase
        let record = recipe.toCKRecord()

        if let imageAsset = recipe.imageAsset {
            record["imageAsset"] = imageAsset as CKAsset
        }

        publicDatabase.save(record) { _, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("[ERROR] Failed to save recipe to CloudKit: \(error.localizedDescription)")
                    completion(.failure(error))
                } else {
                    print("[INFO] Recipe successfully saved to CloudKit.")
                    completion(.success(()))
                }
            }
        }
    }

    func updateRecipeFields(recipeID: String, fields: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) {
        let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        let publicDatabase = container.publicCloudDatabase
        let recordID = CKRecord.ID(recordName: recipeID)

        publicDatabase.fetch(withRecordID: recordID) { fetchedRecord, error in
            if let error = error {
                print("[ERROR] Failed to fetch record for updating fields: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            guard let record = fetchedRecord else {
                print("[ERROR] Fetched record is nil.")
                completion(.failure(NSError(domain: "RecordFetchError", code: 0, userInfo: nil)))
                return
            }

            guard self.isOwnedByCurrentUser(record) else {
                completion(.failure(RecipeOwnershipError()))
                return
            }

            for (key, value) in fields {
                if let value = value as? CKRecordValue {
                    record[key] = value
                }
            }

            publicDatabase.save(record) { _, saveError in
                if let saveError = saveError {
                    print("[ERROR] Failed to save updated record: \(saveError.localizedDescription)")
                    completion(.failure(saveError))
                } else {
                    print("[INFO] Record fields updated successfully.")
                    completion(.success(()))
                }
            }
        }
    }

    func handleImageUpdates(
        for record: CKRecord,
        newImages: [UIImage],
        removedImages: [CKAsset],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var existingAssets = (record["imageUrls"] as? [CKAsset]) ?? []

        existingAssets.removeAll { removedImages.contains($0) }

        for image in newImages {
            if let compressedData = compressImage(image, compressionQuality: 0.6),
               let tempURL = createTemporaryFile(for: compressedData) {
                let asset = CKAsset(fileURL: tempURL)
                existingAssets.append(asset)
            } else {
                print("[ERROR] Failed to process a new image for upload.")
                completion(.failure(NSError(domain: "ImageProcessingError", code: 0, userInfo: nil)))
                return
            }
        }

        record["imageUrls"] = existingAssets.isEmpty ? nil : existingAssets as CKRecordValue
        completion(.success(()))
    }
}
