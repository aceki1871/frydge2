import SwiftUI

struct InstructionsDetailView: View {
    var recipe: CloudRecipe

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Updated title text with precise alignment and position adjustments
            HStack {
                Text("Instructions")
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.leading, 8) // Move text closer to the left side
                Spacer() // Ensure the title stays on the left
            }
            .padding(.top, -10) // Reduce top padding to move it closer to the section buttons

            // Instructions content, aligned left with reduced padding
            Text(recipe.instructions)
                .padding(.leading, 8) // Align text to the left
                .padding(.top, 5)

            RecipeAuthorFooter(authorName: recipe.authorName, creationDate: recipe.creationDate)
        }
        .padding(.horizontal, 10) // Reduced horizontal padding for a tighter fit
        .navigationBarTitleDisplayMode(.inline) // Inline navigation title
    }
}
