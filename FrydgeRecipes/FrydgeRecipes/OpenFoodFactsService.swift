

import Foundation

// MARK: - Shared Protocol for Product Representation

protocol ProductProtocol {
    var productName: String? { get }
    var ingredientsList: String? { get }
    var quantityValue: Int? { get }
}

// MARK: - Nutriments Model (unchanged)

struct OFFNutriments: Codable {
    let energyKcal: Double?
    let fat: Double?
    let carbs: Double?
    let proteins: Double?

    enum CodingKeys: String, CodingKey {
        case energyKcal = "energy-kcal_100g"
        case fat = "fat_100g"
        case carbs = "carbohydrates_100g"
        case proteins = "proteins_100g"
    }
}

// MARK: - Product Model (unchanged — memberwise init preserved)
//
// Do NOT add stored properties here. Several views call the synthesised
// memberwise init directly (ShoppingListView, FridgeView, ProductDetailsView).
// Richer data lives on `FrydgeProduct` below.

struct OFFProduct: Codable, ProductProtocol {

    let code: String?
    let productName: String?
    let ingredientsText: String?
    let quantity: String?
    let imageUrl: String?
    let nutriments: OFFNutriments?

    enum CodingKeys: String, CodingKey {
        case code
        case productName = "product_name"
        case ingredientsText = "ingredients_text"
        case quantity
        case imageUrl = "image_url"
        case nutriments
    }

    var ingredientsList: String? { ingredientsText }

    var quantityValue: Int? {
        guard let raw = quantity else { return nil }
        let (num, _) = OFFProduct.parseQuantityAndUnit(from: raw)
        guard let num else { return nil }
        return Int(num)
    }

    /// Parses "500g", "1.5l", "330 ml", etc. into (numericValue, unit).
    static func parseQuantityAndUnit(from raw: String) -> (Double?, String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }

        let pattern = #"(\d+(?:[.,]\d+)?)\s*([a-zA-Z]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.numberOfRanges >= 2,
              let numRange = Range(match.range(at: 1), in: trimmed) else {
            return (nil, nil)
        }

        let numStr = String(trimmed[numRange]).replacingOccurrences(of: ",", with: ".")
        let number = Double(numStr)

        var unit: String? = nil
        if match.numberOfRanges >= 3, let unitRange = Range(match.range(at: 2), in: trimmed) {
            let u = String(trimmed[unitRange]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !u.isEmpty { unit = u }
        }

        return (number, unit)
    }
}

// MARK: - Full OFF API Response Wrapper (kept for source compatibility)

struct OFFResponse: Codable {
    let status: Int?
    let statusVerbose: String?
    let product: OFFProduct?
}

// MARK: - Frydge Worker payload
//
// The richer shape the Worker actually returns. Use this directly in
// ProductDetailsView / DietaryBadgeChip when you're ready for brand,
// Nutri-Score and dietary flags.

struct FrydgeProduct: Codable, Sendable {
    struct Dietary: Codable, Sendable {
        /// Three-state on purpose. `nil` means "unknown", which must never be
        /// rendered as either a tick or a cross — someone with coeliac disease
        /// should not see "gluten free" because a field was missing.
        let vegan: Int?
        let vegetarian: Int?
        let glutenFree: Int?
        let dairyFree: Int?

        var isVegan: Bool? { vegan.map { $0 == 1 } }
        var isVegetarian: Bool? { vegetarian.map { $0 == 1 } }
        var isGlutenFree: Bool? { glutenFree.map { $0 == 1 } }
        var isDairyFree: Bool? { dairyFree.map { $0 == 1 } }
    }

    struct Nutrition: Codable, Sendable {
        // These property names deliberately match what NutritionEngine's
        // Mirror lookup expects. Rename any of them and nutrition scoring
        // silently breaks — Mirror finds nothing and returns nil, no error.
        let energyKcal100g: Double?
        let fat100g: Double?
        let saturatedFat100g: Double?
        let carbohydrates100g: Double?
        let sugars100g: Double?
        let fiber100g: Double?
        let proteins100g: Double?
        let salt100g: Double?

        /// NutritionEngine scores sodium; OFF stores salt. Stored rather than
        /// computed, because Mirror only sees stored properties.
        let sodium100g: Double?

