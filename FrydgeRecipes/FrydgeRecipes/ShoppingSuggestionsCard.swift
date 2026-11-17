//
//  ShoppingSuggestionsCard.swift
//  FrydgeRecipes
//
//  Horizontal strip of AI-generated shopping suggestions shown at the top of
//  ShoppingListView. Each suggestion is a small card with a product photo
//  (user photo → cached product image → OpenFoodFacts lookup → emoji fallback).
//  Requires Apple Intelligence (iOS 26+) but gracefully renders nothing on
//  earlier OS versions.
//

import SwiftUI

struct ShoppingSuggestionsCard: View {
    let suggestions: [ShoppingSuggestion]
    let isLoading: Bool
    let onAdd: (ShoppingSuggestion) -> Void
    let onRefresh: () -> Void

    var body: some View {
        if isLoading || !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header
                if isLoading && suggestions.isEmpty {
                    loadingRow
                } else {
                    cardRow
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
                .font(.subheadline.weight(.semibold))
            Text("Suggested for you")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            if isLoading && !suggestions.isEmpty {
                ProgressView()
                    .scaleEffect(0.7)
            }
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .disabled(isLoading)
            .accessibilityLabel("Refresh suggestions")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// Skeleton cards keep the strip's height stable while the model thinks.
    private var loadingRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.systemGray5))
                            .frame(height: SuggestionCard.imageHeight)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.systemGray5))
                            .frame(width: 80, height: 10)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.systemGray5))
                            .frame(width: 110, height: 8)
                    }
                    .padding(10)
                    .frame(width: SuggestionCard.width)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    .redacted(reason: .placeholder)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .accessibilityLabel("Thinking of suggestions")
    }

    private var cardRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(suggestions) { suggestion in
                    SuggestionCard(suggestion: suggestion, onAdd: { onAdd(suggestion) })
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - Individual card

private struct SuggestionCard: View {
    static let width: CGFloat = 148
    static let imageHeight: CGFloat = 84

    let suggestion: ShoppingSuggestion
    let onAdd: () -> Void

    @State private var added = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                FoodItemThumbnail(
                    name: suggestion.name,
                    width: Self.width - 20,
                    height: Self.imageHeight,
                    cornerRadius: 10,
                    emojiFont: .largeTitle
                )

                Button {
                    guard !added else { return }
                    withAnimation(.snappy) { added = true }
                    onAdd()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: added ? "checkmark" : "plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(added ? Color.green : Color.purple, in: Circle())
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                }
                .disabled(added)
                .padding(6)
                .accessibilityLabel(added ? "Added \(suggestion.name)" : "Add \(suggestion.name) to list")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(suggestion.reason)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .padding(10)
        .frame(width: Self.width, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Food thumbnail (reusable)

/// Small product photo for a food name. Resolution order:
/// 1. a photo the user took of this item,
/// 2. the on-disk product image cache,
/// 3. an OpenFoodFacts search by name (result is cached for next time),
/// 4. the food emoji as a placeholder.
struct FoodItemThumbnail: View {
    let name: String
    var width: CGFloat = 44
    var height: CGFloat = 44
    var cornerRadius: CGFloat = 10
    var emojiFont: Font = .title3

    @ObservedObject private var photoLibrary = UserPhotoLibrary.shared
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let userPhoto = photoLibrary.firstUIImage(for: name) {
                Image(uiImage: userPhoto)
                    .resizable()
                    .scaledToFill()
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityHidden(true)
        .task(id: name) { await loadImage() }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(.systemGray6))
            Text(FoodEmoji.emoji(for: name))
                .font(emojiFont)
        }
    }

    private func loadImage() async {
        let key = ProductImageCacheManager.shared.imageCacheKey(name: name, quantity: "", unit: "")

        if let cached = ProductImageCacheManager.shared.uiImage(forKey: key) {
            image = cached
            return
        }

        guard let products = try? await OpenFoodFactsService.shared.search(name) else { return }
        guard let match = products.first(where: { product in
            guard let productName = product.productName, !productName.isEmpty else { return true }
            return isFoodRelevant(responseText: productName, query: name)
        }), let rawURL = match.imageUrl, let url = URL(string: rawURL) else { return }

        _ = try? await ProductImageCacheManager.shared.storeImage(
            from: url,
            forKey: key,
            productName: name,
            storeName: nil
        )
        if !Task.isCancelled {
            image = ProductImageCacheManager.shared.uiImage(forKey: key)
        }
    }
}
