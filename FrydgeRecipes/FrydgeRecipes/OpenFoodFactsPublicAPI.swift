//
//  OpenFoodFactsPublicAPI.swift
//  FrydgeRecipes
//
//  Thin client for the public Open Food Facts product API, used only to
//  fill the gaps the Frydge products Worker leaves: the live Green-Score
//  (OFF's renamed Eco-Score, with far better coverage than the Worker's
//  snapshot column), the Agribalyse carbon figure behind it, and the
//  additive tags OFF has already parsed from the ingredients.
//
//  Scores are the only reason to call this; nutrition still comes from the
//  Worker so the two can't disagree on the macro boxes.
//

import Foundation

struct OFFPublicExtras: Equatable, Sendable {
    var greenScoreGrade: String?
    var greenScoreScore: Int?
    /// kg CO₂e per kg (Agribalyse `co2_total`).
    var co2PerKg: Double?
    var nutriScore: String?
    var nova: Int?
    var additiveTags: [String] = []
    var ingredientsText: String?

    var environmental: EnvironmentalImpact? {
        EnvironmentalImpact(grade: greenScoreGrade, score: greenScoreScore, co2PerKg: co2PerKg, source: .greenScore)
    }
}

final class OpenFoodFactsPublicAPI: @unchecked Sendable {

    static let shared = OpenFoodFactsPublicAPI()

    private let baseURL = URL(string: "https://world.openfoodfacts.org/api/v2/product/")!
    private let fields = [
        "environmental_score_grade", "environmental_score_score", "environmental_score_data",
        "ecoscore_grade", "ecoscore_score", "ecoscore_data",
        "nutriscore_grade", "nova_group", "additives_tags", "ingredients_text"
    ].joined(separator: ",")

    private let session: URLSession
    private var cache: [String: OFFPublicExtras?] = [:]
    private let lock = NSLock()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// Extras for a barcode, or nil when OFF doesn't know the product or the
    /// network fails. Misses are cached too so a scan isn't retried on every
    /// redraw.
    func extras(for barcode: String) async -> OFFPublicExtras? {
        let code = barcode.filter(\.isNumber)
        guard !code.isEmpty else { return nil }

        if let hit = cached(code) { return hit }

        guard var comps = URLComponents(url: baseURL.appendingPathComponent(code), resolvingAgainstBaseURL: false) else { return nil }
        comps.queryItems = [URLQueryItem(name: "fields", value: fields)]
        guard let url = comps.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Frydge-iOS/1.0 (frydge app)", forHTTPHeaderField: "User-Agent")

        var result: OFFPublicExtras? = nil
        if let (data, response) = try? await session.data(for: request),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           envelope.status == 1, let p = envelope.product {
            var extras = OFFPublicExtras()
            extras.greenScoreGrade = p.environmentalScoreGrade ?? p.ecoscoreGrade
            extras.greenScoreScore = (p.environmentalScoreScore ?? p.ecoscoreScore).map { Int($0.rounded()) }
            extras.co2PerKg = p.environmentalScoreData?.agribalyse?.co2Total ?? p.ecoscoreData?.agribalyse?.co2Total
            extras.nutriScore = p.nutriscoreGrade
            extras.nova = p.novaGroup
            extras.additiveTags = p.additivesTags ?? []
            extras.ingredientsText = p.ingredientsText
            result = extras
        }

        store(result, for: code)
        return result
    }

    // MARK: - Cache (synchronous so the lock is never held across an await)

    private func cached(_ code: String) -> OFFPublicExtras?? {
        lock.withLock { cache[code] }
    }

    private func store(_ extras: OFFPublicExtras?, for code: String) {
        lock.withLock {
            cache[code] = extras
            if cache.count > 300 { cache.removeAll() }
        }
    }

    // MARK: - Wire format

    private struct Envelope: Decodable {
        let status: Int?
        let product: Product?

        private enum CodingKeys: String, CodingKey { case status, product }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = Lenient.int(c, .status)
            product = try c.decodeIfPresent(Product.self, forKey: .product)
        }
    }

    private struct Product: Decodable {
        let environmentalScoreGrade: String?
        let environmentalScoreScore: Double?
        let environmentalScoreData: ScoreData?
        let ecoscoreGrade: String?
        let ecoscoreScore: Double?
        let ecoscoreData: ScoreData?
        let nutriscoreGrade: String?
        let novaGroup: Int?
        let additivesTags: [String]?
        let ingredientsText: String?

        private enum CodingKeys: String, CodingKey {
            case environmentalScoreGrade = "environmental_score_grade"
            case environmentalScoreScore = "environmental_score_score"
            case environmentalScoreData = "environmental_score_data"
            case ecoscoreGrade = "ecoscore_grade"
            case ecoscoreScore = "ecoscore_score"
            case ecoscoreData = "ecoscore_data"
            case nutriscoreGrade = "nutriscore_grade"
            case novaGroup = "nova_group"
            case additivesTags = "additives_tags"
            case ingredientsText = "ingredients_text"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            environmentalScoreGrade = try? c.decodeIfPresent(String.self, forKey: .environmentalScoreGrade)
            environmentalScoreScore = Lenient.double(c, .environmentalScoreScore)
            environmentalScoreData = try? c.decodeIfPresent(ScoreData.self, forKey: .environmentalScoreData)
            ecoscoreGrade = try? c.decodeIfPresent(String.self, forKey: .ecoscoreGrade)
            ecoscoreScore = Lenient.double(c, .ecoscoreScore)
            ecoscoreData = try? c.decodeIfPresent(ScoreData.self, forKey: .ecoscoreData)
            nutriscoreGrade = try? c.decodeIfPresent(String.self, forKey: .nutriscoreGrade)
            novaGroup = Lenient.int(c, .novaGroup)
            additivesTags = try? c.decodeIfPresent([String].self, forKey: .additivesTags)
            ingredientsText = try? c.decodeIfPresent(String.self, forKey: .ingredientsText)
        }
    }

    private struct ScoreData: Decodable {
        let agribalyse: Agribalyse?
    }

    private struct Agribalyse: Decodable {
        let co2Total: Double?
        private enum CodingKeys: String, CodingKey { case co2Total = "co2_total" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            co2Total = Lenient.double(c, .co2Total)
        }
    }

    /// OFF serialises numbers inconsistently (ints, doubles, or strings),
    /// so read them permissively.
    private enum Lenient {
        static func double<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Double? {
            if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
            if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return Double(i) }
            if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Double(s) }
            return nil
        }
        static func int<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int? {
            if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i }
            if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(d) }
            if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Int(s) }
            return nil
        }
    }
}
