# Phase 2 — dual write

Applied 2 August 2026. Follows `PHASE1_MODEL_LAYER.md`.

Unlike Phase 1, **Phase 2 is live** — it runs on device. But it is purely additive: the
JSON files remain the source of truth, the managers' public behaviour is unchanged, and
every Core Data path is wrapped so it cannot fail into the app.

**Not compiled** — no Xcode toolchain here. Build before shipping.

---

## Files

| File | Change |
|---|---|
| `CoreDataMirror.swift` | **new** — actor: one-time import + debounced mirror |
| `FrydgeManager.swift` | mirror hooks in `saveStoredIngredientsToFile`, `updateUserPhotos` |
| `ShoppingListManager.swift` | mirror hooks in `saveToFile`, `updateUserPhotos` |
| `FrydgeRecipesApp.swift` | `runCoreDataImport()` at launch and after foreground pull |
| `CoreDataMapping.swift` | bug fix (below) |

---

## How it works

Both managers already funnel every mutation through a single save function, which made
this a two-line hook rather than an audit of every call site:

```
FrydgeManager       …any mutation… ──► saveStoredIngredientsToFile() ──► JSON (truth)
                                                                    └──► CoreDataMirror
ShoppingListManager …any mutation… ──► saveToFile()                 ──► JSON (truth)
                                                                    └──► CoreDataMirror
```

`CoreDataMirror` is an `actor`, debounces 1s, and reconciles the **whole array**:

- every item present → `upsert` by UUID, then `apply(includingPhotos: false)`
- every active Core Data row **absent** from the array → `softDelete()`

Whole-array reconciliation is what makes deletes work. The managers delete by removing
from the array and saving, so absence is the only signal available.

**Photos are mirrored separately**, only from `updateUserPhotos`. With external binary
storage, comparing photo blobs faults every one of them into memory — doing that on every
save would mean reading ~10 MB per keystroke on a fridge with 20 photographed items.

### One-time import

`importIfNeeded(fridge:shopping:)` seeds Core Data from the managers' in-memory arrays
rather than re-reading the JSON files. That deliberately avoids duplicating the user-ID
scoping and `_local` migration logic fixed in Phase 0 — the managers have already done
that work correctly by the time it runs.

Three guards:

- flag `didImportIntoCoreData_v1` — stops after one success
- **won't burn the flag on empty input**, so a user whose managers haven't finished loading
  doesn't end up with an empty import marked done
- runs again after the foreground cloud pull, in case the launch attempt happened before
  `appleUserID` resolved

Idempotent regardless — everything upserts by UUID, so a repeat run is a no-op.

---

## Safety contract

This is the part that matters, given the store is new and unproven:

| Property | How |
|---|---|
| Cannot throw into the app | every entry point non-throwing; all `try` contained in the `write` closure |
| Cannot block the UI | `actor` + `newBackgroundContext()` + `try await context.perform` |
| No-op when store is broken | `PersistenceController.shared.isDegraded` short-circuits every call |
| Kill switch | `UserDefaults` key `coreDataMirrorDisabled` — set true to disable, no rebuild |
| Never touches existing data | writes only to Core Data; never mutates JSON files or the in-memory arrays |

If Core Data fails entirely, the app behaves exactly as it did after Phase 0.

Verified: no `try!`, no `fatalError`, no `as!` in any of the three new files; all throwing
calls contained; brace/paren/bracket balance clean across all six touched files.

---

## Two bugs found in my own Phase 1 code

Worth calling out, because both would have caused real damage:

**1. `context.hasChanges` was the wrong dirty check.** `apply(...)` ended with:

```swift
if context.hasChanges { updatedAt = Date() }
```

`context.hasChanges` is true if *any* object in the context is dirty — not this one. During
a bulk reconcile, as soon as one row changed, every subsequent row would get its `updatedAt`
stamped, marking it dirty, and **pushing the entire fridge to CloudKit on every single save**.
Now uses the object-level `hasPersistentChangedValues`.

**2. `withCheckedContinuation` around `context.perform` replaced.** The original was correct
(exactly one resume per path) but fragile — a future edit adding an early return would
double-resume or leak, and both crash. Now uses the `async` `context.perform`, which cannot
be misused that way.

---

## What is now true

- Every fridge and shopping-list mutation lands in Core Data within ~1s.
- Deletes propagate as soft deletes with a real `deletedAt`.
- Photos land as separate rows with external storage.
- **CloudKit is mirroring this data** — assuming the schema has been deployed (see below).

## What is still true

The old sync layer is still the one driving the UI, so its remaining bugs are still live:

- **P0-4** shopping list whole-list last-writer-wins
- **P0-5** 7-day tombstone expiry
- **P1-2 / P1-3 / P1-4** no subscriptions, default zone, discarded query cursor

These die in Phase 3.

---

## ⚠️ Still required before this does anything for real users

From Phase 1, unchanged and now urgent — Phase 2 is actually writing data:

1. Debug build, correct team → call `PersistenceController.shared.initializeCloudKitSchema()`
2. CloudKit Console → **Deploy Schema to Production**

Without this, Core Data still works locally but the CloudKit half silently does nothing.

---

## Suggested test pass

1. Launch with an existing fridge → check log for `Imported N fridge / M shopping items`.
2. Relaunch → import does **not** run again.
3. Add an item, wait 2s, kill the app, relaunch → still present in Core Data.
4. Delete an item → its row has `deletedAt` set, not a hard delete.
5. Delete then re-add the same item → row un-deletes rather than duplicating.
6. Set `coreDataMirrorDisabled = true` → app behaves exactly as pre-Phase-2.
7. Fresh install, empty state → flag stays unset, no empty import recorded.
8. Photo add/remove → photo rows appear/disappear; editing a *name* doesn't touch photos.

---

## Next: Phase 3 — cutover

1. `FrydgeManager` / `ShoppingListManager` become thin façades over
   `NSFetchedResultsController`, keeping their current public API so
   `ShoppingListView` and the other views need no changes.
2. Delete `syncToCloud`, `syncFromCloud`, `pendingSyncIDs`, the tombstone machinery,
   `pushToCloud`, `scheduleRetry` — roughly 600 lines of the hardest code in the app.
3. Keep writing the App Group `UserDefaults` snapshot for the widget.
4. Reverse the truth direction: Core Data becomes the source, JSON becomes the backup.

Phase 3 is the one that actually changes user-visible behaviour, so it wants a real device
test pass and probably a TestFlight round before it goes near the App Store.
