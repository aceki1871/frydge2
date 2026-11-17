import SwiftUI
import MapKit

struct GoLocalView: View {
    @ObservedObject var marketplaceManager: P2PMarketplaceManager

    @StateObject private var locationManager = LocationManager()
    @State private var selectedStore: Store?
    @State private var previewStore: Store?
    @State private var previewListing: P2PListing?
    @State private var detailListing: P2PListing?
    @State private var hasCenteredOnUserLocation = false
    // Default to Auckland — renders map tiles immediately while location permission is pending
    @State private var mapPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -36.852, longitude: 174.763),
            span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
        )
    )

    enum DisplayMode: String, CaseIterable, Identifiable {
        case map = "Map"
        case list = "List"

        var id: String { rawValue }
    }

    private var sortedStores: [Store] {
        guard let userLocation = locationManager.location else {
            return locationManager.stores.sorted { $0.name < $1.name }
        }

        return locationManager.stores.sorted {
            let lhsDistance = distance(from: userLocation, to: $0)
            let rhsDistance = distance(from: userLocation, to: $1)
            return lhsDistance < rhsDistance
        }
    }

    var body: some View {
        mapContent
            .ignoresSafeArea()
            .onAppear {
                locationManager.startUpdatingLocation()
                centerMapOnceOnUserLocation()
            }
            .onChange(of: locationManager.location) { _, _ in
                centerMapOnceOnUserLocation()
            }
            .sheet(item: $selectedStore) { store in
                NavigationStack {
                    StoreLocalBrowseView(store: store)
                }
            }
            // Listing preview — compact bottom sheet, dismissible with a swipe.
            // Replaces the old ZStack overlay which rendered behind the tab bar.
            .sheet(item: $previewListing) { listing in
                ListingMapCard(listing: listing, onViewDetails: {
                    let captured = listing
                    previewListing = nil
                    Task {
                        // Let the preview sheet finish dismissing before presenting detail
                        try? await Task.sleep(for: .milliseconds(350))
                        detailListing = captured
                    }
                })
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)
                .presentationDetents([.height(160)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
                .presentationBackgroundInteraction(.enabled(upThrough: .height(160)))
            }
            .sheet(item: $detailListing) { listing in
                P2PListingDetailView(listing: listing, marketplaceManager: marketplaceManager)
            }
    }

    private var mapContent: some View {
        ZStack {
            Map(position: $mapPosition, interactionModes: [.all]) {
                if let userCoordinate = locationManager.location?.coordinate {
                    Annotation("You", coordinate: userCoordinate) {
                        UserLocationAnnotation(coordinate: userCoordinate)
                    }
                }

                ForEach(sortedStores) { store in
                    Annotation(store.name, coordinate: CLLocationCoordinate2D(latitude: store.latitude, longitude: store.longitude)) {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                                previewListing = nil
                                previewStore = store
                            }
                        } label: {
                            storePin(for: store)
                                .frame(width: 30, height: 30)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                                .shadow(radius: 6)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Only items still for sale earn a pin — a map of sold goods helps nobody.
                ForEach(marketplaceManager.listings.filter { $0.location != nil && $0.isAvailable }) { listing in
                    Annotation(listing.title, coordinate: listing.location!) {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                                previewStore = nil
                                previewListing = listing
                            }
                        } label: {
                            VStack(spacing: 3) {
                                if let img = UIImage.frydgeBounded(data: listing.imageData, maxPixelSize: ImageBudget.thumbnail) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(.white, lineWidth: 1.5)
                                        )
                                        .shadow(radius: 4)
                                } else {
                                    Image(systemName: "tag.fill")
                                        .foregroundStyle(.white)
                                        .frame(width: 32, height: 32)
                                        .background(.orange, in: Circle())
                                        .shadow(radius: 4)
                                }
                                Text(listing.formattedPrice)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.orange, in: Capsule())
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    previewStore = nil
                    previewListing = nil
                }
            }

            VStack {
                HStack {
                    Spacer()

                    Button(action: recenterOnUserLocation) {
                        Image(systemName: "location.north.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                            .shadow(radius: 10)
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 80)
                }

                Spacer()
            }

            if let previewStore {
                // Using contentShape instead of ignoresSafeArea so the tap target
                // stays within the ZStack's frame and can't trigger a Metal
                // drawable resize by requesting a larger layout size.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            self.previewStore = nil
                        }
                    }

                VStack {
                    Spacer()

                    Button {
                        selectedStore = previewStore
                    } label: {
                        StoreView(store: previewStore)
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(2)
            }

        }
    }


    @ViewBuilder
    private func storePin(for store: Store) -> some View {
        let storeName = store.name.lowercased()

        if storeName.contains("pak") {
            Image("paknsave").resizable().scaledToFill().clipShape(Circle())
        } else if storeName.contains("countdown") || storeName.contains("woolworth") {
            Image("countdown").resizable().scaledToFill().clipShape(Circle())
        } else if storeName.contains("unichem") {
            Image("unichem").resizable().scaledToFill().clipShape(Circle())
        } else if storeName.contains("tesco") {
            Image("tesco").resizable().scaledToFill().clipShape(Circle())
        } else if storeName.contains("sainsburys") {
            Image("sainsburys").resizable().scaledToFill().clipShape(Circle())
        } else if storeName.contains("new world") {
            Image("newworld").resizable().scaledToFill().clipShape(Circle())
        } else if storeName.contains("chemist warehouse") {
            Image("chemistwarehouse").resizable().scaledToFill().clipShape(Circle())
        } else if storeName.contains("morrison") {
            Image("morrisons").resizable().scaledToFill().clipShape(Circle())
        } else if storeName.contains("pharmacy") {
            Image("lloydspharmacy").resizable().scaledToFill().clipShape(Circle())
        } else if storeName.contains("four square") {
            Image("foursquare").resizable().scaledToFill().clipShape(Circle())
        } else if storeName.contains("co-op") || storeName.contains("coop") {
            Image("coop").resizable().scaledToFill().clipShape(Circle())
        } else if storeName.contains("boots") {
            Image("boots").resizable().scaledToFill().clipShape(Circle())
        } else if storeName.contains("tank") {
            Image("dad").resizable().scaledToFill().clipShape(Circle())
        } else if storeName.contains("aldi") {
            Image("aldi").resizable().scaledToFill().clipShape(Circle())
        } else if storeName.contains("waitrose") {
            Image("waitrose").resizable().scaledToFill().clipShape(Circle())
        } else if storeName.contains("mands") || storeName.contains("marks") {
            Image("mands").resizable().scaledToFill().clipShape(Circle())
        } else if storeName.contains("clarkcake") {
            Image("clarkcakes").resizable().scaledToFill().clipShape(Circle())
        } else if storeName.contains("asda") {
            Image("asda").resizable().scaledToFill().clipShape(Circle())
        } else {
            Image(systemName: "mappin.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.blue)
        }
    }

    private func recenterOnUserLocation() {
        previewStore = nil
        hasCenteredOnUserLocation = false
        centerMapOnceOnUserLocation()
    }

    private func centerMapOnceOnUserLocation() {
        guard let userLocation = locationManager.location, !hasCenteredOnUserLocation else { return }
        mapPosition = .region(
            MKCoordinateRegion(
                center: userLocation.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            )
        )
        locationManager.setRegion(to: userLocation.coordinate)
        hasCenteredOnUserLocation = true
    }

    private func distance(from userLocation: CLLocation, to store: Store) -> CLLocationDistance {
        let storeLocation = CLLocation(latitude: store.latitude, longitude: store.longitude)
        return userLocation.distance(from: storeLocation)
    }

    private func distanceText(for store: Store) -> String {
        guard let userLocation = locationManager.location else { return "--" }
        let meters = distance(from: userLocation, to: store)
        if meters < 1000 {
            return "\(Int(meters.rounded()))m"
        }
        return String(format: "%.1fkm", meters / 1000)
    }
}

// MARK: - Listing Map Preview Card

private struct ListingMapCard: View {
    let listing: P2PListing
    let onViewDetails: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let uiImage = UIImage.frydgeBounded(data: listing.imageData, maxPixelSize: ImageBudget.thumbnail) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: "tag.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(listing.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: "person.circle.fill")
                        .font(.caption2)
                    Text(listing.sellerName)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)

                if let w3w = listing.what3WordsLocation, !w3w.isEmpty {
                    Text("///\(w3w)")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Text(listing.formattedPrice)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.orange)

                Button(action: onViewDetails) {
                    Text("Details")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.orange, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.orange.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
    }
}

