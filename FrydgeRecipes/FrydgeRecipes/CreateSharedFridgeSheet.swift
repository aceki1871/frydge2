//
//  CreateSharedFridgeSheet.swift
//  FrydgeRecipes
//
//  Created by Josh on 28/11/2025.
//


//
//  CreateSharedFridgeSheet.swift
//  FrydgeRecipes
//
//  Created by Josh on 20/11/2025.
//

import SwiftUI

struct CreateSharedFridgeSheet: View {
    @Binding var name: String
    var onCreate: (String) -> Void
    var onCancel: () -> Void
    
    @FocusState private var isFocused: Bool
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.blue)
                        .padding(.top, 10)

                    Text("New Shared Frydge")
                        .font(.title2.weight(.semibold))

                    Text("Everyone you invite sees the same fridge and shopping list, updated live as items are added, used or ticked off.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                TextField("Enter fridge name", text: $name)
                    .padding()
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(10)
                    .focused($isFocused)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { isFocused = false }
                        }
                    }

                Text("You'll invite people on the next screen — by link, Messages or email.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: {
                    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    onCreate(name)
                }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.blue)
                            .frame(height: 52)
                        Text("Create")
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                }
                
                Button(role: .cancel) {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .foregroundColor(.red)
                }
                
                Spacer()
            }
            .padding()
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    isFocused = true
                }
            }
            .navigationTitle("Create Frydge")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}