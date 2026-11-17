//
//  GlobeView.swift
//  FrydgeRecipes
//
//  Created by Josh on 07/10/2024.
//

import SwiftUI

struct GlobeView: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Image(systemName: "globe")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundColor(colorScheme == .dark ? .gray : .blue)
    }
}
