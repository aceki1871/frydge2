//
//  RecipePageScanView.swift
//  FrydgeRecipes
//
//  Created by Josh on 13/01/2026.
//

import SwiftUI
import VisionKit
import Vision
import UIKit

struct RecipePageScanView: UIViewControllerRepresentable {
    typealias UIViewControllerType = VNDocumentCameraViewController

    var onComplete: (String) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onComplete: (String) -> Void

        init(onComplete: @escaping (String) -> Void) {
            self.onComplete = onComplete
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            controller.dismiss(animated: true)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            Task {
                let text = await OCRService.recognize(scan: scan)
                await MainActor.run {
                    controller.dismiss(animated: true)
                    onComplete(text)
                }
            }
        }
    }
}

enum OCRService {
    static func recognize(scan: VNDocumentCameraScan) async -> String {
        guard scan.pageCount > 0 else { return "" }

        var allText: [String] = []
        allText.reserveCapacity(scan.pageCount)

        for i in 0..<scan.pageCount {
            let img = scan.imageOfPage(at: i)
            let t = await recognize(image: img)
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                allText.append(t)
            }
        }

        return allText.joined(separator: "\n\n")
    }

    static func recognize(image: UIImage) async -> String {
        await withCheckedContinuation { cont in
            guard let cgImage = image.cgImage else {
                cont.resume(returning: "")
                return
            }

            let request = VNRecognizeTextRequest { req, _ in
                let strings = (req.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n") ?? ""

                cont.resume(returning: strings)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            // If you want to bias UK spelling etc:
            // request.recognitionLanguages = ["en-GB"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                cont.resume(returning: "")
            }
        }
    }
}
