//
//  RecipesApp.swift
//  Recipes
//
//  Created by Josh on 06/10/2024.
//


import SwiftUI

struct RecipesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView() // Entry point to handle authentication and app flow
        }
    }
}
