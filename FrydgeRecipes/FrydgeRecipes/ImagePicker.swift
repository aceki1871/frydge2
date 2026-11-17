import SwiftUI
import PhotosUI
import UIKit

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var images: [UIImage]
    var sourceType: UIImagePickerController.SourceType = .photoLibrary
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let uiImage = (info[.originalImage] as? UIImage)?.frydgeBounded(maxPixelSize: ImageBudget.capture) {
                DispatchQueue.main.async {
                    // Resize and crop the image to a square format
                    let resizedImage = self.resizeAndCropImage(uiImage, to: CGSize(width: 200, height: 200))
                    self.parent.images.append(resizedImage)
                }
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        // Helper function to resize and crop the image
        private func resizeAndCropImage(_ image: UIImage, to targetSize: CGSize) -> UIImage {
            let aspectRatio = targetSize.width / targetSize.height

            var newSize: CGSize
            if image.size.width > image.size.height {
                newSize = CGSize(width: image.size.height * aspectRatio, height: image.size.height)
            } else {
                newSize = CGSize(width: image.size.width, height: image.size.width / aspectRatio)
            }

            // Crop the image to target size
            let cropRect = CGRect(
                x: (image.size.width - newSize.width) / 2,
                y: (image.size.height - newSize.height) / 2,
                width: newSize.width,
                height: newSize.height
            )

            guard let cgImage = image.cgImage?.cropping(to: cropRect) else {
                return image // Return original if cropping fails
            }

            // Resize the cropped image
            UIGraphicsBeginImageContextWithOptions(targetSize, false, 0.0)
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: targetSize))
            let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()

            return resizedImage ?? image
        }
    }
}
