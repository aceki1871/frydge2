//
//  UserLocationAnnotation.swift
//  FrydgeRecipes
//
//  Created by Josh on 29/10/2024.
//


import SwiftUI
import MapKit

struct UserLocationAnnotation: View {
    var coordinate: CLLocationCoordinate2D
    
    var body: some View {
        Image(systemName: "location.circle.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 30, height: 30)
            .foregroundColor(.blue)
    }
}