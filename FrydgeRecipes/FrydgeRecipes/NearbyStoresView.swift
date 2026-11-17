//
//  NearbyStoresView.swift
//  FrydgeRecipes
//
//  Created by Josh on 08/11/2024.
//


// NearbyStoresView.swift
import SwiftUI
import MapKit

struct NearbyStoresView: View {
    let stores: [Store]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(stores) { store in
                VStack(alignment: .leading) {
                    Text(store.name)
                        .font(.headline)
                    Text(store.vicinity)
                        .font(.subheadline)
                    Text("Hours: \(store.storehours)")
                        .font(.subheadline)
                    Text("Phone: \(store.phoneNumber ?? "Not available")")
                        .font(.subheadline)
                    if let websiteURL = URL(string: store.website) {
                        Link("Website", destination: websiteURL)
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    }
                }
                .padding(.vertical, 5)
            }
            .navigationTitle("Nearby Stores")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
