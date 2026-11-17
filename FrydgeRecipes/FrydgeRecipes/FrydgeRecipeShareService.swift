import CloudKit
import CryptoKit
import Foundation
import UIKit

struct PreparedRecipeShare {
    let recipeId: String
    let shareURL: URL
    let imageURL: URL
    let previewImage: UIImage
}

enum FrydgeRecipeShareServiceError: LocalizedError {
    case invalidEndpoint
    case invalidServerResponse(String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The recipe sharing endpoint is invalid."
        case .invalidServerResponse(let message):
            return message
        case .notFound:
            return "That shared recipe is no longer available."
        }
    }
}

/// Publishes recipes to frydge2.com so a share link carries a rich preview
/// *and* the full recipe, and fetches shared recipes back for recipients who
/// don't already have them.
final class FrydgeRecipeShareService {
    static let shared = FrydgeRecipeShareService()

    static let domain = URL(string: "https://frydge2.com")!
    private let uploadEndpoint = URL(string: "https://frydge2.com/api/share-recipe")
    private let publishedFingerprintsKey = "recipeSharePublishedFingerprints"

    private init() {}

    // MARK: - URLs

    // `appendingPathComponent` percent-encodes as needed, so pass the raw id.
    static func shareURL(forRecipeID id: String) -> URL {
        domain.appendingPathComponent("recipe").appendingPathComponent(id)
    }

    static func payloadURL(forRecipeID id: String) -> URL {
        domain.appendingPathComponent("api").appendingPathComponent("recipe").appendingPathComponent(id)
    }

    // MARK: - Publish

    /// Uploads the recipe only when its content changed since the last upload
    /// on this device, so viewing a recipe repeatedly costs nothing.
    func publishIfNeeded(recipe: CloudRecipe, cardImage: UIImage, fingerprint: String) async throws {
        if publishedFingerprint(for: recipe.id) == fingerprint {
            return
        }
        _ = try await publish(recipe: recipe, cardImage: cardImage)
        rememberPublished(fingerprint: fingerprint, for: recipe.id)
    }

    /// Renders the share card and publishes it with the full recipe payload.
    func prepareShare(for recipe: CloudRecipe) async throws -> PreparedRecipeShare {
        let hasAllIngredients = await MainActor.run {
            RecipeShareIcon.localFridgeHasAllIngredients(for: recipe)
        }
        let previewImage = await RecipeShareIcon.renderPrepared(
            recipe: recipe,
            hasAllIngredients: hasAllIngredients
        )
        let prepared = try await publish(recipe: recipe, cardImage: previewImage)
        rememberPublished(fingerprint: recipe.shareFingerprint, for: recipe.id)
        return prepared
    }

    private func publish(recipe: CloudRecipe, cardImage: UIImage) async throws -> PreparedRecipeShare {
        guard let endpoint = uploadEndpoint else {
            throw FrydgeRecipeShareServiceError.invalidEndpoint
        }

        guard let imageData = cardImage.frydgeBoundedJPEG(maxPixelSize: ImageBudget.display, quality: 0.82) else {
            throw FrydgeRecipeShareServiceError.invalidServerResponse("Could not prepare the recipe share image.")
        }

        let payload = ShareRecipeRequest(
            id: recipe.id,
            title: recipe.name,
            description: Self.description(for: recipe),
            time: Self.formattedCookTime(for: recipe),
            imageContentType: "image/jpeg",
            imageWidth: Int(cardImage.size.width * cardImage.scale),
            imageHeight: Int(cardImage.size.height * cardImage.scale),
            imageBase64: imageData.base64EncodedString(),
            uploadKey: "frydge2webrecipes",
            recipe: SharedRecipePayload(recipe: recipe)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(payload.uploadKey, forHTTPHeaderField: "X-Frydge-Upload-Key")
        request.httpBody = try encoder.encode(payload)
        print("[SHARE] Uploading recipe share id=\(recipe.id) imageBytes=\(imageData.count)")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FrydgeRecipeShareServiceError.invalidServerResponse("The recipe sharing server returned a non-HTTP response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 response>"
            print("[SHARE] Upload failed status=\(httpResponse.statusCode) body=\(body)")
            throw FrydgeRecipeShareServiceError.invalidServerResponse("Share upload failed with HTTP \(httpResponse.statusCode).")
        }

        let serverResponse: ShareRecipeResponse
        do {
            serverResponse = try JSONDecoder().decode(ShareRecipeResponse.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 response>"
            print("[SHARE] Decode failed body=\(body)")
            throw FrydgeRecipeShareServiceError.invalidServerResponse("Share upload response could not be decoded.")
        }

        guard let shareURL = URL(string: serverResponse.shareURL),
              let imageURL = URL(string: serverResponse.imageURL) else {
            throw FrydgeRecipeShareServiceError.invalidServerResponse("Share upload returned invalid URLs.")
        }

        print("[SHARE] Upload OK id=\(serverResponse.recipeId) shareURL=\(shareURL.absoluteString)")

        return PreparedRecipeShare(
            recipeId: serverResponse.recipeId,
            shareURL: shareURL,
            imageURL: imageURL,
            previewImage: cardImage
        )
    }

    // MARK: - Fetch (recipient side)

    /// Downloads the recipe a share link points at. Used when the recipient's
    /// app doesn't have the recipe locally or in CloudKit.
    func fetchSharedRecipe(id: String) async throws -> CloudRecipe {
        var request = URLRequest(url: Self.payloadURL(forRecipeID: id))
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FrydgeRecipeShareServiceError.invalidServerResponse("The recipe sharing server returned a non-HTTP response.")
        }
        if http.statusCode == 404 {
            throw FrydgeRecipeShareServiceError.notFound
        }
        guard (200...299).contains(http.statusCode) else {
            throw FrydgeRecipeShareServiceError.invalidServerResponse("Fetching the shared recipe failed with HTTP \(http.statusCode).")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: SharedRecipeEnvelope
        do {
            envelope = try decoder.decode(SharedRecipeEnvelope.self, from: data)
        } catch {
            throw FrydgeRecipeShareServiceError.invalidServerResponse("The shared recipe could not be read.")
        }
        guard let payload = envelope.recipe else {
            throw FrydgeRecipeShareServiceError.notFound
        }
        return payload.makeRecipe(fallbackID: id, fallbackName: envelope.title)
    }

    // MARK: - Fingerprint cache

    private func publishedFingerprint(for recipeID: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: publishedFingerprintsKey) as? [String: String])?[recipeID]
    }

