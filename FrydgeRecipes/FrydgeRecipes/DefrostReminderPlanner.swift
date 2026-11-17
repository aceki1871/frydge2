//
//  DefrostReminderPlanner.swift
//  FrydgeRecipes
//
//  "Take the chicken out of the freezer" reminders.
//
//  Cross-references the weekly meal plan (WeekPlanStore) with what's currently
//  in the freezer: when a planned recipe uses an ingredient that lives in the
//  freezer, a local notification is scheduled for the evening before the meal
//  so the item can thaw overnight. If the evening before has already passed,
//  the reminder falls back to the morning of the meal day.
//
//  refresh() rebuilds every pending defrost notification from scratch, so it
//  is safe (and expected) to call it whenever the plan or the fridge changes.
//

import Foundation
@preconcurrency import UserNotifications

@MainActor
enum DefrostReminderPlanner {

    nonisolated static let requestPrefix = "frydge.defrost."

    /// Hour of the evening-before reminder (19:00) and the same-day fallback (08:00).
    nonisolated private static let eveningHour = 19
    nonisolated private static let morningHour = 8

    static func refresh() {
        let plans = WeekPlanStore.shared.plannedRecipes
        // Raw ingredients only: a frozen leftover isn't something you defrost
        // for a recipe, and its dish-style name would fuzzy-match too eagerly.
        let freezerItems = FrydgeManager.shared.storedIngredients.filter {
            $0.lifecycle == .fridge && $0.location.lowercased().contains("freez") && !$0.isExpired
        }

        let requests = buildRequests(plans: plans, freezerItems: freezerItems, now: Date())

        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            // Replace, don't accumulate: the plan or freezer may have changed
            // since these were scheduled.
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(requestPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            for request in requests {
                center.add(request) { error in
                    if let error {
                        print("[Defrost] Failed to schedule reminder: \(error)")
                    }
                }
            }
        }
    }

    // MARK: - Planning

    nonisolated static func buildRequests(
        plans: [PlannedRecipe],
        freezerItems: [StoredIngredient],
        now: Date
    ) -> [UNNotificationRequest] {
        guard !plans.isEmpty, !freezerItems.isEmpty else { return [] }

        var requests: [UNNotificationRequest] = []
        for plan in plans {
            guard let mealDay = nextOccurrence(of: plan.dayIndex, from: now) else { continue }

            let frozen = freezerItems.filter { item in
                plan.ingredients.contains { IngredientMatcher.matches(item.name, $0) }
            }
            guard !frozen.isEmpty else { continue }

            guard let fireDate = reminderDate(forMealDay: mealDay, now: now) else { continue }

            let names = frozen.map(\.name)
            let list = names.count <= 2
                ? names.joined(separator: " and ")
                : names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"

            let content = UNMutableNotificationContent()
            content.title = "Defrost for \(plan.recipeName)"
            content.body = "Take \(list) out of the freezer — you're cooking \(plan.recipeName) \(dayPhrase(forMealDay: mealDay, fireDate: fireDate))."
            content.sound = .default

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            // Stable per plan entry, so a rescheduled plan replaces its reminder.
            let id = "\(requestPrefix)\(plan.id.uuidString)"
            requests.append(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
        return requests
    }

    /// Next calendar date (start of day, today included) for a plan's weekday.
    /// PlannedRecipe uses 0 = Monday … 6 = Sunday; Calendar uses 1 = Sunday … 7 = Saturday.
    nonisolated private static func nextOccurrence(of dayIndex: Int, from now: Date) -> Date? {
        guard (0...6).contains(dayIndex) else { return nil }
        let calendar = Calendar.current
        let targetWeekday = ((dayIndex + 1) % 7) + 1
        let today = calendar.startOfDay(for: now)
        for offset in 0..<7 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            if calendar.component(.weekday, from: candidate) == targetWeekday {
                return candidate
            }
        }
        return nil
    }

    /// 19:00 the evening before the meal; if that has passed, 08:00 on the meal
    /// day; if that has passed too (meal is today, late in the day), one minute
    /// from now so the reminder still lands while it can help.
    nonisolated private static func reminderDate(forMealDay mealDay: Date, now: Date) -> Date? {
        let calendar = Calendar.current
        if let eveningBefore = calendar.date(byAdding: .day, value: -1, to: mealDay),
           let evening = calendar.date(bySettingHour: eveningHour, minute: 0, second: 0, of: eveningBefore),
           evening > now {
            return evening
        }
        if let morning = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: mealDay),
           morning > now {
            return morning
        }
        if calendar.isDate(mealDay, inSameDayAs: now) {
            return calendar.date(byAdding: .minute, value: 1, to: now)
        }
        return nil
    }

    nonisolated private static func dayPhrase(forMealDay mealDay: Date, fireDate: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(mealDay, inSameDayAs: fireDate) { return "today" }
        if let dayAfterFire = calendar.date(byAdding: .day, value: 1, to: fireDate),
           calendar.isDate(mealDay, inSameDayAs: dayAfterFire) {
            return "tomorrow"
        }
        let weekdayIndex = (calendar.component(.weekday, from: mealDay) + 5) % 7
        return "on \(PlannedRecipe.dayNames[weekdayIndex])"
    }
}