        enum CodingKeys: String, CodingKey {
            case energyKcal100g
            case fat100g
            case saturatedFat100g  = "satFat100g"
            case carbohydrates100g = "carbs100g"
            case sugars100g
            case fiber100g         = "fibre100g"
            case proteins100g      = "protein100g"
            case salt100g
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            energyKcal100g    = try c.decodeIfPresent(Double.self, forKey: .energyKcal100g)
            fat100g           = try c.decodeIfPresent(Double.self, forKey: .fat100g)
            saturatedFat100g  = try c.decodeIfPresent(Double.self, forKey: .saturatedFat100g)
            carbohydrates100g = try c.decodeIfPresent(Double.self, forKey: .carbohydrates100g)
            sugars100g        = try c.decodeIfPresent(Double.self, forKey: .sugars100g)
            fiber100g         = try c.decodeIfPresent(Double.self, forKey: .fiber100g)
            proteins100g      = try c.decodeIfPresent(Double.self, forKey: .proteins100g)
            salt100g          = try c.decodeIfPresent(Double.self, forKey: .salt100g)
            sodium100g        = salt100g.map { $0 / 2.5 }   // salt = sodium x 2.5
        }
    }

    let gtin: String
    let code: String
    let name: String?
    let brand: String?
    let quantity: String?
    let quantityValue: Double?
    let quantityUnit: String?
    let categories: String?
    let imageURL: String?
    let imageSmallURL: String?
    let dietary: Dietary?
    let nutriscore: String?
    let nova: Int?
    let ecoscore: String?
    let nutrition: Nutrition?
    let ingredientsText: String?
    let updatedAt: Int?

    /// Bridge to the legacy type used across the app.
    var asOFFProduct: OFFProduct {
        OFFProduct(
            code: code,
            productName: displayName,
            ingredientsText: ingredientsText,
            quantity: quantity,
            imageUrl: imageURL ?? imageSmallURL,
            nutriments: OFFNutriments(
                energyKcal: nutrition?.energyKcal100g,
                fat: nutrition?.fat100g,
                carbs: nutrition?.carbohydrates100g,
                proteins: nutrition?.proteins100g
            )
        )
    }

    /// OFF names are often bare ("milk"), so prefix the brand when we have one.
    var displayName: String? {
        guard let name, !name.isEmpty else { return nil }
        guard let brand, !brand.isEmpty else { return name }
        let firstBrand = brand.split(separator: ",").first.map(String.init) ?? brand
        if name.lowercased().contains(firstBrand.lowercased()) { return name }
        return "\(firstBrand) \(name)"
    }
}

// MARK: - Errors

enum FrydgeProductsError: LocalizedError {
    case notFound(String)
    case offline
    case badResponse(Int)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .notFound(let code):  return "No product found for \(code)."
        case .offline:             return "You appear to be offline."
        case .badResponse(let s):  return "Product service returned status \(s)."
        case .decoding:            return "Couldn't read the product data."
        }
    }
}

// MARK: - MAIN SERVICE

final class OpenFoodFactsService {

    static let shared = OpenFoodFactsService()

    /// Your deployed Worker. Change here only.
    private let baseURL = URL(string: "https://frydge-products.davekitson-read.workers.dev")!

    /// The search endpoint now returns nutrition, scores and dietary flags
    /// for every hit, so only the first result needs a follow-up request —
    /// and only for its ingredients list, which search omits by design.
    private let hydrateCount = 1

    private let session: URLSession
    private let decoder = JSONDecoder()

