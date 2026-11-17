import Foundation



struct FoodDetails: Codable {
    let confidence: Double
    let foodInfo: CustomFoodInfo  // Avoid conflicts with OpenFoodFacts SDK
    let ingredients: [IngredientDetails]
}

// Custom struct to avoid conflict with OpenFoodFacts SDK
struct CustomFoodInfo: Codable {
    let foodID: String
    let displayName: String
    let quantity: Double
    let gPerServing: Double
    let nutrition: CustomNutrition  // Updated to CustomNutrition
}

// Struct representing ingredients that make up the food item
struct IngredientDetails: Codable {
    let confidence: Double
    let foodInfo: IngredientInfo
    let quantity: Double
}

// Ingredient-specific information
struct IngredientInfo: Codable {
    let foodID: String
    let displayName: String
    let gPerServing: Double
}

// Struct representing nutrition information of a food item
struct CustomNutrition: Codable {
    let caloriesPer100g: Double?
    let fatPer100g: Double?
    let carbsPer100g: Double?
    let proteinsPer100g: Double?
    let sodiumPer100g: Double?
}
