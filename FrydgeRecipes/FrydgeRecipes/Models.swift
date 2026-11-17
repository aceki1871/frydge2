import Foundation

// Store struct
struct Store: Codable, Hashable, Identifiable {
    let id: UUID = UUID()
    var name: String
    var vicinity: String
    var latitude: Double
    var longitude: Double
    var storehours: String
    var phoneNumber: String?
    var website: String

    enum CodingKeys: String, CodingKey {
        case name, vicinity, latitude, longitude, storehours, phoneNumber, website
    }
}

// Enum to represent the store's open/closed and reachable status
enum StoreAvailabilityStatus: String, Codable, Hashable {
    case openAndReachable
    case openNotReachable
    case closed
}

// Response from Places API (Google or Predefined)
struct PlacesResponse: Codable {
    var results: [Store]
}
struct SharedShoppingListItem: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var quantity: String
    var unit: String
    var location: String
    var dietaryTags: [String]

    init(id: UUID = UUID(), name: String, quantity: String = "", unit: String = "", location: String = "", dietaryTags: [String] = []) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.location = location
        self.dietaryTags = dietaryTags
    }

    var displayString: String {
        let q = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.lowercased() == "ea", !q.isEmpty { return "\(name) x\(q)" }
        if !q.isEmpty || !u.isEmpty { return "\(name) \(q)\(u)".trimmingCharacters(in: .whitespacesAndNewlines) }
        return name
    }
}

struct RecipeSuggestionPayload: Codable, Hashable {
    static let tagPrefix = "FRYDGE_RECIPE_SUGGESTION:"

    let recipeID: String
    let recipeName: String
    let ingredients: [String]
    let dietaryTags: [String]
    let suggestedAt: Date

    var encodedTag: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return Self.tagPrefix + data.base64EncodedString()
    }
}

extension SharedShoppingListItem {
    var recipeSuggestionPayload: RecipeSuggestionPayload? {
        for tag in dietaryTags where tag.hasPrefix(RecipeSuggestionPayload.tagPrefix) {
            let raw = String(tag.dropFirst(RecipeSuggestionPayload.tagPrefix.count))
            guard let data = Data(base64Encoded: raw),
                  let payload = try? JSONDecoder().decode(RecipeSuggestionPayload.self, from: data) else {
                continue
            }
            return payload
        }
        return nil
    }

    var isRecipeSuggestion: Bool {
        recipeSuggestionPayload != nil
    }
}
