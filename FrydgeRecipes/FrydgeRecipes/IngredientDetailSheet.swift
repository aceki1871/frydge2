import SwiftUI
import PhotosUI

/// Where the detail sheet's edits are written. Defaults (when not supplied) route
/// to the personal `FrydgeManager`; the shared frydges pass an implementation that
/// writes to `SharedFridgeManager` so the *same* sheet edits either store.
struct IngredientEditActions {
    /// Applies a new storage location and returns the (possibly recomputed) best-before date.
    var setLocation: (String) async -> Date
    var setExpiration: (Date) async -> Void
    var delete: () async -> Void
}

struct IngredientDetailSheet: View {
    let ingredient: StoredIngredient
    let onUsageChanged: (Double) -> Void

    /// Non-nil for shared frydge items; nil uses the personal FrydgeManager path.
    private let providedActions: IngredientEditActions?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var frydgeManager: FrydgeManager
    @EnvironmentObject private var shoppingListManager: ShoppingListManager
    @StateObject private var recipeListModel = RecipeListModel()

    @State private var usagePercentage: Double
    @State private var editableExpiryDate: Date
    @State private var selectedLocation: String
    @State private var showingDeleteConfirmation = false
    /// Recipes using this item, best fridge match first (shared matcher).
    @State private var matchingRecipes: [(recipe: CloudRecipe, match: RecipeMatch)] = []
    @State private var selectedRecipe: CloudRecipe?
    @State private var completeRecipe: CloudRecipe?
    @State private var isLoadingRecipes = false
    @State private var headerImage: UIImage?
    @State private var nutritionFacts: ProductNutritionFacts?
    @State private var isLoadingNutrition = true
    @State private var userPhotos: [UIImage]
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var carouselIndex: Int = 0
    /// Extra remote photos for the carousel (products DB, Wikimedia Commons).
    @State private var galleryURLs: [URL] = []
    /// Photos other Frydge users contributed for this item — shown after the
    /// automated gallery, each reportable.
    @State private var communityPhotos: [CommunityPhoto] = []
    @State private var communityPickerItem: PhotosPickerItem?
    @State private var isUploadingCommunityPhoto = false
    /// Live supermarket specials / vouchers for this product, cheapest first.
    @State private var specialOffers: [StockAvailability.StoreOffer] = []
    @State private var selectedTechnique: ChefTechnique?

    init(
        ingredient: StoredIngredient,
        actions: IngredientEditActions? = nil,
        onUsageChanged: @escaping (Double) -> Void
    ) {
        self.ingredient = ingredient
        self.providedActions = actions
        self.onUsageChanged = onUsageChanged
        _usagePercentage = State(initialValue: ingredient.quantityUsed)
        _editableExpiryDate = State(initialValue: ingredient.expirationDate)
        _selectedLocation = State(initialValue: FoodStorageClassifier.normalize(ingredient.location))
        // Local library first; otherwise the copies CloudKit synced for this
        // item, which also seeds the local library for next time.
        let photoBlobs = UserPhotoLibrary.shared.photosWithSyncedFallback(for: ingredient.name) {
            FrydgeManager.shared.syncedPhotos(forItemID: ingredient.id)
        }
        _userPhotos = State(initialValue: photoBlobs.compactMap { UIImage.frydgeBounded(data: $0, maxPixelSize: ImageBudget.display) })
    }

