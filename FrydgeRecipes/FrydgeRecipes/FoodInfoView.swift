import SwiftUI
import PhotosUI

struct FoodInfoView: View {
    var ingredient: String
    var userProvidedImageUrl: String?

    @Environment(\.dismiss) private var dismiss

    @State private var offProduct: OFFProduct?
    @State private var edamamResult: EdamamFoodResult?
    @State private var isLoading = true

    @State private var userPhotos: [UIImage] = []
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var carouselIndex: Int = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    Divider()
                    nutritionSection
                        .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                userPhotos = UserPhotoLibrary.shared.photos(for: ingredient).compactMap { UIImage.frydgeBounded(data: $0, maxPixelSize: ImageBudget.display) }
                await loadData()
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let img = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.upload),
                       let jpeg = img.jpegData(compressionQuality: 0.8) {
                        userPhotos.insert(img, at: 0)
                        UserPhotoLibrary.shared.addPhoto(jpeg, for: ingredient)
                        carouselIndex = 0
                    }
                    selectedPhotoItem = nil
                }
            }
        }
    }

    private var displayName: String {
        offProduct?.productName ?? edamamResult?.label ?? ingredient
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            let offImageURL: URL? = {
                if let s = offProduct?.imageUrl, !s.isEmpty, let u = URL(string: s) { return u }
                if let s = userProvidedImageUrl, !s.isEmpty, let u = URL(string: s) { return u }
                return nil
            }()

            ZStack(alignment: .bottomTrailing) {
                imageArea(userPhotos: userPhotos, offImageURL: offImageURL)

                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .padding(10)
                }
            }
            .frame(height: 200)

            Text(displayName)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func imageArea(userPhotos: [UIImage], offImageURL: URL?) -> some View {
        if !userPhotos.isEmpty {
            TabView(selection: $carouselIndex) {
                ForEach(userPhotos.indices, id: \.self) { i in
                    Image(uiImage: userPhotos[i])
                        .resizable()
                        .scaledToFill()
                        .clipped()
                        .tag(i)
                        .overlay(alignment: .topTrailing) {
                            Button { deleteUserPhoto(at: i) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.4), radius: 3)
                            }
                            .padding(10)
                        }
                }
                if let url = offImageURL {
                    offImageView(url: url).tag(userPhotos.count)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: (userPhotos.count + (offImageURL != nil ? 1 : 0)) > 1 ? .always : .never))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if let url = offImageURL {
            offImageView(url: url)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            emojiPlaceholder
        }
    }

    private func offImageView(url: URL) -> some View {
        CachedAsyncImage(url: url) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFill().clipped()
            case .empty:
                ZStack {
                    Color(.systemGray5)
                    ProgressView()
                }
            default:
                emojiPlaceholder
            }
        }
    }

    private var emojiPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemGray5))
            Text(FoodEmoji.emoji(for: ingredient))
                .font(.system(size: 64))
        }
    }

    private func deleteUserPhoto(at index: Int) {
        guard index < userPhotos.count else { return }
        userPhotos.remove(at: index)
        UserPhotoLibrary.shared.removePhoto(at: index, for: ingredient)
        carouselIndex = max(0, carouselIndex - 1)
    }

    // MARK: - Nutrition

    @ViewBuilder
    private var nutritionSection: some View {
        let kcal    = offProduct?.nutriments?.energyKcal ?? edamamResult?.calories
        let fat     = offProduct?.nutriments?.fat         ?? edamamResult?.fatG
        let carbs   = offProduct?.nutriments?.carbs       ?? edamamResult?.carbsG
        let protein = offProduct?.nutriments?.proteins    ?? edamamResult?.proteinG
        let fiber   = edamamResult?.fiberG
        let usingEdamam = offProduct?.nutriments == nil && edamamResult != nil

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Nutritional Information")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView().scaleEffect(0.7)
                } else if usingEdamam {
                    Text("via Edamam")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                } else if offProduct?.nutriments != nil {
                    Text("via Open Food Facts")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }

            if !isLoading {
                VStack(spacing: 6) {
                    nutritionRow("Energy",  value: kcal,    unit: "kcal")
                    nutritionRow("Fat",     value: fat,     unit: "g")
                    nutritionRow("Carbs",   value: carbs,   unit: "g")
                    nutritionRow("Protein", value: protein, unit: "g")
                    if let fiber {
                        nutritionRow("Fiber", value: fiber, unit: "g")
                    }
                }

                Text("Per 100 g")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    private func nutritionRow(_ label: String, value: Double?, unit: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if let value {
                Text(String(format: "%.1f %@", value, unit))
                    .fontWeight(.medium)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        async let offFetch    = fetchOFFProduct()
        async let edamamFetch = EdamamService.shared.fetchFood(for: ingredient)
        let (off, edam) = await (offFetch, edamamFetch)
        offProduct = off
        if off?.nutriments == nil {
            edamamResult = edam
        }
        isLoading = false
    }

    private func fetchOFFProduct() async -> OFFProduct? {
        await withCheckedContinuation { cont in
            FoodInfoService().fetchFoodInfo(for: ingredient) { result in
                cont.resume(returning: try? result.get())
            }
        }
    }
}