    private func rememberPublished(fingerprint: String, for recipeID: String) {
        var all = (UserDefaults.standard.dictionary(forKey: publishedFingerprintsKey) as? [String: String]) ?? [:]
        all[recipeID] = fingerprint
        // Keep the map bounded; 400 recipes is far more than anyone shares.
        if all.count > 400, let drop = all.keys.sorted().first {
            all.removeValue(forKey: drop)
        }
        UserDefaults.standard.set(all, forKey: publishedFingerprintsKey)
    }

    // MARK: - Images

    static func resolvedRecipeImage(for recipe: CloudRecipe) async -> UIImage? {
        if let image = recipe.image {
            return image
        }

        if let fileURL = recipe.imageAsset?.fileURL,
           let image = UIImage.frydgeBounded(contentsOf: fileURL, maxPixelSize: ImageBudget.display) {
            return image
        }

        for localURL in localImageURLs(for: recipe.id) {
            if let image = UIImage.frydgeBounded(contentsOf: localURL, maxPixelSize: ImageBudget.display) {
                return image
            }
        }

        guard let urlString = recipe.imageSourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty,
              let url = URL(string: urlString) else {
            return nil
        }

        do {
            // Retrying, thumbnail-first download; cache the decoded JPEG so the
            // recipe list can serve it offline afterwards.
            let image = try await RemoteImageFetcher.fetchImage(candidates: RemoteImageFetcher.wikimediaCandidates(for: url))
            if let data = image.jpegData(compressionQuality: 0.85) {
                cacheRecipeImageData(data, recipeId: recipe.id)
            }
            return image
        } catch {
            print("[WARN] Failed to resolve recipe image for sharing: \(error.localizedDescription)")
            return nil
        }
    }

    private static func localImageURLs(for recipeId: String) -> [URL] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return [
            documentsURL
                .appendingPathComponent("recipe-images", isDirectory: true)
                .appendingPathComponent("\(recipeId).jpg"),
            documentsURL.appendingPathComponent("\(recipeId).jpg")
        ]
    }

    private static func cacheRecipeImageData(_ data: Data, recipeId: String) {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directoryURL = documentsURL.appendingPathComponent("recipe-images", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("\(recipeId).jpg")

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("[WARN] Failed to cache recipe image for sharing: \(error.localizedDescription)")
        }
    }

    // MARK: - Text helpers

    static func formattedCookTime(for recipe: CloudRecipe) -> String? {
        let total = recipe.steps.compactMap { $0.timerSeconds }.reduce(0, +)
        guard total > 0 else { return nil }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 && minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }

    static func description(for recipe: CloudRecipe) -> String {
        let parts = [
            formattedCookTime(for: recipe),
            "\(recipe.ingredients.count) ingredients",
            recipe.serves.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "Serves \(recipe.serves)",
            "Open in Frydge"
        ].compactMap { $0 }

        return parts.joined(separator: " · ")
    }
}

