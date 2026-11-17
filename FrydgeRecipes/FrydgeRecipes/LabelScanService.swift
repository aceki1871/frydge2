//
//  LabelScanService.swift
//  FrydgeRecipes
//
//  Uses Apple's on-device Foundation Models (Apple Intelligence, iOS 26+) to
//  extract structured product info from OCR text captured off a product label.
//  Falls back gracefully if the model is unavailable.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Generable output type

@available(iOS 26.0, *)
@Generable(description: "Product information extracted from a scanned label")
struct LabelExtractedInfo {
    @Guide(description: "The product brand and name, e.g. 'Sanitarium Weet-Bix' or 'Anchor Blue Milk'")
    var name: String

    @Guide(description: "Full ingredients list as printed on the label. Empty string if not visible.")
    var ingredients: String

    @Guide(description: "Package size or quantity as printed, e.g. '500g', '1.5L', '12 pack'. Empty string if not visible.")
    var quantity: String
}

// MARK: - Service

@available(iOS 26.0, *)
final class LabelScanService {
    static let shared = LabelScanService()
    private init() {}

    /// Extracts product info from raw OCR text lines captured from a label.
    /// Returns nil if Apple Intelligence is unavailable or extraction fails.
    func extract(from ocrLines: [String]) async -> LabelExtractedInfo? {
        guard FrydgeIntelligence.isAvailable else {
            print("[LabelScanService] Apple Intelligence not available.")
            return nil
        }
        guard !ocrLines.isEmpty else { return nil }

        // Trim the OCR dump — labels can be noisy, keep it focused
        let ocrText = ocrLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(60)
            .joined(separator: "\n")

        let session = LanguageModelSession(instructions: """
            You extract structured product information from OCR text scanned off product labels.
            Identify the brand and product name, the ingredients list, and the package size.
            If a field is not clearly present in the text, return an empty string for it.
            Do not invent information that isn't in the label text.
            """)

        do {
            let response = try await session.respond(
                to: "Label text:\n\(ocrText)",
                generating: LabelExtractedInfo.self
            )
            let info = response.content
            guard !info.name.isEmpty else { return nil }
            return info
        } catch {
            print("[LabelScanService] Extraction error: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Front-label name inference

@available(iOS 26.0, *)
@Generable(description: "The single consumer-facing product name read off the front of a grocery product")
struct FrontLabelName {
    @Guide(description: "The brand and product name a shopper would recognise, combined into one concise phrase, e.g. \"Whittaker's Creamy Milk Chocolate\" or \"Anchor Blue Milk\". Empty string if no product name is discernible.")
    var name: String
}

@available(iOS 26.0, *)
extension LabelScanService {
    /// Picks the most likely product name from noisy front-label OCR lines.
    ///
    /// This replaces the crude "longest line" heuristic with a model that can
    /// combine a brand line and a product-descriptor line and ignore slogans,
    /// weights, and legal text. Returns nil if Apple Intelligence is unavailable
    /// or no name is discernible, so callers can fall back to the heuristic.
    func bestProductName(from ocrLines: [String]) async -> String? {
        guard FrydgeIntelligence.isAvailable else { return nil }

        let cleaned = ocrLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(40)
        guard !cleaned.isEmpty else { return nil }
        let ocrText = cleaned.joined(separator: "\n")

        let session = LanguageModelSession(instructions: """
            You identify the consumer-facing product name from noisy OCR text captured off the front of a grocery product.
            Combine the brand and the product descriptor into one concise name a shopper would recognise.
            Ignore marketing slogans, nutrition facts, weights and sizes, barcodes, and legal text.
            If no product name is discernible, return an empty string. Never invent a name that isn't supported by the text.
            """)

        do {
            let response = try await session.respond(
                to: "Front label text:\n\(ocrText)",
                generating: FrontLabelName.self
            )
            let name = response.content.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        } catch {
            print("[LabelScanService] Name inference error: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Availability check (callable from non-available contexts)

enum LabelScanAvailability {
    /// Returns true if the device can use LabelScanService.
    static var isSupported: Bool {
        FrydgeIntelligence.isAvailable
    }
}