// MARK: - Store Browse

struct StoreLocalBrowseView: View {
    let store: Store

    @EnvironmentObject private var shoppingListManager: ShoppingListManager
    @EnvironmentObject private var frydgeManager: FrydgeManager
    @StateObject private var paymentHandler = ApplePaymentHandler()

    @State private var searchText = ""
    @State private var showingScanner = false
    @State private var scannedBarcode = ""
    @State private var scannedProductDetails: ProductProtocol?
    @State private var statusMessage: String?
    @State private var latestDeals: [StockAvailability.StoreOffer] = []
    @State private var loadingLatestDeals = false
    @State private var paymentErrorMessage: String?
    @State private var showPaymentSuccess = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.name)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text(store.vicinity)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)

                latestDealsSection

                VStack(alignment: .leading, spacing: 10) {
                    Text("Search products")
                        .font(.headline)

                    TextField("Search by item name", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 10) {
                        Button {
                            addSearchTextToShoppingList()
                        } label: {
                            Label("Add to Shopping List", systemImage: "cart.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button {
                            addSearchTextToFridge()
                        } label: {
                            Label("Add to Fridge", systemImage: "refrigerator")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                        )
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("Scan barcode")
                        .font(.headline)

                    Button {
                        showingScanner = true
                    } label: {
                        Label("Open Barcode Scanner", systemImage: "barcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                        )
                )

                if let statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 4)
                }

                Spacer(minLength: 0)
            }
            .padding()
        }
        .navigationTitle(store.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadLatestDeals()
        }
        .sheet(isPresented: $showingScanner, onDismiss: handleScannedBarcodeResult) {
            BarcodeScannerView(
                isShowing: $showingScanner,
                scannedBarcode: $scannedBarcode,
                productDetails: $scannedProductDetails
            )
        }
        .alert("Payment Successful", isPresented: $showPaymentSuccess) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your payment was completed.")
        }
        .alert("Payment Error", isPresented: Binding(
            get: { paymentErrorMessage != nil },
            set: { if !$0 { paymentErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { paymentErrorMessage = nil }
        } message: {
            Text(paymentErrorMessage ?? "Please try again.")
        }
    }

    private var latestDealsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Latest deal products")
                    .font(.headline)
                Spacer()
                if loadingLatestDeals {
                    ProgressView()
                        .scaleEffect(0.85)
                }
            }

            if latestDeals.isEmpty {
                Text(loadingLatestDeals ? "Checking nearby deals..." : "No latest deals found for this store yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(latestDeals.prefix(6).enumerated()), id: \.offset) { _, offer in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text((offer.productTitle?.isEmpty == false ? offer.productTitle! : "Deal product"))
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                if let promo = offer.promoText, !promo.isEmpty {
                                    Text(promo)
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                        .lineLimit(1)
                                } else if let price = offer.price {
                                    Text(currencyText(for: price, code: offer.currencyCode))
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                        .lineLimit(1)
                                }
                            }

                            Button {
                                addOfferToShoppingList(offer)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)

                            if offer.price != nil {
                                Button {
                                    payForOffer(offer)
                                } label: {
                                    Image(systemName: "apple.logo")
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                        .frame(width: 34, height: 30)
                                        .background(Color.black, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(!paymentHandler.canMakePayments)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private func loadLatestDeals() async {
        await MainActor.run {
            loadingLatestDeals = true
            latestDeals = []
        }

        let storeQueries = ["milk", "bread", "cheese", "eggs", "chicken", "coke", "butter", "yoghurt"]
        let normalizedSelectedStore = normalizedStoreName(store.name)

        var collected: [StockAvailability.StoreOffer] = []

        await withTaskGroup(of: [StockAvailability.StoreOffer].self) { group in
            for query in storeQueries {
                group.addTask {
                    await StockAvailability.fetchOffers(for: query)
                }
            }

            for await offers in group {
                let matching = offers.filter { offer in
                    normalizedStoreName(offer.store) == normalizedSelectedStore
                }
                collected.append(contentsOf: matching)
            }
        }

        var seen = Set<String>()
        let deduped = collected.filter { offer in
            let key = [offer.store, offer.productTitle ?? "", offer.productURL.absoluteString].joined(separator: "|")
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        let sorted = deduped.sorted { lhs, rhs in
            let lhsPromo = (lhs.promoText?.isEmpty == false) ? 1 : 0
            let rhsPromo = (rhs.promoText?.isEmpty == false) ? 1 : 0
            if lhsPromo != rhsPromo { return lhsPromo > rhsPromo }

            switch (lhs.price, rhs.price) {
            case let (l?, r?) where l != r:
                return l < r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return (lhs.productTitle ?? "") < (rhs.productTitle ?? "")
            }
        }

        await MainActor.run {
            latestDeals = sorted
            loadingLatestDeals = false
        }
    }

    private func addOfferToShoppingList(_ offer: StockAvailability.StoreOffer) {
        let name = offer.productTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (name?.isEmpty == false ? name! : store.name)
        shoppingListManager.addToShoppingList(name: resolvedName, quantity: "1", unit: "", location: store.name, dietaryTags: [])
        statusMessage = "Deal item added to shopping list"
    }

    private func payForOffer(_ offer: StockAvailability.StoreOffer) {
        guard let price = offer.price else { return }

        let name = offer.productTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let product = VendorProduct(
            name: name?.isEmpty == false ? name! : "Deal product",
            description: offer.detailsText ?? store.vicinity,
            price: Decimal(price),
            currency: offer.currencyCode,
            vendorID: store.id.uuidString,
            vendorName: store.name,
            imageURL: offer.imageURL,
            category: .other,
            isAvailable: true
        )

        paymentHandler.startPayment(for: product, quantity: 1) { success in
            if success {
                showPaymentSuccess = true
            } else {
                paymentErrorMessage = paymentHandler.errorMessage ?? "Apple Pay could not complete this payment."
            }
        }
    }

    private func normalizedStoreName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currencyText(for value: Double, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code.isEmpty ? (Locale.current.currency?.identifier ?? "NZD") : code
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = value.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func addSearchTextToShoppingList() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        shoppingListManager.addToShoppingList(name: trimmed, quantity: "1", unit: "", location: store.name, dietaryTags: [])
        statusMessage = "Added to shopping list"
        searchText = ""
    }

    private func addSearchTextToFridge() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        frydgeManager.addToInventory(trimmed)
        statusMessage = "Added to fridge"
        searchText = ""
    }

    private func handleScannedBarcodeResult() {
        guard let resolvedName = scannedProductDetails?.productName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !resolvedName.isEmpty else {
            scannedBarcode = ""
            scannedProductDetails = nil
            statusMessage = "Product not identified — search by name to add it"
            return
        }

        shoppingListManager.addToShoppingList(
            name: resolvedName,
            quantity: "1",
            unit: "",
            location: store.name,
            dietaryTags: []
        )
        statusMessage = "Added \(resolvedName) to shopping list"
        scannedBarcode = ""
        scannedProductDetails = nil
    }
}
