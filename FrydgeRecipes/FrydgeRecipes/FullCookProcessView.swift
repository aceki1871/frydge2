import SwiftUI
import CloudKit

struct FullCookProcessView: View {
    var recipe: CloudRecipe
    @State private var isCookModeActive = false

    var body: some View {
        VStack(spacing: 24) {
            Text(recipe.name)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                isCookModeActive = true
            } label: {
                Label("Start Cook Mode", systemImage: "flame.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.orange)
                    )
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .disabled(recipe.resolvedSteps.isEmpty)
        }
        .fullScreenCover(isPresented: $isCookModeActive) {
            CookAlongView(recipe: recipe)
        }
    }
}
