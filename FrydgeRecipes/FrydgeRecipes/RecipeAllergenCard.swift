//
//  RecipeAllergenCard.swift
//  FrydgeRecipes
//
//  Shown at the top of a recipe that trips one of the user's can't / won't
//  eat rules: which lines are the problem and what to use instead, so the
//  recipe is adapted on the spot rather than just flagged.
//

import SwiftUI

struct RecipeAllergenCard: View {
    let verdict: RecipeAllergenVerdict

    @State private var isExpanded = true

    private var tint: Color { verdict.isUnsafe ? .red : .orange }

    private struct Row: Identifiable {
        let line: String
        let term: String
        let blocking: Bool
        var id: String { "\(blocking)|\(line)" }
    }

    private var rows: [Row] {
        verdict.unsafe.map { Row(line: $0.line, term: $0.term, blocking: true) }
            + verdict.flagged.map { Row(line: $0.line, term: $0.term, blocking: false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isExpanded {
                swapList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(0.4), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: verdict.isUnsafe ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verdict.isUnsafe ? "Not safe for you as written" : "Heads up")
                        .font(.headline)
                        .foregroundStyle(tint)
                    if let headline = verdict.headline {
                        Text(headline + " · tap for swaps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var swapList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                swapRow(row)
            }
        }
    }

    private func swapRow(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(row.blocking ? Color.red : Color.orange)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.line)
                    .font(.subheadline)
                    .strikethrough(row.blocking, color: .secondary)
                    .foregroundStyle(row.blocking ? .secondary : .primary)
                    .lineLimit(2)
                if let swap = AllergenSwaps.substitute(for: row.term, ingredient: row.line) {
                    Text("Use \(swap)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(row.blocking ? "Leave it out, or pick another recipe." : "Leave it out if you'd rather.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
