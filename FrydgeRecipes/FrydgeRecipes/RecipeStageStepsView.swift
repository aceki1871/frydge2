//
//  RecipeStageStepsView.swift
//  FrydgeRecipes
//
//  The instructions list on the recipe page, one card per stage: the step
//  text, the ingredients (with quantities) that go in at that stage, and the
//  stage's timer / temperature. Pulled out of RecipeDetailView so the same
//  presentation can be reused and tested on its own.
//

import SwiftUI

struct RecipeStageStepsView: View {
    let plan: RecipeStagePlan
    /// Formats an ingredient line for display (the detail page scales it to
    /// the chosen number of serves). Defaults to the saved line.
    var displayLine: (String) -> String = { $0 }
    /// Whether the fridge covers this line, for the tick on the chip.
    var isCovered: (String) -> Bool = { _ in false }
    /// Hide ticks where no fridge context exists (cook mode).
    var showsCoverage: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(plan.stages) { stage in
                stageCard(stage)
            }

            if !plan.unassigned.isEmpty, plan.hasAnyAssignments {
                alsoNeededCard
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Stage card

    private func stageCard(_ stage: RecipeStagePlan.Stage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(stage.number).")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 22, alignment: .leading)

                Text(stage.step.displayText)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }

            if !stage.ingredientLines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Add at this stage", systemImage: "plus.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)

                    StageIngredientChips(
                        lines: stage.ingredientLines,
                        displayLine: displayLine,
                        isCovered: isCovered,
                        showsCoverage: showsCoverage
                    )
                }
                .padding(.leading, 32)
            }

            stageMeta(stage.step)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func stageMeta(_ step: RecipeStep) -> some View {
        let hasMedia = !(step.mediaURLString ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if step.hasTimer || step.hasTemperature || hasMedia {
            HStack(spacing: 14) {
                if let timer = step.timerDisplay {
                    Label(timer, systemImage: "timer")
                        .foregroundColor(.orange)
                }
                if let temperature = step.temperatureDisplay {
                    Label(temperature, systemImage: "thermometer.medium")
                }
                if hasMedia {
                    Label("Media attached", systemImage: "play.rectangle")
                }
                Spacer(minLength: 0)
            }
            .font(.caption.weight(.medium))
            .foregroundColor(.secondary)
            .padding(.leading, 32)
        }
    }

    // MARK: - Also needed

    private var alsoNeededCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Also needed", systemImage: "tray")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Text("Not mentioned in a step; have these ready before you start.")
                .font(.caption2)
                .foregroundColor(.secondary)
            StageIngredientChips(
                lines: plan.unassigned,
                displayLine: displayLine,
                isCovered: isCovered,
                showsCoverage: showsCoverage
            )
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

// MARK: - Chips

/// Wrapping row of ingredient chips with a tick for lines the fridge covers.
struct StageIngredientChips: View {
    let lines: [String]
    var displayLine: (String) -> String = { $0 }
    var isCovered: (String) -> Bool = { _ in false }
    var showsCoverage: Bool = true

    var body: some View {
        WrappingHStack(spacing: 6, lineSpacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                chip(line)
            }
        }
    }

    private func chip(_ line: String) -> some View {
        let covered = showsCoverage && isCovered(line)
        return HStack(spacing: 5) {
            if showsCoverage {
                Image(systemName: covered ? "checkmark.circle.fill" : "circle")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(covered ? .green : .secondary.opacity(0.6))
            }
            Text(displayLine(line))
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(covered ? Color.green.opacity(0.14) : Color.blue.opacity(0.12)))
        .foregroundStyle(covered ? Color.green : Color.blue)
        .accessibilityLabel(showsCoverage ? "\(displayLine(line)), \(covered ? "in the fridge" : "not in the fridge")" : displayLine(line))
    }
}

/// Minimal wrapping layout for chips (left-aligned, wraps to new rows).
struct WrappingHStack: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: maxWidth == .infinity ? width : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