// MARK: - Fingerprint

extension CloudRecipe {
    /// Stable digest of everything a share link exposes. Changes whenever the
    /// recipe content changes, so re-publishing only happens when needed.
    var shareFingerprint: String {
        var parts: [String] = [
            "v2", id, name, serves, pan, instructions, location,
            ingredients.joined(separator: "\u{1F}"),
            dietaryTags.joined(separator: "\u{1F}"),
            steps.map { "\($0.text)|\($0.timerSeconds ?? 0)|\($0.temperatureValue ?? 0)\($0.temperatureUnit ?? "")" }.joined(separator: "\u{1E}"),
            imageSourceURL ?? "",
            authorName ?? ""
        ]
        if let modified = modificationDate {
            parts.append(String(modified.timeIntervalSince1970))
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1D}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Wire types

private struct ShareRecipeRequest: Encodable {
    let id: String
    let title: String
    let description: String
    let time: String?
    let imageContentType: String
    let imageWidth: Int
    let imageHeight: Int
    let imageBase64: String
    let uploadKey: String
    let recipe: SharedRecipePayload
}

private struct ShareRecipeResponse: Decodable {
    let recipeId: String
    let shareURL: String
    let imageURL: String

    private enum CodingKeys: String, CodingKey {
        case recipeId
        case id
        case shareURL
        case imageURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recipeId = try container.decodeIfPresent(String.self, forKey: .recipeId)
            ?? container.decode(String.self, forKey: .id)
        shareURL = try container.decode(String.self, forKey: .shareURL)
        imageURL = try container.decode(String.self, forKey: .imageURL)
    }
}

private struct SharedRecipeEnvelope: Decodable {
    let id: String?
    let title: String?
    let recipe: SharedRecipePayload?
}

/// The portable recipe body stored alongside the share link. Mirrors
/// `CloudRecipe`'s Codable fields but with every key optional so older or
/// hand-edited payloads still import.
struct SharedRecipePayload: Codable {
    var id: String?
    var name: String?
    var serves: String?
    var ingredients: [String]?
    var pan: String?
    var instructions: String?
    var steps: [RecipeStep]?
    var location: String?
    var dietaryTags: [String]?
    var ingredientsMetaJSON: String?
    var imageSourceURL: String?
    var imageCredit: ImageCredit?
    var authorName: String?
    /// Who made it, from the sender's point of view. `CKCurrentUserDefaultName`
    /// is meaningless on another device, so the sender substitutes their
    /// Apple user ID (or a placeholder) before uploading.
    var creatorRecordName: String?
    var creationDate: Date?
    var modificationDate: Date?

    init(recipe: CloudRecipe) {
        id = recipe.id
        name = recipe.name
        serves = recipe.serves
        ingredients = recipe.ingredients
        pan = recipe.pan
        instructions = recipe.instructions
        steps = recipe.steps
        location = recipe.location
        dietaryTags = recipe.dietaryTags
        ingredientsMetaJSON = recipe.ingredientsMetaJSON
        imageSourceURL = recipe.imageSourceURL
        imageCredit = recipe.imageCredit
        authorName = recipe.authorName
        creationDate = recipe.creationDate
        modificationDate = recipe.modificationDate

        let me = UserDefaults.standard.string(forKey: "appleUserID")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let creator = recipe.creatorRecordName, creator != CKCurrentUserDefaultName {
            creatorRecordName = creator
        } else if let me, !me.isEmpty {
            creatorRecordName = me
        } else {
            creatorRecordName = "shared-recipe"
        }
    }

    func makeRecipe(fallbackID: String, fallbackName: String?) -> CloudRecipe {
        var recipe = CloudRecipe(
            name: (name ?? fallbackName ?? "Shared Recipe").trimmingCharacters(in: .whitespacesAndNewlines),
            serves: serves ?? "4",
            ingredients: ingredients ?? [],
            pan: pan ?? "",
            instructions: instructions ?? "",
            steps: steps ?? [],
            id: (id?.isEmpty == false ? id! : fallbackID),
            location: location ?? "Fridge",
            dietaryTags: dietaryTags ?? [],
            ingredientsMetaJSON: ingredientsMetaJSON,
            creationDate: creationDate,
            modificationDate: modificationDate,
            imageSourceURL: imageSourceURL,
            authorName: authorName
        )
        recipe.imageCredit = imageCredit
        recipe.creatorRecordName = creatorRecordName
        return recipe
    }
}
