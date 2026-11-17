//
//  AppIntent.swift
//  FrydgeRecipesLiveActivity
//
//  Created by Josh on 26/04/2025.
//

import WidgetKit
import AppIntents

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Configuration" }
    static var description: IntentDescription { "This is an example widget." }
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }

    // An example configurable parameter.
    @Parameter(title: "Favorite Emoji", default: "😃")
    var favoriteEmoji: String
}
