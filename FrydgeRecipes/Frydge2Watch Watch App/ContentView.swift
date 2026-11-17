import SwiftUI

struct ContentView: View {
    @ObservedObject var connectivity = WatchConnectivityManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Store / location
                VStack(spacing: 2) {
                    Image(systemName: "storefront")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    if let store = connectivity.storeName, !store.isEmpty {
                        Text(store)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        if let distance = connectivity.distanceText {
                            Text(distance)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No store nearby")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)

                Divider()

                // Item count
                HStack {
                    Image(systemName: "cart")
                    Text("\(connectivity.itemCount) item\(connectivity.itemCount == 1 ? "" : "s")")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))

                // Total cost
                HStack {
                    Image(systemName: "dollarsign.circle")
                    if let total = connectivity.totalCostText, !total.isEmpty {
                        Text(total)
                            .fontWeight(.semibold)
                    } else {
                        Text("No prices yet")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle("Frydge")
    }
}

#Preview {
    ContentView()
}
