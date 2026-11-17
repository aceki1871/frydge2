//
//  LeftoverReminderSheet.swift
//  FrydgeRecipes
//
//  Sheet shown when the user taps "Store leftovers" on the post-cook notification.
//  Lets the user set: portions remaining, days until expiry, and where to store.
//

import SwiftUI

struct LeftoverReminderSheet: View {

    let recipeName: String
    var onDismiss: (() -> Void)? = nil

    /// Items that were fully used up while cooking — offered as a restock suggestion.
    var restockSuggestions: [String] = []
    /// Called on store when the user keeps the restock suggestion ticked.
    var onRestock: (([String]) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = LeftoverManager.shared

    @State private var portions: Int = 2
    @State private var daysUntilExpiry: Int = 3
    @State private var destination: LeftoverItem.LeftoverDestination = .ownFridge
    @State private var isSaving = false
    @State private var addRestockToList = true
    @State private var hasUserAdjustedDays = false
    @State private var isApplyingDaysSuggestion = false
    @State private var suggestedDaysDish: String?

    private var expiryDate: Date {
        Calendar.current.date(byAdding: .day, value: daysUntilExpiry, to: Date()) ?? Date()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: "fork.knife")
                            .foregroundStyle(.orange)
                        Text(recipeName)
                            .font(.headline)
                    }
                } header: {
                    Text("Recipe")
                }

                Section {
                    Stepper("**\(portions)** portion\(portions == 1 ? "" : "s") left", value: $portions, in: 1...20)
                } header: {
                    Text("Portions remaining")
                } footer: {
                    Text("How many servings are going in the fridge?")
                }

                Section {
                    Stepper(daysLabel, value: $daysUntilExpiry, in: 1...30)
                    HStack {
                        Image(systemName: "calendar")
                            .foregroundStyle(.secondary)
                        Text("Bin by \(expiryDate.formatted(date: .abbreviated, time: .omitted))")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                } header: {
                    Text("Expiry")
                } footer: {
                    if suggestedDaysDish != nil {
                        Text("Suggested for \(recipeName). You'll get a reminder before this date.")
                    } else {
                        Text("You'll get a reminder before this date.")
                    }
                }

                Section {
                    ForEach(LeftoverItem.LeftoverDestination.allCases, id: \.self) { dest in
                        Button {
                            destination = dest
                        } label: {
                            HStack {
                                Image(systemName: dest.icon)
                                    .frame(width: 24)
                                    .foregroundStyle(destination == dest ? .orange : .secondary)
                                Text(dest.label)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if destination == dest {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.orange)
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Where are they going?")
                } footer: {
                    if destination == .sharedFridge {
                        Text("Your shared fridge members will be notified about these leftovers.")
                    }
                }

                if !restockSuggestions.isEmpty {
                    Section {
                        Toggle(isOn: $addRestockToList) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Add to shopping list")
                                    .font(.subheadline.weight(.medium))
                                Text(restockSuggestions.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Restock")
                    } footer: {
                        Text("These ran out while cooking — add them to your shopping list?")
                    }
                }
            }
            .navigationTitle("Store Leftovers")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: daysUntilExpiry) { _, _ in
                if !isApplyingDaysSuggestion { hasUserAdjustedDays = true }
            }
            .task {
                guard !hasUserAdjustedDays,
                      let days = await LeftoverKeepDaysAI.suggestDays(for: recipeName),
                      !hasUserAdjustedDays else { return }
                isApplyingDaysSuggestion = true
                daysUntilExpiry = days
                isApplyingDaysSuggestion = false
                suggestedDaysDish = recipeName
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") {
                        applyRestockIfNeeded()
                        dismiss()
                        onDismiss?()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Store") {
                        store()
                    }
                    .fontWeight(.semibold)
                    .disabled(isSaving)
                }
            }
        }
    }

    // MARK: - Helpers

    private var daysLabel: String {
        switch daysUntilExpiry {
        case 1:  return "Good for **1 day**"
        case 2:  return "Good for **2 days**"
        case 7:  return "Good for **1 week**"
        case 30: return "Good for **1 month** (frozen?)"
        default: return "Good for **\(daysUntilExpiry) days**"
        }
    }

    private func store() {
        isSaving = true
        let item = LeftoverItem(
            recipeName: recipeName,
            cookedDate: Date(),
            expiryDate: expiryDate,
            portionsRemaining: portions,
            destination: destination
        )
        manager.add(item)

        if destination == .sharedFridge {
            Task {
                await LeftoverManager.notifySharedFridgeMembers(leftover: item)
            }
        }

        // Schedule an expiry reminder 1 day before bin date.
        scheduleExpiryReminder(for: item)

        applyRestockIfNeeded()
        dismiss()
        onDismiss?()
    }

    private func applyRestockIfNeeded() {
        guard addRestockToList, !restockSuggestions.isEmpty else { return }
        onRestock?(restockSuggestions)
    }

    private func scheduleExpiryReminder(for item: LeftoverItem) {
        guard daysUntilExpiry > 1 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Leftover \(item.recipeName) expires soon"
        content.body  = "\(item.portionsRemaining) portion\(item.portionsRemaining == 1 ? "" : "s") left — use today or bin it."
        content.sound = .default
        content.categoryIdentifier = "EXPIRY_REMINDER"
        content.userInfo = ["name": item.recipeName]

        // Fire 1 day before expiry
        let reminderDate = Calendar.current.date(byAdding: .day, value: -1, to: item.expiryDate) ?? item.expiryDate
        guard reminderDate > Date() else { return }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour], from: reminderDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: "leftover.expiry.\(item.id)", content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("[Leftovers] Expiry reminder failed: \(error)") }
        }
    }
}

// MARK: - Leftover card used in FridgeView

struct LeftoverCard: View {
    let item: LeftoverItem
    let onConsume: (Int) -> Void   // pass updated portion count (0 = remove)
    let onDelete: () -> Void

    @State private var showingConsumeSheet = false
    @State private var portionsToConsume = 1

    var body: some View {
        SwipeToDeleteRow(onDelete: onDelete) {
            Button {
                portionsToConsume = 1
                showingConsumeSheet = true
            } label: {
                HStack(spacing: 12) {
                    // Expiry indicator
                    Circle()
                        .fill(indicatorColor)
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.recipeName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Image(systemName: item.destination.icon)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(item.portionsRemaining) portion\(item.portionsRemaining == 1 ? "" : "s") · \(item.expiryLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showingConsumeSheet) {
            ConsumeLeftoverSheet(
                item: item,
                portionsToConsume: $portionsToConsume,
                onConfirm: {
                    let remaining = item.portionsRemaining - portionsToConsume
                    onConsume(max(0, remaining))
                }
            )
            .presentationDetents([.medium])
        }
    }

    private var indicatorColor: Color {
        if item.isExpired              { return .red }
        if item.daysUntilExpiry <= 1   { return .orange }
        return .green
    }
}

// MARK: - Consume sheet

private struct ConsumeLeftoverSheet: View {
    let item: LeftoverItem
    @Binding var portionsToConsume: Int
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.recipeName).font(.headline)
                    Text("\(item.portionsRemaining) portion\(item.portionsRemaining == 1 ? "" : "s") available")
                        .foregroundStyle(.secondary)
                }
                Section("How many portions are you using?") {
                    Stepper("**\(portionsToConsume)** portion\(portionsToConsume == 1 ? "" : "s")",
                            value: $portionsToConsume, in: 1...item.portionsRemaining)
                }
            }
            .navigationTitle("Using leftovers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onConfirm(); dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
