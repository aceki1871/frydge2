//
//  WizardStepView.swift
//  Recipes
//
//  Created by Josh on 05/10/2024.
//


import SwiftUI

struct WizardStepView<Content: View>: View {
    var step: Int
    var totalSteps: Int
    var title: String
    var content: Content
    var onNext: () -> Void
    var onBack: () -> Void
    var canProceed: Bool

    init(step: Int, totalSteps: Int, title: String, @ViewBuilder content: () -> Content, onNext: @escaping () -> Void, onBack: @escaping () -> Void, canProceed: Bool) {
        self.step = step
        self.totalSteps = totalSteps
        self.title = title
        self.content = content()
        self.onNext = onNext
        self.onBack = onBack
        self.canProceed = canProceed
    }

    var body: some View {
        VStack {
            // Title
            Text(title)
                .font(.largeTitle)
                .padding()

            // Main content (custom view for each step)
            content
                .padding()

            Spacer()

            // Navigation controls
            HStack {
                // Back button
                if step > 1 {
                    Button(action: onBack) {
                        Text("Back")
                            .padding()
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(10)
                    }
                    .padding(.leading)
                }

                Spacer()

                // Step indicator
                Text("Step \(step) of \(totalSteps)")
                    .font(.footnote)

                Spacer()

                // Next button
                Button(action: onNext) {
                    Text("Next")
                        .padding()
                        .background(canProceed ? Color.blue : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .disabled(!canProceed)
                .padding(.trailing)
            }
            .padding()
        }
    }
}