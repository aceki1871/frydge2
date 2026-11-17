//
//  DietaryBadgeChip.swift
//  FrydgeRecipes
//
//  Created by Josh on 09/09/2025.
//


import SwiftUI

struct DietaryBadgeChip: View {
    let tag: String       // "DF", "GF", "V", "VG"
    let tone: Tone        // .green / .orange / .gray / .brand

    enum Tone { case green, orange, teal, gray, brand }

    var body: some View {
        Text(tag)
            .font(.caption2).bold()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(bgColor)
            )
            .foregroundColor(.white)
            .accessibilityLabel("\(readableTag) tag")
    }

    private var bgColor: Color {
        switch tone {
        case .green:  return .green
        case .orange: return .orange
        case .teal:   return .teal
        case .gray:   return .gray
        case .brand:  return .blue
        }
    }

    private var readableTag: String {
        switch tag.uppercased() {
        case "DF": return "Dairy Free"
        case "GF": return "Gluten Free"
        case "V":  return "Vegetarian"
        case "VG": return "Vegan"
        default:   return tag
        }
    }
}
