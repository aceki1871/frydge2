//
//  RecipeThumbnailView.swift
//  FrydgeRecipes
//
//  Rounded recipe photo used in planner/picker rows. Resolution order matches
//  RecipeListView: the on-disk prefetch cache first (recipe-images/{id}.jpg,
//  then legacy {id}.jpg in Documents), then the remote imageSourceURL, and
//  finally the food-emoji placeholder for recipes with no photo at all.
//

import SwiftUI

struct RecipeThumbnailView: View {
    let recipeID: String
    let recipeName: String
    let imageSourceURL: String?
    var size: CGFloat = 68

    // Off-main-thread disk/network load with an in-memory cache, shared with
    // SuggestedRecipeCard — avoids blocking disk reads in `body` and avoids
    // re-decoding the same image every time a list row scrolls back into view.
    @StateObject private var imageLoader = RecipeImageLoader()

    var body: some View {
        Group {
            if let image = imageLoader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if imageLoader.isLoading {
                ZStack {
                    Color.gray.opacity(0.12)
                    ProgressView()
                }
            } else {
                emojiPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .accessibilityHidden(true)
        .task(id: recipeID) {
            // Bundled default-pack recipes never have a server-side photo, so
            // don't fire a CloudKit lookup for each one as rows scroll by.
            imageLoader.load(
                id: recipeID,
                remoteURLString: imageSourceURL,
                mayExistInCloudKit: !DefaultRecipePack.isDefault(id: recipeID),
                recipeName: recipeName
            )
        }
    }

    private var emojiPlaceholder: some View {
        // Same artwork the recipe cards and detail header use, so a recipe
        // without a photo looks consistent everywhere it appears.
        RecipePlaceholderArtwork(recipeName: recipeName, emojiScale: 0.5)
    }
}
