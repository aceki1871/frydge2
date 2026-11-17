//
//  RecipeShareIcon.swift
//  FrydgeRecipes
//
//  Renders the rich share icon shown in Messages/share sheet previews:
//  recipe photo, title/meta, and Frydge branding.
//

import UIKit
import UniformTypeIdentifiers

enum RecipeShareIcon {

    /// Loads the best available recipe photo and composites the share icon.
    static func renderPrepared(
        recipe: CloudRecipe,
        hasAllIngredients: Bool
    ) async -> UIImage {
        var preparedRecipe = recipe
        if preparedRecipe.image == nil {
            preparedRecipe.image = await FrydgeRecipeShareService.resolvedRecipeImage(for: recipe)
        }

        let resolvedRecipe = preparedRecipe
        return await MainActor.run {
            render(recipe: resolvedRecipe, hasAllIngredients: hasAllIngredients)
        }
    }

    /// Composites the share icon. Square, ~512pt at @2x.
    static func render(
        recipe: CloudRecipe,
        hasAllIngredients: Bool
    ) -> UIImage {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { ctx in
            let bounds = CGRect(origin: .zero, size: size)

            // Background
            UIColor(red: 0.06, green: 0.08, blue: 0.07, alpha: 1.0).setFill()
            ctx.fill(bounds)

            // Top region: large food photo with a soft lower shade for contrast.
            let photoRect = CGRect(x: 0, y: 0, width: size.width, height: 294)
            if let photo = recipe.image {
                drawScaledToFill(image: photo, in: photoRect)
            } else {
                UIColor(red: 0.15, green: 0.19, blue: 0.16, alpha: 1.0).setFill()
                ctx.fill(photoRect)
                drawCentered(systemName: "fork.knife", color: .white, fontSize: 100, in: photoRect)
            }

            drawVerticalGradient(
                in: CGRect(x: 0, y: 190, width: size.width, height: 104),
                top: UIColor.black.withAlphaComponent(0.0),
                bottom: UIColor.black.withAlphaComponent(0.34)
            )

            let cardRect = CGRect(x: 18, y: 266, width: size.width - 36, height: 226)
            let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: 26)
            UIColor.white.withAlphaComponent(0.95).setFill()
            cardPath.fill()

            let pad: CGFloat = 26
            let contentX = cardRect.minX + pad
            let contentWidth = cardRect.width - pad * 2

            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .bold),
                .foregroundColor: UIColor(red: 0.09, green: 0.13, blue: 0.10, alpha: 1.0)
            ]
            let nameRect = CGRect(x: contentX, y: cardRect.minY + 24, width: contentWidth, height: 88)
            (recipe.name as NSString).draw(in: nameRect, withAttributes: nameAttrs)

            // Meta line: cook time + ingredients + green tick.
            let metaY = cardRect.minY + 122
            let metaAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 21, weight: .semibold),
                .foregroundColor: UIColor(red: 0.35, green: 0.42, blue: 0.36, alpha: 1.0)
            ]

            var metaX = contentX
            if let timeText = formattedCookTime(for: recipe) {
                drawCentered(systemName: "clock.fill", color: UIColor(red: 0.35, green: 0.42, blue: 0.36, alpha: 1.0),
                             fontSize: 19, in: CGRect(x: metaX, y: metaY + 4, width: 24, height: 24))
                metaX += 30
                (timeText as NSString).draw(at: CGPoint(x: metaX, y: metaY), withAttributes: metaAttrs)
                metaX += (timeText as NSString).size(withAttributes: metaAttrs).width + 20
            }

            let ingredientsText = "\(recipe.ingredients.count) ingredients"
            drawCentered(systemName: "list.bullet", color: UIColor(red: 0.35, green: 0.42, blue: 0.36, alpha: 1.0),
                         fontSize: 18, in: CGRect(x: metaX, y: metaY + 4, width: 24, height: 24))
            metaX += 30
            (ingredientsText as NSString).draw(at: CGPoint(x: metaX, y: metaY), withAttributes: metaAttrs)
            metaX += (ingredientsText as NSString).size(withAttributes: metaAttrs).width + 20

            if hasAllIngredients && metaX < cardRect.maxX - 48 {
                drawCentered(systemName: "checkmark.circle.fill",
                             color: UIColor.systemGreen,
                             fontSize: 23,
                             in: CGRect(x: metaX, y: metaY + 2, width: 28, height: 28))
            }

            drawBrandFooter(in: CGRect(x: contentX, y: cardRect.maxY - 56, width: contentWidth, height: 36))
        }
    }

    private static func drawBrandFooter(in rect: CGRect) {
        let iconRect = CGRect(x: rect.minX, y: rect.minY, width: 34, height: 34)
        let iconPath = UIBezierPath(roundedRect: iconRect, cornerRadius: 8)
        UIGraphicsGetCurrentContext()?.saveGState()
        iconPath.addClip()

        if let appIcon = UIImage(named: "AppIcon") ?? UIImage(named: "IMG_0210") {
            drawScaledToFill(image: appIcon, in: iconRect)
        } else {
            UIColor(red: 0.18, green: 0.48, blue: 0.28, alpha: 1.0).setFill()
            iconPath.fill()
            drawCentered(systemName: "leaf.fill", color: .white, fontSize: 18, in: iconRect)
        }
        UIGraphicsGetCurrentContext()?.restoreGState()

        let brandAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: UIColor(red: 0.10, green: 0.22, blue: 0.13, alpha: 1.0)
        ]
        ("frydge" as NSString).draw(
            at: CGPoint(x: iconRect.maxX + 10, y: rect.minY + 4),
            withAttributes: brandAttrs
        )

        let openAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 17, weight: .medium),
            .foregroundColor: UIColor(red: 0.42, green: 0.49, blue: 0.43, alpha: 1.0)
        ]
        let openText = "Open in app" as NSString
        let openSize = openText.size(withAttributes: openAttrs)
        openText.draw(
            at: CGPoint(x: rect.maxX - openSize.width, y: rect.minY + 7),
            withAttributes: openAttrs
        )
    }

    private static func drawVerticalGradient(in rect: CGRect, top: UIColor, bottom: UIColor) {
        guard let context = UIGraphicsGetCurrentContext(),
              let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [top.cgColor, bottom.cgColor] as CFArray,
                locations: [0, 1]
              ) else {
            return
        }

        context.saveGState()
        context.addRect(rect)
        context.clip()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX, y: rect.minY),
            end: CGPoint(x: rect.midX, y: rect.maxY),
            options: []
        )
        context.restoreGState()
    }

    /// True if every ingredient name appears in the local FrydgeManager inventory.
    /// Match is case-insensitive substring across the normalized inventory list.
    @MainActor
    static func localFridgeHasAllIngredients(for recipe: CloudRecipe) -> Bool {
        guard !recipe.ingredients.isEmpty else { return false }
        let inventory = FrydgeManager.shared.inventoryList // [String], lowercased
        return recipe.ingredients.allSatisfy { ing in
            let needle = ing.lowercased()
            return inventory.contains { hay in hay.contains(needle) || needle.contains(hay) }
        }
    }

    /// Universal link that opens the recipe in Frydge and gives Messages a web
    /// page to scrape for Open Graph preview metadata.
    static func deepLinkURL(for recipe: CloudRecipe) -> URL? {
        FrydgeRecipeShareService.shareURL(forRecipeID: recipe.id)
    }

    // MARK: - Private drawing helpers

    private static func drawScaledToFill(image: UIImage, in rect: CGRect) {
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }
        let scale = max(rect.width / imgSize.width, rect.height / imgSize.height)
        let drawSize = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)
        let drawOrigin = CGPoint(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2
        )
        UIGraphicsGetCurrentContext()?.saveGState()
        UIBezierPath(rect: rect).addClip()
        image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        UIGraphicsGetCurrentContext()?.restoreGState()
    }

    private static func drawCentered(systemName: String, color: UIColor, fontSize: CGFloat, in rect: CGRect) {
        let cfg = UIImage.SymbolConfiguration(pointSize: fontSize, weight: .semibold)
        guard let sym = UIImage(systemName: systemName, withConfiguration: cfg)?
                .withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        let s = sym.size
        let origin = CGPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2)
        sym.draw(at: origin)
    }

    private static func formattedCookTime(for recipe: CloudRecipe) -> String? {
        let total = recipe.steps.compactMap { $0.timerSeconds }.reduce(0, +)
        guard total > 0 else { return nil }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 && minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }
}
