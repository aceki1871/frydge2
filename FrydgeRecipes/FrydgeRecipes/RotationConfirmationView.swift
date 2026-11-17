//
//  RotationConfirmationView.swift
//  FrydgeRecipes
//
//  Created by Josh on 25/11/2024.
//


import SwiftUI

struct RotationConfirmationView: View {
    @Binding var image: UIImage
    @Environment(\.dismiss) private var dismiss

    @State private var rotationAngle: Double = 0
    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 1.0

    var onConfirm: (UIImage) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Adjust Image Orientation and Position")
                .font(.headline)
                .padding(.top)

            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.8)

                    Image(uiImage: rotatedImage())
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width * 0.9, height: geometry.size.width * 0.9)
                        .offset(offset)
                        .scaleEffect(scale)
                        .clipped()
                        .gesture(
                            DragGesture()
                                .onChanged { gesture in
                                    offset = gesture.translation
                                }
                        )
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = value
                                }
                        )
                }
                .frame(width: geometry.size.width * 0.9, height: geometry.size.width * 0.9)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white, lineWidth: 2)
                )
            }
            .frame(height: 300) // Fixed height for better layout.

            HStack {
                Button(action: {
                    rotationAngle -= 90
                }) {
                    Image(systemName: "rotate.left")
                        .font(.title)
                        .padding()
                }

                Button(action: {
                    rotationAngle += 90
                }) {
                    Image(systemName: "rotate.right")
                        .font(.title)
                        .padding()
                }
            }

            Button(action: {
                onConfirm(croppedImage())
                dismiss()
            }) {
                Text("Confirm")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(8)
            }
        }
        .padding()
    }

    private func rotatedImage() -> UIImage {
        let radians = CGFloat(rotationAngle * Double.pi / 180)
        let newSize = CGRect(origin: .zero, size: image.size)
            .applying(CGAffineTransform(rotationAngle: radians))
            .integral.size

        UIGraphicsBeginImageContextWithOptions(newSize, false, image.scale)
        let context = UIGraphicsGetCurrentContext()!

        context.translateBy(x: newSize.width / 2, y: newSize.height / 2)
        context.rotate(by: radians)

        image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width, height: image.size.height))

        let rotatedImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()

        return rotatedImage
    }

    private func croppedImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300))
        let croppedImage = renderer.image { _ in
            rotatedImage().draw(
                in: CGRect(
                    origin: CGPoint(x: -offset.width, y: -offset.height),
                    size: CGSize(
                        width: rotatedImage().size.width * scale,
                        height: rotatedImage().size.height * scale
                    )
                )
            )
        }
        return croppedImage
    }
}
