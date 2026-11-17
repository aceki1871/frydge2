import SwiftUI

/// A short paged walkthrough of the app's main tabs and how to scan items in.
/// Shown automatically the first time the user reaches the main app (gated by
/// the "hasSeenTutorial" flag in ContentView) and replayable from
/// Profile → Show Tutorial.
struct TutorialView: View {
    /// Called when the user finishes or skips the tutorial.
    let onFinish: () -> Void

    @State private var currentPage = 0
    @ObservedObject private var marketplace = MarketplaceAvailability.shared

    /// Core pages plus the marketplace page, which only appears once the
    /// marketplace launch gate is open (see MarketplaceAvailability).
    private var pages: [TutorialPage] {
        var all = corePages
        if marketplace.isEnabled {
            all.append(
                TutorialPage(
                    systemImage: "storefront.fill",
                    tint: .purple,
                    title: "Local Marketplace",
                    message: "Buy and sell extra produce with people nearby, with secure payments built in."
                )
            )
        }
        return all
    }

    private let corePages: [TutorialPage] = [
        TutorialPage(
            systemImage: "refrigerator.fill",
            tint: .blue,
            title: "Welcome to Frydge",
            message: "Frydge keeps track of what's in your fridge so you always know what you have — and what to cook with it."
        ),
        TutorialPage(
            systemImage: "exclamationmark.shield.fill",
            tint: .red,
            title: "Tell Frydge What You Can't Eat",
            message: "Allergies, intolerances or just things you'd rather avoid — be as specific as you like:",
            steps: [
                TutorialStep(icon: "person.crop.circle", text: "Profile → Dietary → Can't & won't eat"),
                TutorialStep(icon: "plus.circle.fill", text: "Add a food, a family like “cheese”, an additive like E621, or a phrase like “palm oil”"),
                TutorialStep(icon: "exclamationmark.triangle.fill", text: "Frydge flags a match whenever you scan a product or add it to your fridge or shopping list")
            ]
        ),
        TutorialPage(
            systemImage: "camera.fill",
            tint: .teal,
            title: "Scan Your Shopping In",
            message: "Tap + at the top of the Frydge tab, then choose a shortcut:",
            steps: [
                TutorialStep(icon: "doc.text.viewfinder", text: "Scan Receipt adds your whole shop in one go"),
                TutorialStep(icon: "list.bullet.rectangle", text: "Scan a List reads a handwritten or printed list"),
                TutorialStep(icon: "refrigerator", text: "Scan Fridge photographs what's already inside and adds it all at once")
            ]
        ),
        TutorialPage(
            systemImage: "barcode.viewfinder",
            tint: .indigo,
            title: "Scan a Barcode",
            message: "Adding a single product? Scan its barcode:",
            steps: [
                TutorialStep(icon: "plus.circle.fill", text: "Tap + at the top of the Frydge tab"),
                TutorialStep(icon: "barcode.viewfinder", text: "Point the scanner at the product's barcode"),
                TutorialStep(icon: "checkmark.circle", text: "The name and details fill in automatically")
            ]
        ),
        TutorialPage(
            systemImage: "book.fill",
            tint: .orange,
            title: "Cook From What You Have",
            message: "Browse recipes matched to your fridge. Cook Mode walks you through each step and updates your fridge when you're done."
        ),
        TutorialPage(
            systemImage: "person.2.fill",
            tint: .pink,
            title: "Share With Your Household",
            message: "A shared frydge keeps everyone on the same page, live:",
            steps: [
                TutorialStep(icon: "person.2.fill", text: "Open Shared Frydges and tap + to create one"),
                TutorialStep(icon: "square.and.arrow.up", text: "Invite people by link, Messages or email"),
                TutorialStep(icon: "arrow.triangle.2.circlepath", text: "Everyone sees the same items update as they're added or used")
            ]
        ),
        TutorialPage(
            systemImage: "cart.fill",
            tint: .green,
            title: "Smarter Shopping",
            message: "Build shopping lists and share them with your household. The camera button works here too — scan a receipt or a written list."
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { onFinish() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
            }

            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    TutorialPageView(page: page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if currentPage < pages.count - 1 {
                    withAnimation { currentPage += 1 }
                } else {
                    onFinish()
                }
            } label: {
                Text(currentPage < pages.count - 1 ? "Next" : "Get Started")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.blue)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

private struct TutorialPage {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String
    var steps: [TutorialStep] = []
}

private struct TutorialStep: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
}

private struct TutorialPageView: View {
    let page: TutorialPage

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(page.tint.opacity(0.15))
                    .frame(width: 120, height: 120)
                Image(systemName: page.systemImage)
                    .font(.system(size: 48))
                    .foregroundStyle(page.tint)
            }

            Text(page.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)

            Text(page.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            if !page.steps.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(page.steps) { step in
                        HStack(spacing: 14) {
                            Image(systemName: step.icon)
                                .font(.title3)
                                .foregroundStyle(page.tint)
                                .frame(width: 34, height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(page.tint.opacity(0.12))
                                )
                            Text(step.text)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .padding(.horizontal, 28)
            }

            Spacer()
            Spacer()
        }
    }
}

#Preview {
    TutorialView(onFinish: {})
}
