//
//  DietaryRestrictionsView.swift
//  FrydgeRecipes
//
//  Profile → Dietary → "Can't & won't eat". Lets the user be as specific as
//  they like about ingredients (allergies, intolerances, dislikes, additives)
//  and shows where those rules bite. Also home to `DietaryFlagCard`, the
//  inline warning the product card and scan sheets show when a food matches.
//

import SwiftUI

// MARK: - Editor

struct DietaryRestrictionsView: View {
    @ObservedObject private var store = DietaryRestrictionStore.shared
    @AppStorage(DietaryRestrictionStore.profileTagsKey) private var profileDietaryCSV = ""

    @State private var newTerm = ""
    @State private var newSeverity: DietaryRestriction.Severity = .cannot
    @State private var editing: DietaryRestriction?
    @State private var testName = ""
    @FocusState private var termFieldFocused: Bool

    var body: some View {
        List {
            // MARK: Add
            Section {
                HStack(spacing: 10) {
                    TextField("e.g. peanuts, palm oil, E621, cow's milk", text: $newTerm)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($termFieldFocused)
                        .onSubmit(addTyped)
                    Button(action: addTyped) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Picker("Treat as", selection: $newSeverity) {
                    ForEach(DietaryRestriction.Severity.allCases) { severity in
                        Text(severity.title).tag(severity)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Add an ingredient")
            } footer: {
                Text("Be as specific as you like: a food (“brie”), a family (“cheese”, which also catches brie and feta), an additive (“E621” or “MSG”) or a phrase (“palm oil”). “Can't eat” is for allergies and medical needs and shows as a red stop; “Prefer not to” shows as an amber warning.")
            }

            // MARK: Quick picks
            Section {
                chipGrid(DietaryRestrictionStore.commonAllergens, severity: .cannot)
            } header: {
                Text("Common allergens")
            } footer: {
                Text("Tap to add as “can't eat”. Tap again to remove.")
            }

            Section {
                chipGrid(DietaryRestrictionStore.commonAvoids, severity: .avoid)
            } header: {
                Text("Often avoided")
            }

            // MARK: Lists
            if !store.cannotEat.isEmpty {
                Section {
                    ForEach(store.cannotEat) { restriction in
                        row(restriction)
                    }
                    .onDelete { offsets in delete(offsets, from: store.cannotEat) }
                } header: {
                    Label("Can't eat", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }

            if !store.prefersToAvoid.isEmpty {
                Section {
                    ForEach(store.prefersToAvoid) { restriction in
                        row(restriction)
                    }
                    .onDelete { offsets in delete(offsets, from: store.prefersToAvoid) }
                } header: {
                    Label("Prefer not to", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            // MARK: Implied by profile tags
            if !impliedSummary.isEmpty {
                Section {
                    ForEach(impliedSummary, id: \.label) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.label)
                                .font(.subheadline.weight(.semibold))
                            Text(entry.terms.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("From your dietary tags")
                } footer: {
                    Text("Your GF / DF / V / VG tags in Profile already warn about these as “prefer not to”. Add any of them above to make it a hard “can't eat”.")
                }
            }

            // MARK: Try it
            Section {
                TextField("Type a food to see what would be flagged", text: $testName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                let flags = store.flags(forName: testName)
                if !testName.trimmingCharacters(in: .whitespaces).isEmpty {
                    if flags.isEmpty {
                        Label("No match — this would be added quietly.", systemImage: "checkmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        DietaryFlagCard(flags: flags)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                }
            } header: {
                Text("Try it")
            } footer: {
                Text("Frydge checks every item you add to your fridge or shopping list, and every product you scan, against this list. Matches on the product name use the same food matcher as recipes; matches in a product's ingredients list are whole-word.")
            }
        }
        .navigationTitle("Can't & won't eat")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { restriction in
            DietaryRestrictionEditSheet(restriction: restriction)
        }
    }

    // MARK: Rows & chips

    private func row(_ restriction: DietaryRestriction) -> some View {
        Button {
            editing = restriction
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(restriction.displayTerm)
                        .foregroundStyle(.primary)
                    if !restriction.note.isEmpty {
                        Text(restriction.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func chipGrid(_ terms: [String], severity: DietaryRestriction.Severity) -> some View {
        DietaryChipFlow(spacing: 8) {
            ForEach(terms, id: \.self) { term in
                let isOn = store.contains(term: term)
                Button {
                    if isOn { store.remove(term: term) } else { store.add(term: term, severity: severity) }
                } label: {
                    HStack(spacing: 4) {
                        if isOn { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                        Text(term)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(isOn ? (severity == .cannot ? Color.red : Color.orange) : Color(.tertiarySystemFill)))
                    .foregroundStyle(isOn ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private var impliedSummary: [(label: String, terms: [String])] {
        profileDietaryCSV
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .compactMap { tag in
                DietaryRestrictionStore.impliedTermsByTag[tag].map { ($0.label, $0.terms) }
            }
    }

    // MARK: Actions

    private func addTyped() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        store.add(term: term, severity: newSeverity)
        newTerm = ""
        termFieldFocused = true
    }

    private func delete(_ offsets: IndexSet, from list: [DietaryRestriction]) {
        for index in offsets { store.remove(list[index]) }
    }
}

// MARK: - Edit sheet

private struct DietaryRestrictionEditSheet: View {
    @State var restriction: DietaryRestriction
    @Environment(\.dismiss) private var dismiss
    private let store = DietaryRestrictionStore.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ingredient", text: $restriction.term)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Treat as", selection: $restriction.severity) {
                        ForEach(DietaryRestriction.Severity.allCases) { severity in
                            Text(severity.title).tag(severity)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    TextField("Note (optional)", text: $restriction.note, axis: .vertical)
                        .lineLimit(1...3)
                } footer: {
                    Text("For you only — e.g. “anaphylaxis”, “migraines”, “Lent”.")
                }
                Section {
                    Button("Remove", role: .destructive) {
                        store.remove(restriction)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.update(restriction)
                        dismiss()
                    }
                    .disabled(restriction.term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Flag card (shared by product card, scan sheets, editor preview)

/// "Contains peanuts — you said you can't eat this." Red for a hard "can't",
/// amber for a preference. Lists every matching rule, blocking ones first.
struct DietaryFlagCard: View {
    let flags: [DietaryFlag]
    var compact: Bool = false

    private var isBlocking: Bool { flags.contains(where: \.isBlocking) }
    private var tint: Color { isBlocking ? .red : .orange }

    var body: some View {
        if !flags.isEmpty {
            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                HStack(spacing: 8) {
                    Image(systemName: isBlocking ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(tint)
                    Text(isBlocking ? "Not safe for you" : "Heads up")
                        .font(compact ? .subheadline.weight(.semibold) : .headline)
                        .foregroundStyle(tint)
                }
                ForEach(flags) { flag in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(flag.headline)
                            .font(.subheadline.weight(.medium))
                        Text(flag.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(compact ? 10 : 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(tint.opacity(0.35), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Quick picks for first-run setup

/// The allergen chips on their own, for the profile setup screen: a
/// one-screen way to get the most important rules in before first use.
struct DietaryQuickPicks: View {
    @ObservedObject private var store = DietaryRestrictionStore.shared

    var body: some View {
        DietaryChipFlow(spacing: 8) {
            ForEach(DietaryRestrictionStore.commonAllergens, id: \.self) { term in
                let isOn = store.contains(term: term)
                Button {
                    if isOn { store.remove(term: term) } else { store.add(term: term, severity: .cannot) }
                } label: {
                    HStack(spacing: 4) {
                        if isOn { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                        Text(term)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(isOn ? Color.red : Color(.tertiarySystemFill)))
                    .foregroundStyle(isOn ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Flow layout

/// Wraps chips onto as many lines as needed.
struct DietaryChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    NavigationStack { DietaryRestrictionsView() }
}