    /// Resolves to the supplied shared-frydge actions, or a default set backed by
    /// the personal `FrydgeManager`.
    private var actions: IngredientEditActions {
        if let providedActions { return providedActions }
        return IngredientEditActions(
            setLocation: { newLocation in
                frydgeManager.setLocation(for: ingredient.id, to: newLocation)
                return frydgeManager.storedIngredients.first(where: { $0.id == ingredient.id })?.expirationDate
                    ?? editableExpiryDate
            },
            setExpiration: { newDate in
                frydgeManager.setExpirationDate(for: ingredient.id, to: newDate)
            },
            delete: {
                await frydgeManager.deleteItem(ingredient)
            }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Nutrition and product facts lead; price is already shown on
                // the shopping list and sits at the very end here.
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    Divider()
                    nutritionSection

                    // Live vouchers / specials at nearby supermarkets for this product.
                    if !specialOffers.isEmpty {
                        Divider()
                        specialsSection
                    }

                    // Chef: how to crack, fillet, dice… whatever this food needs.
                    let prepTechniques = ChefTechniqueLibrary.relevant(toFood: ingredient.name)
                    if !prepTechniques.isEmpty {
                        Divider()
                        chefSection(prepTechniques)
                    }

                    Divider()
                    infoSection
                    Divider()
                    expirationSection

                    if !ingredient.dietaryTags.isEmpty {
                        Divider()
                        dietaryTagsSection
                    }

                    Divider()
                    recipesSection

                    if let observed = ObservedPriceStore.shared.latest(for: ingredient.name) {
                        Divider()
                        priceSection(observed)
                    }
                }
                .padding()
            }
            .navigationTitle("Item Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
            .confirmationDialog("Delete Item", isPresented: $showingDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    Task {
                        await actions.delete()
                        dismiss()
                    }
                }

                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Are you sure you want to delete \(ingredient.name)?")
            }
            .task {
                // Network lookups run side by side; none blocks the others.
                async let specials: Void = loadSpecials()
                async let gallery: Void = loadGallery()
                async let community: Void = loadCommunityPhotos()
                await loadMatchingRecipes()
                await loadHeaderImage()
                await loadNutrition()
                _ = await (specials, gallery, community)
            }
            .sheet(item: $selectedTechnique) { technique in
                NavigationStack { ChefTechniqueDetailView(technique: technique) }
            }
            .navigationDestination(item: $selectedRecipe) { recipe in
                RecipeDetailView(recipeListModel: recipeListModel, recipe: recipe)
                    .environmentObject(frydgeManager)
            }
            .sheet(item: $completeRecipe) { recipe in
                RecipeMissingIngredientsSheet(recipe: recipe)
                    .environmentObject(frydgeManager)
                    .environmentObject(shoppingListManager)
            }
            // Keep the ranking live as the fridge changes underneath the sheet.
            .onChange(of: frydgeManager.storedIngredients) { _, _ in
                applyRecipeFilter()
            }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 12) {
            // Carousel order: the user's own photos, the cached header image,
            // then extra remote photos streamed in as they load.
            let allImages: [UIImage] = userPhotos + (headerImage.map { [$0] } ?? [])
            let pageCount = allImages.count + galleryURLs.count + communityPhotos.count

            ZStack(alignment: .bottomTrailing) {
                if pageCount == 0 {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.systemGray5))
                        Text(FoodEmoji.emoji(for: ingredient.name))
                            .font(.system(size: 64))
                    }
                } else {
                    TabView(selection: $carouselIndex) {
                        ForEach(0..<pageCount, id: \.self) { i in
                            Group {
                                if i < allImages.count {
                                    Image(uiImage: allImages[i])
                                        .resizable()
                                        .scaledToFill()
                                } else if i < allImages.count + galleryURLs.count {
                                    CachedAsyncImage(url: galleryURLs[i - allImages.count]) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image.resizable().scaledToFill()
                                        case .failure:
                                            Color(.systemGray5)
                                        default:
                                            ZStack {
                                                Color(.systemGray6)
                                                ProgressView()
                                            }
                                        }
                                    }
                                } else {
                                    Image(uiImage: communityPhotos[i - allImages.count - galleryURLs.count].image)
                                        .resizable()
                                        .scaledToFill()
                                }
                            }
                            .clipped()
                            .tag(i)
                            .overlay(alignment: .topTrailing) {
                                if i < userPhotos.count {
                                    Button {
                                        deleteUserPhoto(at: i)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(.white)
                                            .shadow(color: .black.opacity(0.4), radius: 3)
                                    }
                                    .padding(10)
                                } else if i >= allImages.count + galleryURLs.count {
                                    let photo = communityPhotos[i - allImages.count - galleryURLs.count]
                                    Menu {
                                        Button("Report photo", systemImage: "flag") {
                                            reportCommunityPhoto(photo)
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(.white)
                                            .shadow(color: .black.opacity(0.4), radius: 3)
                                    }
                                    .padding(10)
                                }
                            }
                            .overlay(alignment: .bottomLeading) {
                                if i >= allImages.count + galleryURLs.count {
                                    Text("Shared by a Frydge user")
                                        .font(.caption2)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(.black.opacity(0.4), in: Capsule())
                                        .padding(8)
                                }
                            }
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: pageCount > 1 ? .always : .never))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                HStack(spacing: 8) {
                    PhotosPicker(selection: $communityPickerItem, matching: .images) {
                        Image(systemName: isUploadingCommunityPhoto ? "arrow.triangle.2.circlepath" : "person.2.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 3)
                    }
                    .disabled(isUploadingCommunityPhoto)
                    .accessibilityLabel("Share a photo with other Frydge users")

                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 3)
                    }
                    .accessibilityLabel("Add a private photo")
                }
                .padding(10)
            }
            .frame(height: 200)
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let item = newItem else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.upload),
                       let jpeg = img.jpegData(compressionQuality: 0.8) {
                        userPhotos.insert(img, at: 0)
                        UserPhotoLibrary.shared.addPhoto(jpeg, for: ingredient.name)
                        carouselIndex = 0
                    }
                    selectedPhotoItem = nil
                }
            }
            .onChange(of: communityPickerItem) { _, newItem in
                guard let item = newItem else { return }
                Task {
                    isUploadingCommunityPhoto = true
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.upload) {
                        _ = try? await CommunityPhotoStore.shared.upload(img, barcode: nil, name: ingredient.name)
                        await loadCommunityPhotos()
                    }
                    isUploadingCommunityPhoto = false
                    communityPickerItem = nil
                }
            }

            Text(ingredient.name)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private func deleteUserPhoto(at index: Int) {
        guard index < userPhotos.count else { return }
        userPhotos.remove(at: index)
        UserPhotoLibrary.shared.removePhoto(at: index, for: ingredient.name)
        let total = userPhotos.count + (headerImage != nil ? 1 : 0) + galleryURLs.count + communityPhotos.count
        if carouselIndex >= total { carouselIndex = max(0, total - 1) }
    }

    private func reportCommunityPhoto(_ photo: CommunityPhoto) {
        Task {
            try? await CommunityPhotoStore.shared.report(photo)
            await loadCommunityPhotos()
            let total = userPhotos.count + (headerImage != nil ? 1 : 0) + galleryURLs.count + communityPhotos.count
            if carouselIndex >= total { carouselIndex = max(0, total - 1) }
        }
    }

    // MARK: - Info Section

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Information")
                .font(.headline)

            if !quantityDisplay.isEmpty {
                HStack {
                    Text("Quantity:")
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(quantityDisplay)
                        .fontWeight(.medium)
                }
            }

            HStack {
                Text("Location:")
                    .foregroundColor(.secondary)

                Spacer()

                Picker("Location", selection: $selectedLocation) {
                    Text("Fridge").tag(FoodStorageClassifier.fridge)
                    Text("Freezer").tag(FoodStorageClassifier.freezer)
                    Text("Pantry").tag(FoodStorageClassifier.pantry)
                }
                .pickerStyle(.menu)
                .onChange(of: selectedLocation) { _, newLocation in
                    // setLocation recomputes best-before; reflect it in the date picker.
                    Task {
                        let newExpiry = await actions.setLocation(newLocation)
                        editableExpiryDate = newExpiry
                    }
                }
            }

            Divider()
                .opacity(0.4)

            // "Half the bag" chips instead of a bare percentage slider.
            UsageChipPicker(itemName: ingredient.name, usagePercentage: $usagePercentage)
                .onChange(of: usagePercentage) { _, newValue in
                    onUsageChanged(newValue)
                }
        }
    }

    // MARK: - Price Section (last, deliberately)

    private func priceSection(_ observed: ObservedPrice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Price")
                .font(.headline)
            HStack {
                Text("Last paid:")
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    if observed.isSpecial {
                        Image(systemName: "tag.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(lastPaidText(observed))
                        .fontWeight(.medium)
                }
            }
        }
    }

    /// "$4.50 · New World · 3 Aug" style summary for an observed price.
    private func lastPaidText(_ observed: ObservedPrice) -> String {
        var parts = [observed.priceText]
        if let store = observed.store, !store.isEmpty { parts.append(store) }
        let df = DateFormatter()
        df.dateFormat = "d MMM"
        parts.append(df.string(from: observed.date))
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Expiration Section

    private var expirationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Expiration")
                .font(.headline)

            DatePicker(
                "Best Before",
                selection: $editableExpiryDate,
                displayedComponents: .date
            )
            .onChange(of: editableExpiryDate) { _, newDate in
                Task { await actions.setExpiration(newDate) }
            }

            HStack {
                Text("Status:")
                    .foregroundColor(.secondary)

                Spacer()

                Text(expirationStatusText)
                    .fontWeight(.medium)
                    .foregroundColor(expirationStatusColor)
            }
        }
    }

    // MARK: - Dietary Tags Section

    private var dietaryTagsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dietary Tags")
                .font(.headline)

            FlowLayout(spacing: 8) {
                ForEach(Array(ingredient.dietaryTags).sorted(), id: \.self) { tag in
                    DietaryBadgeChip(tag: tag, tone: .brand)
                }
            }
        }
    }

    // MARK: - Recipes Section

    private var recipesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recipes Using This")
                    .font(.headline)

                Spacer()

                if isLoadingRecipes {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            if isLoadingRecipes {
                Color.clear.frame(height: 1)
            } else if matchingRecipes.isEmpty {
                Text("No recipes found for this ingredient")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                Text("Ranked by what else is already in your frydge")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    ForEach(matchingRecipes.prefix(6), id: \.recipe.id) { entry in
                        recipeMatchRow(entry.recipe, match: entry.match)
                    }
                }
            }
        }
    }

    private func recipeMatchRow(_ recipe: CloudRecipe, match: RecipeMatch) -> some View {
        let tint: Color = match.percent >= 0.9 ? .green : match.percent >= 0.5 ? .blue : .orange
        return HStack(spacing: 12) {
            Button {
                selectedRecipe = recipe
            } label: {
                HStack(spacing: 12) {
                    recipeRowImage(recipe)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(recipe.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        HStack(spacing: 6) {
                            Text(match.percentText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(tint)
                            Text(match.isComplete
                                 ? "You have everything"
                                 : "Missing \(match.missing.count) of \(match.total)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if match.isComplete {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                // "Complete this recipe": add what's missing to the shopping list.
                Button {
                    completeRecipe = recipe
                } label: {
                    Image(systemName: "cart.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 34, height: 34)
                        .background(Color.blue.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add missing ingredients for \(recipe.name) to shopping list")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    // MARK: - Recipe Image

    @ViewBuilder
    private func recipeRowImage(_ recipe: CloudRecipe) -> some View {
        if let img = recipe.image {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else if let assetURL = recipe.imageAsset?.fileURL,
                  let img = UIImage.frydgeBounded(contentsOf: assetURL, maxPixelSize: ImageBudget.thumbnail) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else if let imageUrlString = recipe.imageSourceURL,
                  !imageUrlString.isEmpty,
                  let imageUrl = URL(string: imageUrlString) {
            CachedAsyncImage(url: imageUrl) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    recipeImagePlaceholder
                }
            }
        } else {
            recipeImagePlaceholder
        }
    }

    private var recipeImagePlaceholder: some View {
        ZStack {
            Color.orange.opacity(0.15)

            Image(systemName: "fork.knife")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Header Image

    private func loadHeaderImage() async {
        let key = ProductImageCacheManager.shared.imageCacheKey(name: ingredient.name, quantity: "", unit: "")
        if let cached = ProductImageCacheManager.shared.uiImage(forKey: key) {
            headerImage = cached
            return
        }
        // Race OFF + Wikipedia + Edamam; first valid image wins
        await ProductImageCacheManager.shared.prefetchIfNeeded(for: ingredient.name)
        if let cached = ProductImageCacheManager.shared.uiImage(forKey: key) {
            headerImage = cached
        }
    }

    // MARK: - Nutrition Section

    /// Same component the add-flow preview and scanned-product sheet use.
    private var nutritionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProductNutritionCard(facts: nutritionFacts, isLoading: isLoadingNutrition, productName: ingredient.name)

            if let brand = nutritionFacts?.brand, !brand.isEmpty,
               !ingredient.name.localizedCaseInsensitiveContains(brand) {
                HStack {
                    Text("Brand:")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                    Spacer()
                    Text(brand)
                        .font(.subheadline.weight(.medium))
                }
            }
            if let size = nutritionFacts?.quantity, !size.isEmpty {
                HStack {
                    Text("Pack size:")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                    Spacer()
                    Text(size)
                        .font(.subheadline.weight(.medium))
                }
            }
        }
    }

    private func loadNutrition() async {
        isLoadingNutrition = true
        nutritionFacts = await ProductNutritionFacts.lookup(name: ingredient.name)
        isLoadingNutrition = false
    }

    // MARK: - Photo gallery

    /// Extra photos for the carousel, skipping whatever the header already shows.
    private func loadGallery() async {
        let key = ProductImageCacheManager.shared.imageCacheKey(name: ingredient.name, quantity: "", unit: "")
        let headerRemote = ProductImageCacheManager.shared.cachedInfo(forKey: key)?.remoteURL
        let urls = await ProductImageCacheManager.shared.galleryImageURLs(for: ingredient.name, limit: 4)
        galleryURLs = urls.filter { $0.absoluteString != headerRemote }
    }

    private func loadCommunityPhotos() async {
        communityPhotos = await CommunityPhotoStore.shared.photos(barcode: nil, name: ingredient.name)
    }

    // MARK: - Specials Section

    /// Current supermarket vouchers / specials for this product. Only offers
    /// the retailer flags as a promotion are shown, one per chain, cheapest
    /// first. Everything comes from the same live offer feed the shopping
    /// list uses, so a deal here is a deal there.
    private func loadSpecials() async {
        let offers = await StockAvailability.fetchOffers(for: ingredient.name)
        var seenChains = Set<String>()
        specialOffers = offers
            .filter { $0.promoText != nil && $0.isProbablyMatch }
            .sorted { ($0.price ?? .infinity) < ($1.price ?? .infinity) }
            .filter { seenChains.insert($0.store.lowercased()).inserted }
    }

    private var specialsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("On special near you", systemImage: "tag.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            ForEach(specialOffers) { offer in
                Link(destination: offer.productURL) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "tag.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .frame(width: 28, height: 28)
                            .background(Color.orange.opacity(0.12), in: Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(offer.store)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            if let title = offer.productTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !title.isEmpty {
                                Text(title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            if let promo = offer.promoText {
                                Text(promo)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        }

                        Spacer(minLength: 8)

                        VStack(alignment: .trailing, spacing: 2) {
                            if let price = offer.price {
                                Text(price.formatted(.currency(code: offer.currencyCode)))
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.primary)
                            }
                            if let metres = offer.distanceMeters {
                                Text(Measurement(value: metres, unit: UnitLength.meters)
                                    .formatted(.measurement(width: .abbreviated, usage: .road)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(offer.store): \(offer.promoText ?? "special")")
            }
        }
    }

    // MARK: - Chef Section

    private func chefSection(_ techniques: [ChefTechnique]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("How to prep")
                    .font(.headline)
                Spacer()
                ChefButton(relevant: techniques, context: ingredient.name)
                    .foregroundStyle(.orange)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(techniques) { technique in
                        Button {
                            selectedTechnique = technique
                        } label: {
                            HStack(spacing: 6) {
                                Text(technique.emoji)
                                Text(technique.title)
                                    .font(.subheadline.weight(.medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Recipe Loading

    private func loadMatchingRecipes() async {
        isLoadingRecipes = true

        // Show from cache immediately (RecipeListModel.init already loaded these)
        applyRecipeFilter()
        isLoadingRecipes = false

        // Silently refresh if the cache is stale, then re-filter
        await recipeListModel.fetchIfStale(maxAge: 5 * 60)
        applyRecipeFilter()
    }

    /// Recipes that use this item, ranked by how much of the rest of the
    /// recipe is already in the fridge. Goes through FrydgeManager.recipesUsing
    /// (RecipeMatch.swift) so it agrees with the recipes list and detail.
    private func applyRecipeFilter() {
        matchingRecipes = frydgeManager.recipesUsing(ingredient, from: recipeListModel.recipes)
    }

    // MARK: - Helpers

    private var quantityDisplay: String {
        let quantity = ingredient.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = ingredient.unit.trimmingCharacters(in: .whitespacesAndNewlines)

        return [quantity, unit]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var daysUntilExpiration: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: editableExpiryDate).day ?? 0
    }

    private var isCurrentlyExpired: Bool {
        editableExpiryDate < Calendar.current.startOfDay(for: Date())
    }

    private var expirationStatusText: String {
        let daysLeft = daysUntilExpiration

        if isCurrentlyExpired {
            let daysPast = abs(daysLeft)
            return daysPast == 0 ? "Expired today" : "Expired \(daysPast) day\(daysPast == 1 ? "" : "s") ago"
        } else if daysLeft == 0 {
            return "Expires today"
        } else if daysLeft == 1 {
            return "Expires in 1 day"
        } else {
            return "Expires in \(daysLeft) days"
        }
    }

    private var expirationStatusColor: Color {
        (isCurrentlyExpired || daysUntilExpiration <= 0) ? .red : .blue
    }
}

// MARK: - FlowLayout Helper

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.replacingUnspecifiedDimensions().width,
            subviews: subviews,
            spacing: spacing
        )

        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing
        )

        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + result.positions[index].x,
                    y: bounds.minY + result.positions[index].y
                ),
                proposal: .unspecified
            )
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let subviewSize = subview.sizeThatFits(.unspecified)

                if currentX + subviewSize.width > maxWidth && currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }

                positions.append(CGPoint(x: currentX, y: currentY))
                lineHeight = max(lineHeight, subviewSize.height)
                currentX += subviewSize.width + spacing
            }

            size = CGSize(
                width: maxWidth,
                height: currentY + lineHeight
            )
        }
    }
}
