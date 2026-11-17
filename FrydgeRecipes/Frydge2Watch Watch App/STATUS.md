# Watch app status: dormant

Recorded 2 November 2026 (repair plan, workstream G).

The Swift sources in this folder and in `Recipes.Frydge2Watch Watch App/` are
**not members of any target** in `FrydgeRecipes.xcodeproj`. The project's
targets are: `FrydgeRecipes`, `FrydgeRecipesLiveActivityExtension`,
`listwidgetExtension`, `ShareViewController`,
`ShoppingListNotificationExtension`, plus the two test bundles. No watchOS
target exists, so this code is not built, not signed and not shipped.

What the phone still does for a paired Watch: `WatchDataSender` pushes an
application context (remaining item count, estimated total, nearest store)
via WatchConnectivity whenever the shopping list is saved. Since 2 Nov 2026
that summary is derived from `WidgetSnapshot.estimatedTotal`, the same
quantity / currency / ticked-item logic the widgets use. Nothing receives it
unless a Watch app is installed.

Decision required before release: either

1. re-add a watchOS target that compiles these sources, adopt
   `WidgetSnapshot` as its data model, and put it through the acceptance
   matrix; or
2. leave it dormant and remove the sources from the shipped archive review.

Until that decision, treat this folder as reference code only.
