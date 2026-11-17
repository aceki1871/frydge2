//
//  RemoteImageFetcherTests.swift
//  FrydgeRecipesTests
//
//  Pins the Wikimedia thumbnail URL mapping and the ImageIO downsampler.
//  Both are load-bearing for "images don't load" in App Review: a wrong
//  thumbnail path (or a non-standard width) is a 400 from Wikimedia, and an
//  un-downsampled 8000 px original is a memory spike on a list of cards.
//

import Testing
import UIKit
@testable import FrydgeRecipes

struct RemoteImageFetcherTests {

    // MARK: - Wikimedia candidates

    @Test func commonsOriginalGetsThumbnailThenOriginal() throws {
        let original = try #require(URL(string: "https://upload.wikimedia.org/wikipedia/commons/6/67/Pavlova_dessert.JPG"))
        let candidates = RemoteImageFetcher.wikimediaCandidates(for: original)

        #expect(candidates.count == 2)
        #expect(candidates.first?.absoluteString
                == "https://upload.wikimedia.org/wikipedia/commons/thumb/6/67/Pavlova_dessert.JPG/\(RemoteImageFetcher.wikimediaThumbnailWidth)px-Pavlova_dessert.JPG")
        #expect(candidates.last == original)
    }

    @Test func thumbnailWidthIsAStandardWikimediaStep() {
        // Hot-linked thumbnails at any other width are rejected with HTTP 400.
        let standardSteps: Set<Int> = [20, 40, 60, 120, 250, 330, 500, 960, 1280, 1920, 3840]
        #expect(standardSteps.contains(RemoteImageFetcher.wikimediaThumbnailWidth))
    }

    @Test func percentEncodedNamesRoundTrip() throws {
        let original = try #require(URL(string: "https://upload.wikimedia.org/wikipedia/commons/a/a4/Banoffee_pie_-_Richmond_Park%2C_UK.jpg"))
        let thumb = try #require(RemoteImageFetcher.wikimediaCandidates(for: original).first)

        // Comma is a legal path character; either encoding is fine as long as
        // the directory and file segments are both present and consistent.
        #expect(thumb.pathComponents.contains("thumb"))
        // ["/", "wikipedia", "commons", "thumb", "a", "a4", <file>, <thumb name>]
        #expect(thumb.pathComponents[6] == "Banoffee_pie_-_Richmond_Park,_UK.jpg")
        #expect(thumb.lastPathComponent == "1280px-Banoffee_pie_-_Richmond_Park,_UK.jpg")
    }

    @Test func djvuAndPdfUseRenderedPageThumbnail() throws {
        let djvu = try #require(URL(string: "https://upload.wikimedia.org/wikipedia/commons/0/0d/The_Epicurean_%28Ranhofer%2C_1920%29.djvu"))
        let thumb = try #require(RemoteImageFetcher.wikimediaCandidates(for: djvu).first)
        #expect(thumb.lastPathComponent == "page1-1280px-The_Epicurean_(Ranhofer,_1920).djvu.jpg")
    }

    @Test func svgUsesPNGThumbnail() throws {
        let svg = try #require(URL(string: "https://upload.wikimedia.org/wikipedia/commons/1/11/Example.svg"))
        let thumb = try #require(RemoteImageFetcher.wikimediaCandidates(for: svg).first)
        #expect(thumb.lastPathComponent == "1280px-Example.svg.png")
    }

    @Test func nonWikimediaURLsPassThroughUntouched() throws {
        let url = try #require(URL(string: "https://assets.woolworths.com.au/images/1005/123456.jpg"))
        #expect(RemoteImageFetcher.wikimediaCandidates(for: url) == [url])
    }

    @Test func alreadyAThumbnailPassesThrough() throws {
        let thumb = try #require(URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/6/67/Pavlova_dessert.JPG/500px-Pavlova_dessert.JPG"))
        #expect(RemoteImageFetcher.wikimediaCandidates(for: thumb) == [thumb])
    }

    // MARK: - Downsampling

    @Test func largeImageIsDownsampledToMaxPixelSize() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000)).image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        }
        let data = try #require(big.jpegData(compressionQuality: 0.6))

        let decoded = try #require(RemoteImageFetcher.decodeDownsampled(data, maxPixelSize: 1600))
        let longest = max(decoded.size.width * decoded.scale, decoded.size.height * decoded.scale)
        #expect(longest <= 1600)
        #expect(longest > 1500)   // not shrunk beyond what was asked
    }

    @Test func smallImageIsNotUpscaled() throws {
        let small = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { ctx in
            UIColor.green.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }
        let data = try #require(small.pngData())

        let decoded = try #require(RemoteImageFetcher.decodeDownsampled(data, maxPixelSize: 1600))
        let pixelWidth = decoded.size.width * decoded.scale
        #expect(pixelWidth <= small.size.width * small.scale)
    }

    @Test func nonImageDataDecodesToNil() {
        let html = Data("<!DOCTYPE html><html><body>Wikimedia Error</body></html>".utf8)
        #expect(RemoteImageFetcher.decodeDownsampled(html) == nil)
        #expect(RemoteImageFetcher.decodeDownsampled(Data()) == nil)
    }
}
