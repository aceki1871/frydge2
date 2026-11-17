//
//  RecipeShareView.swift
//  FrydgeRecipes
//
//  Native recipe sharing used everywhere a recipe appears (detail toolbar,
//  list action tray). A `RecipeShareMenu` offers the rich link, plain text,
//  the rendered recipe card, and copy-link, all through SwiftUI `ShareLink`
//  so Messages/Mail/AirDrop get the right representation and the sheet is
//  presented by the system rather than wrapped in our own sheet.
//
//  The link is published to frydge2.com in the background the moment the menu
//  appears (only when the recipe changed since last time), so tapping Share
//  is instant and the recipient's preview + full recipe are ready.
//

import SwiftUI
import UIKit

// MARK: - Publisher

/// Per-recipe share state: the rendered card and whether the public link has
/// been (re)published for the current content.
@MainActor
final class RecipeSharePublisher: ObservableObject {
    @Published private(set) var cardImage: UIImage?
    @Published private(set) var isPublishing = false
    @Published private(set) var lastError: String?

    private var preparedFingerprint: String?
    private var task: Task<Void, Never>?

    func prepare(for recipe: CloudRecipe, force: Bool = false) {
        let fingerprint = recipe.shareFingerprint
        guard force || fingerprint != preparedFingerprint || cardImage == nil else { return }
        preparedFingerprint = fingerprint
        task?.cancel()

        task = Task { [weak self] in
            guard let self else { return }
            isPublishing = true
            defer { isPublishing = false }

            let hasAll = RecipeShareIcon.localFridgeHasAllIngredients(for: recipe)
            let image = await RecipeShareIcon.renderPrepared(recipe: recipe, hasAllIngredients: hasAll)
            guard !Task.isCancelled else { return }
            cardImage = image

            do {
                try await FrydgeRecipeShareService.shared.publishIfNeeded(
                    recipe: recipe,
                    cardImage: image,
                    fingerprint: fingerprint
                )
                lastError = nil
            } catch {
                // The universal link still works for anyone who has the app
                // and the recipe; only the preview/payload is degraded.
                lastError = error.localizedDescription
                print("[SHARE] Background publish failed for \(recipe.id): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Menu

/// Share menu for one recipe. Use `.toolbar` style in navigation bars and
/// `.tray` style inside the recipe list's long-press action bar.
struct RecipeShareMenu: View {
    enum Style {
        case toolbar
        case tray
    }

    let recipe: CloudRecipe
    var style: Style = .toolbar

    @StateObject private var publisher = RecipeSharePublisher()
    @EnvironmentObject private var appState: AppState

    private var shareURL: URL { recipe.publicRecipeShareURL }

    private var preview: SharePreview<Image, Never> {
        if let card = publisher.cardImage {
            return SharePreview(recipe.name, image: Image(uiImage: card))
        }
        if let photo = recipe.image {
            return SharePreview(recipe.name, image: Image(uiImage: photo))
        }
        return SharePreview(recipe.name, image: Image(systemName: "fork.knife.circle.fill"))
    }

    var body: some View {
        Menu {
            ShareLink(
                item: shareURL,
                subject: Text(recipe.name),
                message: Text(RecipeShareText.summary(for: recipe)),
                preview: preview
            ) {
                Label("Share Link", systemImage: "link")
            }

            ShareLink(
                item: RecipeShareText.fullText(for: recipe),
                subject: Text(recipe.name),
                preview: preview
            ) {
                Label("Share as Text", systemImage: "text.alignleft")
            }

            if let card = publisher.cardImage {
                ShareLink(
                    item: Image(uiImage: card),
                    subject: Text(recipe.name),
                    message: Text(RecipeShareText.summary(for: recipe)),
                    preview: SharePreview(recipe.name, image: Image(uiImage: card))
                ) {
                    Label("Share Recipe Card", systemImage: "photo")
                }
            }

            Divider()

            Button {
                UIPasteboard.general.url = shareURL
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                appState.showBanner(
                    title: "Link copied",
                    message: recipe.name,
                    systemImage: "doc.on.clipboard",
                    style: .success,
                    duration: 2
                )
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }

            if publisher.lastError != nil {
                Button {
                    publisher.prepare(for: recipe, force: true)
                } label: {
                    Label("Retry Preview Upload", systemImage: "arrow.clockwise")
                }
            }
        } label: {
            label
        }
        .accessibilityLabel("Share recipe")
        .task(id: recipe.shareFingerprint) {
            publisher.prepare(for: recipe)
        }
    }

    @ViewBuilder
    private var label: some View {
        switch style {
        case .toolbar:
            // Circular Liquid Glass button; the host hides the bar's shared
            // glass grouping so this is the only glass behind the icon.
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
                .overlay(alignment: .topTrailing) {
                    if publisher.isPublishing {
                        ProgressView()
                            .controlSize(.mini)
                            .offset(x: 2, y: -2)
                    }
                }
        case .tray:
            VStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background { Circle().fill(Color.blue.opacity(0.85)) }
                    .glassEffect(.regular.interactive(), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                Text("Share")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Text representation

enum RecipeShareText {
    /// One-liner that accompanies the link in Messages / Mail.
    static func summary(for recipe: CloudRecipe) -> String {
        var bits: [String] = []
        if let time = FrydgeRecipeShareService.formattedCookTime(for: recipe) { bits.append(time) }
        bits.append("\(recipe.ingredients.count) ingredients")
        let serves = recipe.serves.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serves.isEmpty { bits.append("serves \(serves)") }
        return "\(recipe.name) · " + bits.joined(separator: " · ")
    }

    /// Full recipe as plain text for Notes, Mail, or apps without link previews.
    static func fullText(for recipe: CloudRecipe) -> String {
        var lines: [String] = []
        lines.append(recipe.name)
        var meta: [String] = []
        let serves = recipe.serves.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serves.isEmpty { meta.append("Serves \(serves)") }
        if let time = FrydgeRecipeShareService.formattedCookTime(for: recipe) { meta.append(time) }
        if !recipe.dietaryTags.isEmpty { meta.append(recipe.dietaryTags.joined(separator: ", ")) }
        if !meta.isEmpty { lines.append(meta.joined(separator: " · ")) }
        if let author = recipe.authorName?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            lines.append("By \(author)")
        }

        if !recipe.ingredients.isEmpty {
            lines.append("")
            lines.append("Ingredients")
            for ingredient in recipe.ingredients {
                lines.append("• \(ingredient)")
            }
        }

        let steps = recipe.resolvedSteps
        if !steps.isEmpty {
            lines.append("")
            lines.append("Method")
            for (index, step) in steps.enumerated() {
                var text = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
                var extras: [String] = []
                if let timer = step.timerDisplay { extras.append(timer) }
                if let temp = step.temperatureDisplay { extras.append(temp) }
                if !extras.isEmpty { text += " (\(extras.joined(separator: ", ")))" }
                lines.append("\(index + 1). \(text)")
            }
        } else if !recipe.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append("Method")
            lines.append(recipe.instructions)
        }

        lines.append("")
        lines.append("Open in Frydge: \(recipe.publicRecipeShareURL.absoluteString)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        Text("Recipe")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    RecipeShareMenu(
                        recipe: CloudRecipe(
                            name: "Chocolate Chip Cookies",
                            serves: "24 cookies",
                            ingredients: ["2¼ cups flour", "1 tsp baking soda", "2 cups chocolate chips"],
                            pan: "Baking sheets",
                            steps: [
                                RecipeStep(text: "Preheat oven to 190°C", timerSeconds: 600),
                                RecipeStep(text: "Bake for 10-12 minutes", timerSeconds: 660)
                            ],
                            dietaryTags: ["Vegetarian"]
                        )
                    )
                }
            }
    }
    .environmentObject(AppState())
}
