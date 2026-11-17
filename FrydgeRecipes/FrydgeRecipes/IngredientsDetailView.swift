import SwiftUI
import Foundation

struct IngredientsDetailView: View {
    var recipe: CloudRecipe
    @StateObject var shoppingListManager = ShoppingListManager()
    @State private var selectedIngredients: [String] = []
    @Environment(\.colorScheme) var colorScheme
    @State private var showingIngredientDetail = false
    @State private var selectedIngredientDetail: OFFProduct?

    var body: some View {
        VStack {
            if recipe.ingredients.isEmpty {
                Text("No ingredients available.")
                    .foregroundColor(.gray)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(recipe.ingredients, id: \.self) { ingredient in
                            ingredientRow(ingredient: ingredient)
                        }
                    }
                    .padding(.vertical)

                    RecipeAuthorFooter(authorName: recipe.authorName, creationDate: recipe.creationDate)
                }
            }
        }
        .onAppear {
            loadIngredients()
        }
        .sheet(isPresented: $showingIngredientDetail) {
            if let ingredientDetail = selectedIngredientDetail {
                RecipeIngredientInfoView(product: ingredientDetail)
            } else {
                Text("No details available")
            }
        }
    }

    // MARK: - Ingredient Row
    private func ingredientRow(ingredient: String) -> some View {
        HStack {
            Text(ingredient)
                .font(.headline)
                .foregroundColor(.green)
                .padding(.vertical, 10)
                .padding(.leading, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture {
                    fetchIngredientDetails(for: ingredient)
                }

            Button(action: {
                toggleIngredient(ingredient)
            }) {
                Image(systemName: selectedIngredients.contains(ingredient) ? "checkmark.square.fill" : "square")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundColor(.green)
            }
            .padding(.trailing, 15)
        }
        .frame(maxWidth: .infinity)
        .background(colorScheme == .dark ? Color.black : Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.6), lineWidth: 2)
        )
        .cornerRadius(10)
        .padding(.horizontal, 10)
    }

    // MARK: - Toggle Ingredient Selection
    private func toggleIngredient(_ ingredientName: String) {
        if selectedIngredients.contains(ingredientName) {
            selectedIngredients.removeAll { $0 == ingredientName }
            shoppingListManager.removeFromShoppingList(ingredientName) // Pass as String
        } else {
            selectedIngredients.append(ingredientName)
            shoppingListManager.addToShoppingList(ingredientName) // Pass as String
        }
    }

    // MARK: - Load Ingredients
    private func loadIngredients() {
        selectedIngredients = []
    }

    // MARK: - Fetch Ingredient Details
    private func fetchIngredientDetails(for ingredientName: String) {
        Task {
            do {
                let results = try await OpenFoodFactsService.shared.search(ingredientName)
                await MainActor.run {
                    if let first = results.first {
                        self.selectedIngredientDetail = first
                        self.showingIngredientDetail = true
                    } else {
                        print("No OFF product found for \(ingredientName)")
                        self.selectedIngredientDetail = nil
                        self.showingIngredientDetail = false
                    }
                }
            } catch {
                await MainActor.run {
                    print("Error fetching ingredient details: \(error.localizedDescription)")
                    self.selectedIngredientDetail = nil
                    self.showingIngredientDetail = false
                }
            }
        }
    }
}
// MARK: - Recipe Ingredient Info View
struct RecipeIngredientInfoView: View {
    let product: OFFProduct
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Product image
                    if let imageURLString = product.imageUrl,
                       let imageURL = URL(string: imageURLString) {
                        CachedAsyncImage(url: imageURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 250)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            case .failure:
                                placeholderImageView
                            case .empty:
                                ProgressView()
                                    .frame(height: 250)
                            @unknown default:
                                placeholderImageView
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)
                    } else {
                        placeholderImageView
                            .padding(.horizontal)
                    }
                    
                    // Product details
                    VStack(alignment: .leading, spacing: 16) {
                        if let productName = product.productName {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Product Name")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                Text(productName)
                                    .font(.body)
                            }
                        }
                        
                        if let quantity = product.quantity, !quantity.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Quantity")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                Text(quantity)
                                    .font(.body)
                            }
                        }
                        
                        if let ingredients = product.ingredientsText, !ingredients.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Ingredients")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                Text(ingredients)
                                    .font(.body)
                            }
                        }
                        
                        if let code = product.code {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Barcode")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                Text(code)
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 40)
            }
            .navigationTitle("Product Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var placeholderImageView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .frame(height: 250)
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundColor(.secondary)
        }
    }
}

