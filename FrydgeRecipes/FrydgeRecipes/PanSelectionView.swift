//
//  PanSelectionView.swift
//  FrydgeRecipes
//
//  Created by Josh on 16/10/2024.
//


import SwiftUI
import CloudKit

// Extension for CloudPan to provide SF Symbol names
extension CloudPan {
    func symbolName() -> String {
        switch name.lowercased() {
        case "frying pan": return "frying.pan"
        case "saucepan": return "cup.and.saucer"
        case "baking tray": return "rectangle"
        case "wok": return "circle"
        case "grill pan": return "square"
        case "casserole dish": return "flame"
        default: return "circle"
        }
    }
}

struct PanSelectionView: View {
    @State private var searchQuery = ""
    @State private var predefinedPans: [CloudPan] = []
    @Binding var selectedPans: [CloudPan]
    @State private var isLoading = true

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            if isLoading {
                ProgressView("Loading Pans...")
                    .padding()
            } else {
                TextField("Search for a pan...", text: $searchQuery)
                    .padding()
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                List {
                    ForEach(predefinedPans.filter { $0.name.contains(searchQuery) || searchQuery.isEmpty }, id: \.id) { pan in
                        HStack {
                            Image(systemName: pan.symbolName()) // Display SF Symbol for each pan
                                .font(.title2)
                                .foregroundColor(.blue)

                            Text(pan.name)
                                .padding(.leading, 5)

                            Spacer()

                            Button(action: {
                                togglePanSelection(for: pan)
                            }) {
                                Image(systemName: selectedPans.contains(where: { $0.id == pan.id }) ? "checkmark.circle.fill" : "plus.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.title2)
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: loadPansFromCloudKit)
        .navigationTitle("Select Pans")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .foregroundStyle(.blue)
            }
        }
    }

    // Toggle the selection state for a pan
    private func togglePanSelection(for pan: CloudPan) {
        if let existingPan = selectedPans.first(where: { $0.id == pan.id }) {
            selectedPans.removeAll { $0.id == existingPan.id }
        } else {
            selectedPans.append(pan)
        }
    }

    // Load predefined pans from CloudKit
    private func loadPansFromCloudKit() {
        isLoading = true
        let query = CKQuery(recordType: "Pan", predicate: NSPredicate(value: true))
        let publicDatabase = CKContainer.default().publicCloudDatabase

        Task {
            do {
                let (records, _) = try await publicDatabase.records(matching: query)
                DispatchQueue.main.async {
                    self.predefinedPans = records.compactMap { _, result in
                        switch result {
                        case .success(let record):
                            return CloudPan(record: record)
                        case .failure(let error):
                            print("Error mapping record: \(error.localizedDescription)")
                            return nil
                        }
                    }
                    self.isLoading = false
                }
            } catch {
                print("Error fetching pans: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isLoading = false
                }
            }
        }
    }
}
