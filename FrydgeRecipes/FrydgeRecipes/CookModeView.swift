//
//  CookModeView.swift
//  FrydgeRecipes
//
//  Full-screen, animated, step-by-step cooking. Replaces the static
//  instruction list as the primary "how to make it" experience.
//

import SwiftUI
import Combine

struct CookModeView: View {
    let recipe: CloudRecipe

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int = 0
    @State private var remaining: Int? = nil
    @State private var timerRunning = false
    @State private var steps: [RecipeStep] = []
    /// Which ingredients (with quantities) go in on each page.
    @State private var plan: RecipeStagePlan = .empty

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var current: RecipeStep? {
        guard steps.indices.contains(index) else { return nil }
        return steps[index]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressBar

                TabView(selection: $index) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                        stepPage(step, number: i + 1)
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                controls
            }
            .navigationTitle(recipe.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ChefButton(
                        relevant: current.map { ChefTechniqueLibrary.relevant(to: $0) } ?? [],
                        context: "step \(index + 1)"
                    )
                }
            }
        }
        .onAppear {
            // Legacy recipes get structured lazily, right here.
            steps = StepInference.enrich(recipe.steps, ingredients: recipe.ingredients)
            if steps.isEmpty {
                steps = StepInference.steps(fromInstructions: recipe.instructions,
                                            ingredients: recipe.ingredients)
            }
            plan = RecipeStagePlan.build(ingredients: recipe.ingredients, steps: steps)
            UIApplication.shared.isIdleTimerDisabled = true
            loadTimerForCurrentStep()
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: index) { _, _ in loadTimerForCurrentStep() }
        .onReceive(tick) { _ in
            guard timerRunning, let r = remaining, r > 0 else { return }
            remaining = r - 1
            if remaining == 0 {
                timerRunning = false
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    // MARK: - Progress

    private var progressBar: some View {
        HStack(spacing: 4) {
            ForEach(steps.indices, id: \.self) { i in
                Capsule()
                    .fill(i <= index ? Color.blue : Color.secondary.opacity(0.2))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .animation(.easeInOut(duration: 0.25), value: index)
    }

    // MARK: - Page

    private func stepPage(_ step: RecipeStep, number: Int) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Step \(number) of \(steps.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                StepAnimationView(step: step, isPlaying: index == number - 1)
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )

                if let action = step.action {
                    Label(action.title, systemImage: action.symbol)
                        .font(.headline)
                        .foregroundStyle(.blue)
                }

                Text(step.displayText)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                // What to add on this page, with the saved quantities. Falls
                // back to the bare tagged names if nothing could be resolved.
                let stageLines = plan.ingredientLines(forStepID: step.id)
                if !stageLines.isEmpty {
                    VStack(spacing: 8) {
                        Label("Add now", systemImage: "plus.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        StageIngredientChips(lines: stageLines, showsCoverage: false)
                    }
                    .padding(.horizontal)
                } else if !step.ingredientRefs.isEmpty {
                    FlowChips(items: step.ingredientRefs)
                        .padding(.horizontal)
                }

                HStack(spacing: 10) {
                    if let v = step.vessel {
                        metaChip(v.title, systemImage: v.symbol)
                    }
                    if let h = step.heat, step.action?.usesHeat == true {
                        metaChip("\(h.title) heat", systemImage: "flame.fill", tint: h.tint)
                    }
                    if let t = step.temperatureDisplay {
                        metaChip(t, systemImage: "thermometer.medium", tint: .orange)
                    }
                }

                timerBlock(step)
            }
            .padding(.vertical, 20)
        }
    }

    private func metaChip(_ text: String, systemImage: String, tint: Color = .secondary) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    // MARK: - Timer

    @ViewBuilder
    private func timerBlock(_ step: RecipeStep) -> some View {
        if let total = step.timerSeconds, total > 0 {
            VStack(spacing: 10) {
                Text(RecipeStep.formatDuration(remaining ?? total))
                    .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())

                HStack(spacing: 12) {
                    Button {
                        timerRunning.toggle()
                    } label: {
                        Label(timerRunning ? "Pause" : "Start",
                              systemImage: timerRunning ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        remaining = total
                        timerRunning = false
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 40)
            }
            .padding(.top, 6)
        }
    }

    private func loadTimerForCurrentStep() {
        timerRunning = false
        remaining = current?.timerSeconds
    }

    // MARK: - Controls

    private var controls: some View {
        HStack {
            Button {
                withAnimation { index = max(0, index - 1) }
            } label: {
                Image(systemName: "chevron.left").font(.title2)
            }
            .disabled(index == 0)

            Spacer()

            Button {
                if index >= steps.count - 1 { dismiss() }
                else { withAnimation { index += 1 } }
            } label: {
                Text(index >= steps.count - 1 ? "Finish" : "Next")
                    .font(.headline)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color.blue))
                    .foregroundStyle(.white)
            }

            Spacer()

            Button {
                withAnimation { index = min(steps.count - 1, index + 1) }
            } label: {
                Image(systemName: "chevron.right").font(.title2)
            }
            .disabled(index >= steps.count - 1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Simple wrapping chip row

struct FlowChips: View {
    let items: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chips }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows(of: 2), id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(row, id: \.self) { chip($0) }
                    }
                }
            }
        }
    }

    private var chips: some View {
        ForEach(items, id: \.self) { chip($0) }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.blue.opacity(0.14)))
            .foregroundStyle(.blue)
    }

    private func rows(of size: Int) -> [[String]] {
        stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }
}
