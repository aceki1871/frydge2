//
//  ImageCredit.swift
//  FrydgeRecipes
//
//  Attribution metadata for a recipe image. Required for CC-BY / CC-BY-SA
//  images, which legally must show the author + license. Populated by
//  fetch_images.py from Wikimedia Commons.
//

import Foundation

struct ImageCredit: Codable, Hashable {
    var imageURL: String          // direct URL to the image file
    var sourcePageURL: String?    // the Commons file page (where the licence lives)
    var license: String?          // e.g. "CC BY-SA 4.0"
    var licenseURL: String?       // e.g. "https://creativecommons.org/licenses/by-sa/4.0/"
    var author: String?           // attribution name

    /// One-line credit string for display, e.g.
    /// "Photo: Jane Doe / CC BY-SA 4.0"
    var displayCredit: String {
        var parts: [String] = []
        if let a = author, !a.isEmpty { parts.append("Photo: \(a)") }
        if let l = license, !l.isEmpty { parts.append(l) }
        return parts.joined(separator: " / ")
    }
}
