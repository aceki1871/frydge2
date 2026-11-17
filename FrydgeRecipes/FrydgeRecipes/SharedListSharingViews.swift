//
//  SharedListSharingViews.swift
//  FrydgeRecipes
//
//  The shopping-list sharing flow, redone as glass:
//    • `CreateSharedListSheet` — name + emoji picker + who-it's-for presets,
//      with a two-step strip ("Name it → Invite people") so the user knows
//      the system share sheet comes next.
//    • `SharedListCardHeader` — the header row of each shared list card on
//      the Shopping List screen: emoji tile, name, role/items line, a people
//      button that opens management, and the expand chevron.
//
//  Management itself (members, permissions, rename, stop sharing, leave) is
//  the native `ShareManagementSheet`, the same one shared frydges use.
//

import SwiftUI
import CloudKit

// MARK: - Create sheet

struct CreateSharedListSheet: View {
    @Binding var name: String
    @Binding var emoji: String
    let isCreating: Bool
    let onCreate: () -> Void
    let onCancel: () -> Void

    @FocusState private var nameFocused: Bool

    private static let emojiChoices: [String] = [
        "🛒", "🏠", "👨‍👩‍👧", "🧑‍🤝‍🧑", "🍳", "🥗", "🎉", "🏕️", "🏖️", "🎂",
        "🍕", "🥡", "🧁", "🍷", "🧺", "🐶", "👶", "🏃", "💪", "🎄"
    ]

    private static let presets: [(name: String, emoji: String)] = [
        ("Weekly shop", "🛒"), ("Household", "🏠"), ("Family", "👨‍👩‍👧"),
        ("Flatmates", "🧑‍🤝‍🧑"), ("Party", "🎉"), ("Road trip", "🏕️")
    ]

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    hero
                    stepStrip
                    emojiPicker
                    nameField
                    presetChips
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("New Shared List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isCreating)
                }
            }
            .safeAreaInset(edge: .bottom) {
                createButton
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { nameFocused = true }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 84, height: 84)
                Text(emoji.isEmpty ? "🛒" : String(emoji.prefix(1)))
                    .font(.system(size: 44))
            }
            .glassEffect(.regular, in: Circle())
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: emoji)

            Text(trimmedName.isEmpty ? "Shop together" : trimmedName)
                .font(.title2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text("One list, everyone's phone. Add, tick off and see prices live.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    /// "1 Name it  →  2 Invite people" so the system share sheet that follows
    /// isn't a surprise.
    private var stepStrip: some View {
        HStack(spacing: 10) {
            stepPill(number: 1, title: "Name it", active: true)
            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
            stepPill(number: 2, title: "Invite people", active: false)
        }
        .frame(maxWidth: .infinity)
    }

    private func stepPill(number: Int, title: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(active ? .white : .secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(active ? Color.blue : Color(.tertiarySystemFill)))
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(active ? .primary : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
    }

    private var emojiPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick an icon")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.emojiChoices, id: \.self) { choice in
                        let selected = String(emoji.prefix(1)) == choice
                        Button {
                            emoji = choice
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            Text(choice)
                                .font(.system(size: 24))
                                .frame(width: 46, height: 46)
                                .background(
                                    Circle().fill(selected ? Color.blue.opacity(0.18) : Color(.secondarySystemGroupedBackground))
                                )
                                .overlay(
                                    Circle().strokeBorder(selected ? Color.blue : Color.clear, lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Icon \(choice)")
                        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(emoji.isEmpty ? "🛒" : String(emoji.prefix(1)))
                    .font(.title3)
                TextField("e.g. Weekly shop", text: $name)
                    .font(.body.weight(.medium))
                    .textInputAutocapitalization(.words)
                    .focused($nameFocused)
                    .submitLabel(.go)
                    .onSubmit { if !trimmedName.isEmpty && !isCreating { onCreate() } }
                    .disabled(isCreating)
                if !name.isEmpty {
                    Button {
                        name = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear name")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var presetChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick picks")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.presets, id: \.name) { preset in
                        Button {
                            name = preset.name
                            emoji = preset.emoji
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            HStack(spacing: 6) {
                                Text(preset.emoji)
                                Text(preset.name)
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var createButton: some View {
        Button(action: onCreate) {
            HStack(spacing: 8) {
                if isCreating {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "person.badge.plus")
                }
                Text(isCreating ? "Creating…" : "Create & Invite")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(.white)
        }
        .buttonStyle(.glassProminent)
        .tint(.blue)
        .disabled(trimmedName.isEmpty || isCreating)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
        .accessibilityHint("Creates the list, then opens the invite sheet")
    }
}

// MARK: - Card header

/// Header row for one shared list card on the Shopping List screen.
struct SharedListCardHeader: View {
    let emoji: String
    let name: String
    let isOwner: Bool
    let itemCount: Int
    let totalText: String?
    /// Items the store the shopper is in doesn't sell (in-store mode only).
    var notHereCount: Int = 0
    let isExpanded: Bool
    let isLoading: Bool
    let onOpenManage: () -> Void
    let onToggleExpand: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Tapping the identity opens members / sharing.
            Button(action: onOpenManage) {
                HStack(spacing: 12) {
                    Text(emoji)
                        .font(.system(size: 24))
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(Color.blue.opacity(0.12)))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if isLoading {
                                ProgressView().scaleEffect(0.7)
                            }
                        }
                        HStack(spacing: 6) {
                            Label(isOwner ? "You own this" : "Shared with you",
                                  systemImage: isOwner ? "crown.fill" : "person.2.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(isOwner ? Color.orange : Color.blue)
                                .labelStyle(.titleAndIcon)
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(itemCount) item\(itemCount == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let totalText, !totalText.isEmpty {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(totalText)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            if notHereCount > 0 {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("\(notHereCount) not here")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityLabel("\(name), \(isOwner ? "you own this" : "shared with you"), \(itemCount) items")
            .accessibilityHint("Opens members and sharing")

            // People / invite shortcut.
            Button(action: onOpenManage) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glass)
            .disabled(isLoading)
            .accessibilityLabel("Invite or manage people")

            Button(action: onToggleExpand) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 30, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.2), value: isExpanded)
            .accessibilityLabel(isExpanded ? "Collapse \(name)" : "Expand \(name)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
    }
}
