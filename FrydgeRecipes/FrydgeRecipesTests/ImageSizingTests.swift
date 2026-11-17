//
//  ImageSizingTests.swift
//  FrydgeRecipesTests
//
//  Guards the size policy every image path now goes through: nothing is
//  decoded, resized, or encoded above its ImageBudget.
//

import Testing
import UIKit
@testable import FrydgeRecipes

struct ImageSizingTests {

    private func solidImage(width: CGFloat, height: CGFloat, scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func longestEdgePixels(_ image: UIImage) -> CGFloat {
        max(image.size.width * image.scale, image.size.height * image.scale)
    }

    @Test func oversizedBitmapIsScaledToBudget() {
        let big = solidImage(width: 4032, height: 3024)
        let bounded = big.frydgeBounded(maxPixelSize: ImageBudget.upload)
        #expect(longestEdgePixels(bounded) <= ImageBudget.upload)
        #expect(longestEdgePixels(bounded) >= ImageBudget.upload - 1)
        // Aspect ratio preserved (4:3).
        let ratio = bounded.size.width / bounded.size.height
        #expect(abs(ratio - 4.0 / 3.0) < 0.01)
    }

    @Test func retinaScaleCountsAsPixels() {
        // 1200 pt @3x is 3600 px: must be scaled even though the point size looks small.
        let retina = solidImage(width: 1200, height: 800, scale: 3)
        let bounded = retina.frydgeBounded(maxPixelSize: ImageBudget.display)
        #expect(longestEdgePixels(bounded) <= ImageBudget.display)
    }

    @Test func smallBitmapIsReturnedUnchanged() {
        let small = solidImage(width: 300, height: 200)
        let bounded = small.frydgeBounded(maxPixelSize: ImageBudget.display)
        #expect(bounded === small)
    }

    @Test func boundedJPEGRespectsPixelAndByteCaps() throws {
        let big = solidImage(width: 6000, height: 4000)
        let data = try #require(big.frydgeBoundedJPEG(maxPixelSize: ImageBudget.upload, quality: 0.9))
        #expect(data.count <= ImageBudget.maxUploadBytes)

        let decoded = try #require(UIImage.frydgeBounded(data: data, maxPixelSize: 10_000))
        #expect(longestEdgePixels(decoded) <= ImageBudget.upload)
    }

    @Test func boundedDecodeFromDataHonoursBudget() throws {
        let big = solidImage(width: 5000, height: 2000)
        let data = try #require(big.jpegData(compressionQuality: 0.7))

        let thumb = try #require(UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.thumbnail))
        #expect(longestEdgePixels(thumb) <= ImageBudget.thumbnail)

        let display = try #require(UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.display))
        #expect(longestEdgePixels(display) <= ImageBudget.display)
    }

    @Test func boundedDecodeIsMemoised() throws {
        let image = solidImage(width: 2000, height: 1500)
        let data = try #require(image.pngData())
        let first = try #require(UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.thumbnail))
        let second = try #require(UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.thumbnail))
        #expect(first === second)
    }

    @Test func nilAndGarbageDataDecodeToNil() {
        #expect(UIImage.frydgeBounded(data: nil, maxPixelSize: ImageBudget.display) == nil)
        #expect(UIImage.frydgeBounded(data: Data(), maxPixelSize: ImageBudget.display) == nil)
        #expect(UIImage.frydgeBounded(data: Data("not an image".utf8), maxPixelSize: ImageBudget.display) == nil)
        #expect(UIImage.frydgeBounded(contentsOf: nil, maxPixelSize: ImageBudget.display) == nil)
    }

    @Test func budgetsAreOrderedSensibly() {
        #expect(ImageBudget.thumbnail < ImageBudget.display)
        #expect(ImageBudget.display <= ImageBudget.capture)
        #expect(ImageBudget.upload <= ImageBudget.capture)
    }
}
