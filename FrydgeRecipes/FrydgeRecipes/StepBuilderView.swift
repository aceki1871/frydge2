//
//  StepBuilderView.swift
//  FrydgeRecipes
//
//  Chip-based step authoring. You never type a sentence — pick an action,
//  tap ingredients, set time/heat. The sentence is generated.
//  Drop this into RecipeEditorView in place of the free-text step composer.
//

import SwiftUI

struct StepBuilderView: View {
    /// The recipe's current ingredient lines, so we can offer them as chips.
    let availableIngredients: [String]

    /// Called when the user commits the step.
    var onCommit: (RecipeStep) -> Void

    @State private var group: CookAction.Group = .prep
    @State private var action: CookAction?
    @State private var selected: Set<String> = []
    @State private var vessel: Vessel?
    @State private var heat: HeatLevel = .medium
    @State private var minutes: Int = 0
    @State private var seconds: Int = 0
    @State private var temperature: Int = 180
    @State private var tempUnit: String = "°C"
    @State private var note: String = ""

    private var ingredientChips: [String] {
        availableIngredients
            .map { StepInference.coreNoun(of: $0) }
            .filter { !$0.isEmpty }
    }

    private var draft: RecipeStep {
        let total = minutes * 60 + seconds
        return RecipeStep(
            text: "",
            timerSeconds: total > 0 ? total : nil,
            temperatureValue: (action?.usesTemperature ?? false) ? temperature : nil,
            temperatureUnit: (action?.usesTemperature ?? false) ? tempUnit : nil,
            action: action,
            ingredientRefs: ingredientChips.filter { selected.contains($0) },
            vessel: vessel ?? action?.defaultVessel,
            heat: (action?.usesHeat ?? false) ? heat : nil,
            note: note.isEmpty ? nil : note
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Live preview — animation + generated sentence
            if action != nil {
                VStack(spacing: 10) {
                    StepAnimationView(step: draft)
                        .frame(height: 130)
                    Text(draft.generatedText)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial))
                .transition(.opacity.combined(with: .scale))
            }

            // 1. Action group
            Picker("Group", selection: $group) {
                ForEach(CookAction.Group.allCases) { g in
                    Label(g.rawValue, systemImage: g.symbol).tag(g)
                }
            }
            .pickerStyle(.segmented)

            // 2. Action
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CookAction.actions(in: group)) { a in
                        Button {
                            withAnimation(.snappy) {
                                action = a
                                vessel = a.defaultVessel
                                if let s = a.suggestedSeconds {
                                    minutes = s / 60
                                    seconds = s % 60
                                }
                            }
                        } label: {
                            Label(a.title, systemImage: a.symbol)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(action == a ? Color.blue : Color.secondary.opacity(0.14))
                                )
                                .foregroundStyle(action == a ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }

            // 3. Ingredients
            if !ingredientChips.isEmpty {
                sectionLabel("Ingredients used")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ingredientChips, id: \.self) { name in
                            Button {
                                if selected.contains(name) { selected.remove(name) }
                                else { selected.insert(name) }
                            } label: {
                                Text(name)
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule().fill(selected.contains(name)
                                                       ? Color.blue.opacity(0.85)
                                                       : Color.secondary.opacity(0.12))
                                    )
                                    .foregroundStyle(selected.contains(name) ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            // 4. Parameters
            if let a = action {
                if a.usesHeat {
                    sectionLabel("Heat")
                    Picker("Heat", selection: $heat) {
                        ForEach(HeatLevel.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                if a.usesTemperature {
                    sectionLabel("Temperature")
                    HStack {
                        Stepper("\(temperature)\(tempUnit)", value: $temperature, in: 50...300, step: 5)
                        Picker("", selection: $tempUnit) {
                            Text("°C").tag("°C"); Text("°F").tag("°F")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 110)
                    }
                }

                sectionLabel("Time")
                HStack {
                    Stepper("\(minutes) min", value: $minutes, in: 0...600)
                    Stepper("\(seconds) sec", value: $seconds, in: 0...59, step: 5)
                }

                sectionLabel("Note (optional)")
                TextField("e.g. until golden brown", text: $note)
                    .textFieldStyle(.roundedBorder)

                Button {
                    onCommit(draft)
                    reset()
                } label: {
                    Label("Add step", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .animation(.snappy, value: action)
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func reset() {
        action = nil
        selected = []
        vessel = nil
        heat = .medium
        minutes = 0
        seconds = 0
        note = ""
    }
}
