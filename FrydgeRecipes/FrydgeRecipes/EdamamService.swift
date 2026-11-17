//
//  EdamamService.swift
//  FrydgeRecipes
//
//  Wraps the Edamam Food Database API v2.
//  Credentials live in ProductImageCacheManager — this service reads them from there
//  so they only need to be set in one place.
//
//  API shape (per 100g unless noted):
//  GET /api/food-database/v2/parser?app_id=&app_key=&ingr=chicken&nutrition-type=logging
//  → { parsed: [{ food }], hints: [{ food, measures }] }
//
//  food {
//    foodId, label, knownAs, category, categoryLabel, image,
//    nutrients: { ENERC_KCAL, PROCNT, FAT, CHOCDF, FIBTG }
//  }
//  measures [{ label, weight(g) }]

import Foundation

// MARK: - Public result type

struct EdamamFoodResult: Codable {
    let label: String
    let imageURL: URL?
    let category: String?          // e.g. "Generic foods", "Packaged foods"
    let calories: Double?          // kcal per 100 g
    let proteinG: Double?          // g per 100 g
    let fatG: Double?              // g per 100 g
    let carbsG: Double?            // g per 100 g
    let fiberG: Double?            // g per 100 g
    let measures: [EdamamMeasure]
}

struct EdamamMeasure: Codable {
    let label: String   // "Gram", "Ounce", "Cup", "Whole", etc.
    let weightG: Double // grams per 1 unit of this measure
}

// MARK: - Service

actor EdamamService {
    static let shared = EdamamService()

    // Reads credentials from ProductImageCacheManager via a thin accessor below.
    // Set them once there; everything else is automatic.
    private var appID:  String { EdamamCredentials.appID  }
    private var appKey: String { EdamamCredentials.appKey }

    private var isConfigured: Bool { !appID.isEmpty && !appKey.isEmpty }

    // In-memory cache; populated from disk on first use so data survives relaunches
    private var resultCache: [String: EdamamFoodResult]

    private static let diskCacheURL: URL? =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("edamam-nutrition-cache.json")
    private static let diskCacheMaxAge: TimeInterval = 7 * 24 * 60 * 60

    private init() {
        resultCache = EdamamService.loadFromDisk()
    }

    private static func loadFromDisk() -> [String: EdamamFoodResult] {
        guard let url = diskCacheURL,
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([String: EdamamDiskEntry].self, from: data)
        else { return [:] }
        let cutoff = Date().addingTimeInterval(-diskCacheMaxAge)
        return entries.reduce(into: [:]) { dict, kv in
            if kv.value.cachedAt > cutoff { dict[kv.key] = kv.value.result }
        }
    }

    private func persistToDisk() {
        let snapshot = resultCache
        Task.detached(priority: .background) {
            let entries = snapshot.mapValues { EdamamDiskEntry(result: $0, cachedAt: Date()) }
            guard let url = EdamamService.diskCacheURL,
                  let data = try? JSONEncoder().encode(entries) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Main entry point

    /// Fetch food data for an ingredient name. Returns nil if unconfigured or not found.
    func fetchFood(for name: String) async -> EdamamFoodResult? {
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConfigured, !key.isEmpty else { return nil }

        if let cached = resultCache[key] { return cached }

        guard var components = URLComponents(string: "https://api.edamam.com/api/food-database/v2/parser") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "app_id",          value: appID),
            URLQueryItem(name: "app_key",         value: appKey),
            URLQueryItem(name: "ingr",            value: name),
            URLQueryItem(name: "nutrition-type",  value: "logging")
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }

            let raw = try JSONDecoder().decode(EdamamAPIResponse.self, from: data)

            // Prefer "parsed" (exact match) over "hints" (fuzzy matches)
            let food = raw.parsed?.first?.food ?? raw.hints?.first?.food
            guard let food else { return nil }

            let measures = raw.hints?.first?.measures?.compactMap { m -> EdamamMeasure? in
                guard let label = m.label, let weight = m.weight, weight > 0 else { return nil }
                return EdamamMeasure(label: label, weightG: weight)
            } ?? []

            let result = EdamamFoodResult(
                label:    food.label ?? name,
                imageURL: food.image.flatMap { URL(string: $0) },
                category: food.categoryLabel ?? food.category,
                calories: food.nutrients?.ENERC_KCAL,
                proteinG: food.nutrients?.PROCNT,
                fatG:     food.nutrients?.FAT,
                carbsG:   food.nutrients?.CHOCDF,
                fiberG:   food.nutrients?.FIBTG,
                measures: measures
            )

            resultCache[key] = result
            persistToDisk()
            return result
        } catch {
            return nil
        }
    }
}

// MARK: - Disk cache entry

private struct EdamamDiskEntry: Codable {
    let result: EdamamFoodResult
    let cachedAt: Date
}

// MARK: - Credential accessor
// Bridges to the constants already stored in ProductImageCacheManager.

enum EdamamCredentials {
    static var appID:  String = ""
    static var appKey: String = ""
}

// MARK: - Private Decodable models

private struct EdamamAPIResponse: Decodable {
    let parsed: [EdamamParsedItem]?
    let hints:  [EdamamHint]?
}

private struct EdamamParsedItem: Decodable {
    let food: EdamamFood?
}

private struct EdamamHint: Decodable {
    let food:     EdamamFood?
    let measures: [EdamamMeasureRaw]?
}

private struct EdamamFood: Decodable {
    let foodId:        String?
    let label:         String?
    let knownAs:       String?
    let category:      String?
    let categoryLabel: String?
    let image:         String?
    let nutrients:     EdamamNutrients?
}

private struct EdamamNutrients: Decodable {
    let ENERC_KCAL: Double?  // calories
    let PROCNT:     Double?  // protein g
    let FAT:        Double?  // fat g
    let CHOCDF:     Double?  // carbs g
    let FIBTG:      Double?  // fiber g
}

private struct EdamamMeasureRaw: Decodable {
    let label:  String?
    let weight: Double?
}
