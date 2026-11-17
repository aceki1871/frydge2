import Foundation

// Renamed the protocol to avoid potential conflicts
protocol CustomProductProtocol {
    var productName: String? { get }
    var ingredientsList: String? { get }
    var quantityValue: Int? { get }
}

// Renamed the struct
struct CustomManualProduct: CustomProductProtocol {
    var productName: String?
    var ingredientsList: String?
    var quantityValue: Int?
}
