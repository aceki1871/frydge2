//
//  UPCItemDBService.swift
//  FrydgeRecipes
//
//  Barcode lookup fallback via UPC Item DB (free tier, 100 req/day, no API key).
//  Used when OpenFoodFacts returns no result.
//

import Foundation

// MARK: - Model

struct UPCItem: Codable, ProductProtocol {
    let ean: String?
    let title: String?
    let description: String?
    let brand: String?
    let size: String?
    let images: [String]?

    var productName: String? {
        guard let t = title, !t.isEmpty else { return nil }
        // Strip brand prefix if it duplicates the name (e.g. "Colgate Colgate Total…")
        if let b = brand, t.lowercased().hasPrefix(b.lowercased()) { return t }
        if let b = brand, !b.isEmpty { return "\(b) \(t)" }
        return t
    }

    var ingredientsList: String? {
        guard let d = description, !d.isEmpty else { return nil }
        return d
    }

    var quantityValue: Int? {
        guard let raw = size else { return nil }
        let (num, _) = OFFProduct.parseQuantityAndUnit(from: raw)
        return num.map { Int($0) }
    }

    var imageUrl: String? { images?.first }
}

private struct UPCItemDBResponse: Codable {
    let code: String?
    let total: Int?
    let items: [UPCItem]?
}

// MARK: - Service

final class UPCItemDBService {
    static let shared = UPCItemDBService()
    private init() {}

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    func lookup(_ barcode: String) async throws -> UPCItem {
        let urlString = "https://api.upcitemdb.com/prod/trial/lookup?upc=\(barcode)"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, _) = try await session.data(for: request)
        let decoded = try JSONDecoder().decode(UPCItemDBResponse.self, from: data)

        guard decoded.code == "OK", let item = decoded.items?.first else {
            throw NSError(
                domain: "UPCItemDB",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Product not found in UPC Item DB"]
            )
        }
        return item
    }
}
