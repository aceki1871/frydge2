//
//  StoreBrand.swift
//  listwidget
//
//  Maps a store name ("Pak’nSave Sylvia Park", "Countdown Glenfield") to the
//  chain's logo asset, short display name and brand colour so every widget
//  family can show a consistent store symbol.
//

import SwiftUI
import UIKit

struct StoreBrand: Equatable {
    let assetName: String?
    let displayName: String
    let tint: Color

    static let unknown = StoreBrand(assetName: nil, displayName: "Nearest store", tint: .secondary)

    /// Resolves a brand from any store string. Falls back to the raw name with
    /// a neutral colour when the chain is not one we have a logo for.
    static func resolve(_ storeName: String?) -> StoreBrand {
        let raw = (storeName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .unknown }

        let normalized = raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[’'`]", with: "", options: .regularExpression)
            .lowercased()

        if normalized.contains("paknsave") || normalized.contains("pak n save") || normalized.hasPrefix("pak") {
            return StoreBrand(assetName: "paknsave", displayName: "Pak'nSave", tint: Color(red: 0.98, green: 0.80, blue: 0.05))
        }
        if normalized.contains("new world") || normalized.contains("newworld") {
            return StoreBrand(assetName: "newworld", displayName: "New World", tint: Color(red: 0.85, green: 0.12, blue: 0.14))
        }
        if normalized.contains("countdown") {
            return StoreBrand(assetName: "countdown", displayName: "Countdown", tint: Color(red: 0.00, green: 0.55, blue: 0.27))
        }
        if normalized.contains("woolworth") || normalized.hasPrefix("metro ") {
            return StoreBrand(assetName: "woolworths", displayName: "Woolworths", tint: Color(red: 0.00, green: 0.55, blue: 0.27))
        }
        if normalized.contains("four square") || normalized.contains("foursquare") {
            return StoreBrand(assetName: "foursquare", displayName: "Four Square", tint: Color(red: 0.00, green: 0.47, blue: 0.70))
        }
        if normalized.contains("chemist warehouse") {
            return StoreBrand(assetName: "chemistwarehouse", displayName: "Chemist Warehouse", tint: Color(red: 0.93, green: 0.73, blue: 0.10))
        }
        if normalized.contains("tesco") {
            return StoreBrand(assetName: "tesco", displayName: "Tesco", tint: Color(red: 0.00, green: 0.33, blue: 0.62))
        }
        if normalized.contains("sainsbury") {
            return StoreBrand(assetName: "sainsburys", displayName: "Sainsbury's", tint: Color(red: 0.94, green: 0.45, blue: 0.08))
        }
        if normalized.contains("waitrose") {
            return StoreBrand(assetName: "waitrose", displayName: "Waitrose", tint: Color(red: 0.36, green: 0.60, blue: 0.20))
        }
        if normalized.contains("asda") {
            return StoreBrand(assetName: "asda", displayName: "Asda", tint: Color(red: 0.47, green: 0.72, blue: 0.14))
        }
        if normalized.contains("aldi") {
            return StoreBrand(assetName: "aldi", displayName: "Aldi", tint: Color(red: 0.00, green: 0.20, blue: 0.55))
        }
        if normalized.contains("boots") {
            return StoreBrand(assetName: "boots", displayName: "Boots", tint: Color(red: 0.02, green: 0.20, blue: 0.50))
        }
        if normalized.contains("co-op") || normalized.contains("coop") {
            return StoreBrand(assetName: "coop", displayName: "Co-op", tint: Color(red: 0.00, green: 0.63, blue: 0.84))
        }
        if normalized.contains("morrisons") {
            return StoreBrand(assetName: "morrisons", displayName: "Morrisons", tint: Color(red: 0.00, green: 0.42, blue: 0.24))
        }

        return StoreBrand(assetName: nil, displayName: raw, tint: .secondary)
    }

    /// Short branch suffix ("Sylvia Park") when the store name carries one.
    static func branch(from storeName: String?) -> String? {
        guard let storeName else { return nil }
        let brand = resolve(storeName)
        guard brand.assetName != nil else { return nil }
        let cleaned = storeName
            .replacingOccurrences(of: "[’'`]", with: "", options: .regularExpression)
        // Drop the chain word(s) from the front and return what's left.
        let chainWords: Set<String> = Set(
            brand.displayName
                .replacingOccurrences(of: "[’'`]", with: "", options: .regularExpression)
                .lowercased()
                .split(separator: " ")
                .map(String.init)
        )
        var words = cleaned.split(separator: " ").map(String.init)
        while let first = words.first, chainWords.contains(first.lowercased()) || first.lowercased().hasPrefix("pak") {
            words.removeFirst()
        }
        let rest = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }
}

/// Circular store badge: chain logo when we have one, a building glyph otherwise.
struct StoreLogoView: View {
    let storeName: String?
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    private var brand: StoreBrand { StoreBrand.resolve(storeName) }

    var body: some View {
        if let asset = brand.assetName, let image = UIImage(named: asset) {
            // The artwork is drawn for a white ground, so this disc stays
            // white in both appearances.
            ZStack {
                Circle().fill(.white)
                Circle().strokeBorder(brand.tint.opacity(0.35), lineWidth: 1)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(Circle())
                    .padding(size * 0.08)
            }
            .frame(width: size, height: size)
            .accessibilityLabel(brand.displayName)
        } else {
            // No chain match: disc and glyph invert with the appearance, so
            // the glyph can never vanish into its own background.
            let dark = Color(white: 0.20)
            ZStack {
                Circle().fill(colorScheme == .dark ? Color.white : dark)
                Image(systemName: "building.2.fill")
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? dark : Color.white)
            }
            .frame(width: size, height: size)
            .accessibilityLabel(brand.displayName)
        }
    }
}
