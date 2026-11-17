//
//  ImageHelper.swift
//  Recipes
//
//  Created by Josh on 07/10/2024.
//


import UIKit

class ImageHelper {
    static func resizeImage(image: UIImage, targetSize: CGSize) -> UIImage? {
        let size = image.size

        let widthRatio  = targetSize.width  / size.width
        let heightRatio = targetSize.height / size.height

        let scaleFactor = min(widthRatio, heightRatio)

        let newSize = CGSize(width: size.width * scaleFactor, height: size.height * scaleFactor)
        let renderer = UIGraphicsImageRenderer(size: newSize)

        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    static func storeImage(_ image: UIImage, withName name: String) -> URL? {
        guard let data = image.jpegData(compressionQuality: 0.7) else { return nil }
        let filename = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).jpg")
        try? data.write(to: filename)
        return filename
    }

    /// Bounded even here: nothing in the app decodes above `ImageBudget.display`.
    static func loadHighResImage(fromURL url: URL) -> UIImage? {
        UIImage.frydgeBounded(contentsOf: url, maxPixelSize: ImageBudget.display)
    }
}