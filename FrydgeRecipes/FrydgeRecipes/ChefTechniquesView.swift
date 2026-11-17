//
//  ChefTechniquesView.swift
//  FrydgeRecipes
//
//  The sheet behind the "Chef" button. Shows the techniques relevant to
//  where it was opened from (a cooking step, a recipe, a fridge item) first,
//  then the whole library, searchable. Each technique opens to numbered
//  steps, tips and a video link.
//

import SwiftUI

/// Compact button that opens the technique sheet. Drop it into any toolbar
/// or control row; pass `relevant` to lead with the techniques that matter
/// where it sits.
struct ChefButton: View {
    var relevant: [ChefTechnique] = []
    var context: String? = nil
    var style: Style = .toolbar

    enum Style { case toolbar, pill, onDark }

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            switch style {
            case .toolbar:
                Image(systemName: "graduationcap.fill")
            case .pill:
                Label("Chef's tips", systemImage: "graduationcap.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .foregroundStyle(.orange)
            case .onDark:
                VStack(spacing: 5) {
                    Image(systemName: "graduationcap.fill")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("Chef")
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(relevant.isEmpty ? Color.white.opacity(0.12) : Color.orange.opacity(0.22))
                )
                .foregroundColor(relevant.isEmpty ? .white : .orange)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(relevant.isEmpty ? "Chef's techniques" : "Chef's techniques, \(relevant.count) for this step")
        .sheet(isPresented: $isPresented) {
            ChefTechniquesView(relevant: relevant, context: context)
        }
    }
}

struct ChefTechniquesView: View {
    var relevant: [ChefTechnique] = []
    var context: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var quickTechnique: QuickTechnique?
    @State private var isGeneratingQuickTip = false

    private var results: [ChefTechnique] { ChefTechniqueLibrary.search(query) }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            List {
                if !isSearching, !relevant.isEmpty {
                    Section {
                        ForEach(relevant) { technique in
                            row(technique)
                        }
                    } header: {
                        Text(context.map { "For \($0)" } ?? "For this step")
                    }
                } else if !isSearching, relevant.isEmpty, let context, FrydgeIntelligence.isSupportedOnDevice {
                    Section {
                        quickTipContent(for: context)
                    } header: {
                        Text("For \(context)")
                    }
                }

                Section(isSearching ? "Results" : "All techniques") {
                    if results.isEmpty {
                        Text("Nothing matches “\(query)”. Try the food or the action — “egg”, “fillet”, “dice”.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(results) { technique in
                            row(technique)
                        }
                    }
                }
            }
            .navigationTitle("Chef's techniques")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Crack an egg, slice fish, dice onion…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: ChefTechnique.self) { technique in
                ChefTechniqueDetailView(technique: technique)
            }
        }
    }

    @ViewBuilder
    private func quickTipContent(for stepText: String) -> some View {
        if let quickTechnique {
            VStack(alignment: .leading, spacing: 8) {
                Label(quickTechnique.title, systemImage: "sparkles")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.purple)
                ForEach(Array(quickTechnique.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !quickTechnique.tip.isEmpty {
                    Text(quickTechnique.tip)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } else if isGeneratingQuickTip {
            HStack(spacing: 8) {
                ProgressView()
                Text("Getting a tip…")
                    .foregroundStyle(.secondary)
            }
        } else {
            Button {
                isGeneratingQuickTip = true
                Task {
                    quickTechnique = await QuickTechniqueAI.technique(for: stepText)
                    isGeneratingQuickTip = false
                }
            } label: {
                Label("Ask Apple Intelligence for a tip", systemImage: "sparkles")
            }
        }
    }

    private func row(_ technique: ChefTechnique) -> some View {
        NavigationLink(value: technique) {
            HStack(spacing: 12) {
                Text(technique.emoji)
                    .font(.title2)
                    .frame(width: 36, height: 36)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(technique.title)
                        .font(.body.weight(.semibold))
                    Text(technique.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct ChefTechniqueDetailView: View {
    let technique: ChefTechnique

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Text(technique.emoji)
                        .font(.system(size: 44))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(technique.title)
                            .font(.title2.weight(.bold))
                        Text(technique.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(technique.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Color.orange, in: Circle())
                            Text(step)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !technique.tips.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Chef's tips", systemImage: "lightbulb.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        ForEach(technique.tips, id: \.self) { tip in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•")
                                Text(tip)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.subheadline)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Watch it done", systemImage: "play.rectangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    StepAnimationView(
                        primitive: technique.demonstrationPrimitive,
                        tint: .orange,
                        accessibilityLabel: "\(technique.title) demonstration"
                    )
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if !technique.foods.isEmpty {
                    Text("Applies to: " + technique.foods.map { $0.capitalized }.formatted(.list(type: .and)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle(technique.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
