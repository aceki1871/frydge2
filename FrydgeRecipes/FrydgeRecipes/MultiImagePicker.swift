//
//  MultiImagePicker.swift
//  Recipes
//
//  Created by Josh on 07/10/2024.
//


import SwiftUI
import UIKit

struct MultiImagePicker: UIViewControllerRepresentable {
    @Binding var selectedImages: [UIImage]
    @Binding var highResImageURLs: [URL]

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        var parent: MultiImagePicker

        init(parent: MultiImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = (info[.originalImage] as? UIImage)?.frydgeBounded(maxPixelSize: ImageBudget.capture) {
                parent.selectedImages.append(image)
                if let assetURL = info[.imageURL] as? URL {
                    parent.highResImageURLs.append(assetURL)
                }
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: UIViewControllerRepresentableContext<MultiImagePicker>) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .photoLibrary
        picker.allowsEditing = false
        picker.mediaTypes = ["public.image"]
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: UIViewControllerRepresentableContext<MultiImagePicker>) {
        // No updates necessary
    }
}
