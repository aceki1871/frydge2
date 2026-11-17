import SwiftUI

struct HomeView: View {
    @EnvironmentObject var appState: AppState

    @State private var showScanner = false
    @State private var scannedBarcode = ""
    @State private var scannedProductDetails: (any ProductProtocol)? = nil
    @State private var selection: Int = 0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Tab(_:systemImage:value:) is the iOS 18+ replacement for .tabItem/.tag.
            TabView(selection: $selection) {
                Tab("Recipes", systemImage: "book", value: 0) {
                    RecipeListView()
                }

                Tab("Shopping List", systemImage: "list.bullet", value: 1) {
                    ShoppingListView()
                }

                Tab("Fridge", systemImage: "lightswitch.on", value: 2) {
                    FrydgeView()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openScanner)) { _ in
                showScanner = true
            }
            .fullScreenCover(isPresented: $showScanner) {
                BarcodeScannerView(
                    isShowing: $showScanner,
                    scannedBarcode: $scannedBarcode,
                    productDetails: $scannedProductDetails,
                    onNutritionScanned: { _ in },
                    onFrontLabelDetected: { _ in }
                )
            }

            // Floating "+" only on the Recipes tab — opens the structured creation flow.
            if selection == 0 {
                Button {
                    appState.showCreateRecipe = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.accentColor))
                        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 80) // sit above the TabView bar
                .accessibilityLabel("Create new recipe")
            }
        }
    }
}
