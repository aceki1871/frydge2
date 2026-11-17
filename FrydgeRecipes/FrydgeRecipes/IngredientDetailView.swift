//
//  IngredientDetailView.swift
//  FrydgeRecipes
//

import SwiftUI
import UIKit

struct IngredientDetailView: View {
    let ingredient: StoredIngredient
    
    @EnvironmentObject var frydgeManager: FrydgeManager
    @StateObject private var recipeListModel = RecipeListModel()
    @Environment(\.dismiss) private var dismiss
    
    // Product info
    @State private var productImageURL: URL?
    @State private var productInfo: OFFProduct?
    @State private var isLoadingProduct = false
    
    // Recipes using this ingredient
    @State private var matchingRecipes: [CloudRecipe] = []
    @State private var selectedRecipe: CloudRecipe?
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Product image and basic info
                    productSection
                    
                    Divider()
                        .padding(.horizontal)
                    
                    // Recipes using this ingredient
                    recipesSection
                }
                .padding(.bottom, 40)
            }
            .navigationTitle(ingredient.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadProductInfo()
                await loadMatchingRecipes()
            }
            .navigationDestination(item: $selectedRecipe) { recipe in
                RecipeDetailView(recipeListModel: recipeListModel, recipe: recipe)
                    .environmentObject(frydgeManager)
            }
        }
    }
    
    // MARK: - Product Section
    
    private var productSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Product image
            if let imageURL = productImageURL {
                CachedAsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    case .failure(_):
                        placeholderImage
                    case .empty:
                        ProgressView()
                            .frame(height: 200)
                    @unknown default:
                        placeholderImage
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
            } else if isLoadingProduct {
                ProgressView()
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
            } else {
                placeholderImage
                    .padding(.horizontal)
            }
            
            // Product details
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Quantity:")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(quantityDisplay)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Location:")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(ingredient.location)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Expires:")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(expirationDisplay)
                        .font(.subheadline)
                        .foregroundColor(ingredient.isExpired ? .red : .secondary)
                }
                
                if !ingredient.dietaryTags.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Dietary Tags:")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        HStack(spacing: 6) {
                            ForEach(ingredient.dietaryTags.sorted(), id: \.self) { tag in
                                DietaryBadgeChip(tag: tag, tone: .brand)
                            }
                        }
                    }
                }
                
                // Product information from OFF
                if let product = productInfo {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Product Information")
                            .font(.headline)
                            .padding(.top, 8)
                        
                        if let ingredients = product.ingredientsText, !ingredients.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Ingredients:")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Text(ingredients)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if let quantity = product.quantity, !quantity.isEmpty {
                            HStack {
                                Text("Package Size:")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Text(quantity)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }
    
    private var placeholderImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .frame(height: 200)
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundColor(.secondary)
        }
    }
    
    private var quantityDisplay: String {
        let qty = ingredient.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = ingredient.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        return [qty, unit].filter { !$0.isEmpty }.joined(separator: " ")
    }
    
    private var expirationDisplay: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: ingredient.expirationDate)
    }
    
    // MARK: - Recipes Section
    
    private var recipesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Used in Recipes")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)
            
            if matchingRecipes.isEmpty {
                Text("No recipes use this ingredient")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 20)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(matchingRecipes, id: \.id) { recipe in
                        Button {
                            selectedRecipe = recipe
                        } label: {
                            HStack(spacing: 12) {
                                recipeRowImage(recipe)
                                    .frame(width: 54, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(recipe.name)
                                        .font(.body)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                        .lineLimit(2)

                                    HStack(spacing: 12) {
                                        if !recipe.serves.isEmpty {
                                            Label(recipe.serves, systemImage: "person.2")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }

                                        let totalSecs = totalCookTimeSeconds(for: recipe)
                                        if totalSecs > 0 {
                                            Label(formatCookTime(totalSecs), systemImage: "clock")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                                    )
                            )
                            .padding(.horizontal)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
    
    // MARK: - Recipe Row Image

    @ViewBuilder
    private func recipeRowImage(_ recipe: CloudRecipe) -> some View {
        if let img = recipe.image {
            Image(uiImage: img).resizable().scaledToFill()
        } else if let assetURL = recipe.imageAsset?.fileURL,
                  let img = UIImage.frydgeBounded(contentsOf: assetURL, maxPixelSize: ImageBudget.thumbnail) {
            Image(uiImage: img).resizable().scaledToFill()
        } else if let urlString = recipe.imageSourceURL,
                  !urlString.isEmpty,
                  let url = URL(string: urlString) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: recipeThumbnailPlaceholder
                }
            }
        } else {
            recipeThumbnailPlaceholder
        }
    }

    private var recipeThumbnailPlaceholder: some View {
        ZStack {
            Color.orange.opacity(0.12)
            Image(systemName: "fork.knife")
                .font(.system(size: 20))
                .foregroundStyle(.orange.opacity(0.7))
        }
    }

    // MARK: - Data Loading
    
    private func loadProductInfo() async {
        isLoadingProduct = true
        defer { isLoadingProduct = false }
        
        // Build search query
        let query = metadataQuery()
        
        // Try Open Food Facts first
        if let imageURL = await fetchOFFImageURL(for: query),
           let product = await fetchOFFProduct(for: query) {
            await MainActor.run {
                productImageURL = imageURL
                productInfo = product
            }
            return
        }
        
        // Fallback to store offers
        let offers = await StockAvailability.fetchOffers(for: query)
        if let best = offers.first(where: { $0.imageURL != nil }) {
            await MainActor.run {
                productImageURL = best.imageURL
            }
        }
    }
    
    private func loadMatchingRecipes() async {
        await recipeListModel.fetchRecipesFromCloud()

        // Shared token matcher: brand words, pack sizes and prefixes never match.
        let itemTokens = IngredientMatcher.tokens(ingredient.name)
        let matches: [CloudRecipe] = itemTokens.isEmpty ? [] : recipeListModel.recipes.filter { recipe in
            IngredientMatcher.tokensMatch(IngredientMatcher.recipeTokens(recipe.ingredients), itemTokens)
        }

        await MainActor.run {
            matchingRecipes = matches
        }
    }
    
    private func metadataQuery() -> String {
        let qty = ingredient.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = ingredient.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [ingredient.name, qty, unit].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return parts.joined(separator: " ")
    }
    
    private func fetchOFFImageURL(for query: String) async -> URL? {
        guard var components = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "search_terms", value: query),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: "1")
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(OFFSearchResponse.self, from: data)
            let raw = decoded.products.first?.imageFrontURL ?? decoded.products.first?.imageURL
            if let raw, let imageURL = URL(string: raw) { return imageURL }
        } catch {
            return nil
        }
        return nil
    }
    
    private func fetchOFFProduct(for query: String) async -> OFFProduct? {
        guard var components = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "search_terms", value: query),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: "1")
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            
            let decoded = try JSONDecoder().decode(OFFSearchResponse.self, from: data)
            guard let firstProduct = decoded.products.first else { return nil }
            
            return OFFProduct(
                code: firstProduct.code,
                productName: firstProduct.productName ?? ingredient.name,
                ingredientsText: firstProduct.ingredientsText,
                quantity: firstProduct.quantity,
                imageUrl: firstProduct.imageFrontURL ?? firstProduct.imageURL,
                nutriments: nil
            )
        } catch {
            return nil
        }
    }
    
    // ✅ FIXED: Use steps array instead of prepTime/cookTime
    private func totalCookTimeSeconds(for recipe: CloudRecipe) -> Int {
        guard !recipe.steps.isEmpty else { return 0 }
        return recipe.steps.reduce(0) { partial, step in
            partial + max(0, step.timerSeconds ?? 0)
        }
    }
    
    private func formatCookTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let mins = (seconds % 3600) / 60
        
        if hours > 0 && mins > 0 {
            return "\(hours)h \(mins)m"
        } else if hours > 0 {
            return "\(hours)h"
        } else if mins > 0 {
            return "\(mins)m"
        } else {
            return "\(seconds)s"
        }
    }
}

// MARK: - Supporting Types

private struct OFFSearchResponse: Decodable {
    let products: [OFFSearchProduct]
}

private struct OFFSearchProduct: Decodable {
    let code: String?
    let productName: String?
    let ingredientsText: String?
    let quantity: String?
    let imageFrontURL: String?
    let imageURL: String?

    enum CodingKeys: String, CodingKey {
        case code
        case productName = "product_name"
        case ingredientsText = "ingredients_text"
        case quantity
        case imageFrontURL = "image_front_url"
        case imageURL = "image_url"
    }
}