    /// Small in-memory cache. The Worker sets Cache-Control too, but this
    /// avoids a round trip entirely when the same barcode is scanned twice.
    private var memoryCache: [String: (product: FrydgeProduct, at: Date)] = [:]
    private let cacheTTL: TimeInterval = 60 * 60
    private let cacheLock = NSLock()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.waitsForConnectivity = false
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 64 * 1024 * 1024,
            diskPath: "frydge-products"
        )
        self.session = URLSession(configuration: config)
    }

    // MARK: - Fetch by Barcode (signature unchanged)

    func fetchByBarcode(_ barcode: String) async throws -> OFFProduct {
        try await fetchRich(barcode).asOFFProduct
    }

    /// Richer variant — brand, Nutri-Score, dietary flags.
    func fetchRich(_ barcode: String) async throws -> FrydgeProduct {
        let key = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw FrydgeProductsError.notFound(barcode) }

        if let cached = cachedProduct(for: key) { return cached }

        struct Envelope: Codable { let source: String?; let product: FrydgeProduct }

        let url = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("product")
            .appendingPathComponent(key)

        let envelope: Envelope = try await get(url, notFoundCode: key)
        store(envelope.product, for: key)
        return envelope.product
    }

    // MARK: - Search (signature unchanged)

    func search(_ query: String) async throws -> [OFFProduct] {
        let rich = try await searchRich(query)
        return rich.map(\.asOFFProduct)
    }

    func searchRich(_ query: String) async throws -> [FrydgeProduct] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        struct Results: Codable { let results: [FrydgeProduct] }

        var comps = URLComponents(
            url: baseURL.appendingPathComponent("v1").appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: "20"),
        ]
        guard let url = comps.url else { throw URLError(.badURL) }

        let light: Results = try await get(url, notFoundCode: trimmed)
        guard !light.results.isEmpty else { return [] }

        // The search endpoint returns a lighter column set (no nutrition or
        // ingredients). Hydrate the top few so `.first` behaves as callers
        // expect. These are edge-cached, so it's cheap.
        let toHydrate = Array(light.results.prefix(hydrateCount))
        let rest = Array(light.results.dropFirst(hydrateCount))

        let hydrated: [FrydgeProduct] = await withTaskGroup(of: (Int, FrydgeProduct?).self) { group in
            for (i, p) in toHydrate.enumerated() {
                group.addTask { [weak self] in
                    guard let self else { return (i, nil) }
                    return (i, try? await self.fetchRich(p.code))
                }
            }
            var slots = [FrydgeProduct?](repeating: nil, count: toHydrate.count)
            for await (i, p) in group { slots[i] = p }
            // Fall back to the light row if hydration failed.
            return slots.enumerated().map { $0.element ?? toHydrate[$0.offset] }
        }

        return hydrated + rest
    }

    // MARK: - Batch fetch
    //
    // For views that show many products at once (FridgeView, ShoppingListView).
    // One request instead of N — the old code fired a separate call per item,
    // which on a 30-item shopping list meant 30 round trips.

    func fetchMany(_ codes: [String]) async -> [String: FrydgeProduct] {
        let unique = Array(Set(codes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
        guard !unique.isEmpty else { return [:] }

        var out: [String: FrydgeProduct] = [:]
        var toFetch: [String] = []

        for code in unique {
            if let cached = cachedProduct(for: code) { out[code] = cached }
            else { toFetch.append(code) }
        }
        guard !toFetch.isEmpty else { return out }

        struct BatchResponse: Codable { let results: [FrydgeProduct] }

        // D1 caps bound parameters at 100 per query, so chunk accordingly.
        for chunk in stride(from: 0, to: toFetch.count, by: 100).map({
            Array(toFetch[$0..<min($0 + 100, toFetch.count)])
        }) {
            var comps = URLComponents(
                url: baseURL.appendingPathComponent("v1").appendingPathComponent("products"),
                resolvingAgainstBaseURL: false
            )!
            comps.queryItems = [URLQueryItem(name: "codes", value: chunk.joined(separator: ","))]
            guard let url = comps.url else { continue }

            guard let response: BatchResponse = try? await get(url, notFoundCode: "") else { continue }

            for product in response.results {
                store(product, for: product.code)
                // Key by whatever the caller passed in, as well as the
                // normalised GTIN — a 13-digit scan must find a 14-digit row.
                out[product.code] = product
                out[product.gtin] = product
                if let original = chunk.first(where: { Self.gtin14($0) == product.gtin }) {
                    out[original] = product
                }
            }
        }
        return out
    }

    /// Mirrors the Worker's normalisation. Keep the two in step.
    static func gtin14(_ input: String) -> String? {
        let digits = input.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        if digits.count > 14 { return String(digits.suffix(14)) }
        return String(repeating: "0", count: 14 - digits.count) + digits
    }

    // MARK: - Networking

    private func get<T: Decodable>(_ url: URL, notFoundCode: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Frydge-iOS/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw FrydgeProductsError.offline
            default:
                throw error
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw FrydgeProductsError.badResponse(0)
        }
        guard http.statusCode != 404 else {
            throw FrydgeProductsError.notFound(notFoundCode)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FrydgeProductsError.badResponse(http.statusCode)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw FrydgeProductsError.decoding(error)
        }
    }

    // MARK: - Cache

    private func cachedProduct(for key: String) -> FrydgeProduct? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let entry = memoryCache[key] else { return nil }
        guard Date().timeIntervalSince(entry.at) < cacheTTL else {
            memoryCache.removeValue(forKey: key)
            return nil
        }
        return entry.product
    }

    private func store(_ product: FrydgeProduct, for key: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        memoryCache[key] = (product, Date())
        // Also key by the normalised GTIN so a 13-digit scan hits a 14-digit entry.
        memoryCache[product.gtin] = (product, Date())
        if memoryCache.count > 500 { memoryCache.removeAll() }
    }

    func clearCache() {
        cacheLock.lock(); memoryCache.removeAll(); cacheLock.unlock()
        session.configuration.urlCache?.removeAllCachedResponses()
    }
}
