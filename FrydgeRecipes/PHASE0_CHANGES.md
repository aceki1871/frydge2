# Phase 0 — stop the bleeding

Applied 2 August 2026. Companion to `CODE_REVIEW_2026-08.md`.

Seven files touched. No behaviour changes beyond the fixes below; no public API removed.
**Not compiled** — there is no Xcode toolchain in this environment. Build before shipping.

---

## Swift changes

### `ShoppingListManager.swift`

**P0-1 — infinite recursion removed.** `saveToFile()` called itself in its own `catch`
with no attempt limit. Any persistent write failure (device locked while an extension
touches the App Group file, disk full, container unavailable) recursed until the stack
overflowed.

Now: writes `.atomic`, sets a `pendingDiskSave` flag on failure, logs, and returns.
New `retryPendingDiskSaveIfNeeded()` flushes it on next foreground.

```diff
-        } catch {
-            saveToFile()                    // recursed forever
+        } catch {
+            pendingDiskSave = true
+            print("[ERROR] Saving shopping list to file failed: …")
             saveShoppingListToUserDefaults()
             refreshWidgetSnapshots()
         }
```

**P2-3 — `.atomic`** added to the list write, so a kill mid-write can't truncate the file.

---

### `FrydgeManager.swift`

**P0-2 — photos no longer destroyed on sync.** `userPhotoData` is never written to the
CKRecord, so cloud items always arrive with an empty photo array; the merge assigned
`cloud` wholesale and `saveStoredIngredientsToFile()` persisted the loss. The overlay now
carries local-only fields forward:

```diff
 for cloud in cloudItems {
     if pendingSyncIDs.contains(cloud.id) { continue }
-    mergedByID[cloud.id] = cloud
+    var merged = cloud
+    if let local = mergedByID[cloud.id] { merged.userPhotoData = local.userPhotoData }
+    mergedByID[cloud.id] = merged
 }
```

**P0-3 — failed cloud writes are retried instead of dropped.** `pendingSyncIDs.removeAll()`
ran *before* the fire-and-forget write reported back, so any failure lost the change
permanently and silently. Restructured:

- `saveOrUpdateIngredientToCloud(_:)` (per-item, fire-and-forget) → **removed**
- `makeRecord(for:)` — builds the record only
- `pushToCloud(_:)` — batches into `CKModifyRecordsOperation` (300/batch, `atomically: false`),
  awaits results, returns the set of **server-confirmed** IDs plus any `CKErrorRetryAfterKey`
- `syncDirtyToCloud` — `pendingSyncIDs.subtract(saved)`; anything unsaved stays queued
- `scheduleRetry(after:)` — re-arms with exponential backoff, 30s → 300s cap, reset on success
- `runPendingSync()` — no longer duplicates the push loop; delegates to `syncDirtyToCloud`
- offline guard now re-arms a retry rather than silently dropping the queue

Side effect: a 150-item `pushAll` is now ~1 request instead of 150, so it stops
self-inflicting `requestRateLimited`.

**P0-6 — fridge no longer leaks between iCloud accounts.** `userID` fell back to the literal
`"local"`, so every account on a shared device read and wrote the same
`storedIngredients_local.json`. Replaced with an `installScopedID` (the pattern
`ShoppingListManager` already used and documented).

Added `migrateScopedCaches(...)`, which on user-ID resolution moves
`storedIngredients_*`, `ingredients_*` and the tombstone dictionary from the
install-scoped **and** historical `_local` buckets to the resolved per-user names.
Never clobbers an existing destination file.

**P2-3 — `.atomic`** added to `saveStoredIngredientsToFile()` and `saveItems(_:to:)`.

---

### `FrydgeRecipesApp.swift`

**Duplicate manager instances collapsed.** `@StateObject var frydgeManager = FrydgeManager()`
constructed a *second* fridge alongside `FrydgeManager.shared`, which `LeftoverManager` and
`RecipeShareIcon` already use. Two live instances, separate `storedIngredients` and
`pendingSyncIDs`, both writing the same JSON file and the same CloudKit records — last
writer won. Now `= FrydgeManager.shared`.

**Foreground sync added.** The `scenePhase == .active` handler only called
`drainWidgetTicks()`. It now also:

- `retryPendingDiskSaveIfNeeded()` — flushes a save that failed earlier
- pulls `frydgeManager.syncFromCloud()` and `shoppingListManager.syncFromCloud()`

Previously the *only* sync triggers were `FridgeView`/`ShoppingListView` `onAppear`, so a
change made on another device stayed invisible until you opened that exact screen.
This is a mitigation, not a fix — the real fix is push subscriptions (see below).

---

### `AppDelegateWrapper.swift`

Third throwaway `FrydgeManager()` inside the Live Activity drain → `FrydgeManager.shared`.

---

## Configuration changes

### `FrydgeRecipes/Info.plist`

**P1-1 — background tasks can now actually register.** `BGTaskScheduler.shared.register`
was being called for two identifiers that were declared nowhere.

```diff
 <key>UIBackgroundModes</key>
 <array>
+    <string>fetch</string>
     <string>location</string>
+    <string>processing</string>
     <string>remote-notification</string>
 </array>
+<key>BGTaskSchedulerPermittedIdentifiers</key>
+<array>
+    <string>com.Clark-Online.Recipes.refresh</string>
+    <string>com.Clark-Online.Recipes.processing</string>
+</array>
```

### `PrivacyInfo.xcprivacy`

**P1-5** — was four empty arrays. Now declares the four required-reason API categories
actually used (UserDefaults `1C8F.1`, File timestamp `C617.1`, Disk space `E174.1`,
System boot time `35F9.1`) and eight collected data types (email, name, user ID, precise
location, photos, audio, purchase history, other usage data) — all marked linked,
none marked tracking. This was an inaccurate privacy declaration and an automated
rejection (ITMS-91053) waiting to happen.

Verified the file is in the app target: `project.pbxproj:578` (Resources build phase).

### `FrydgeRecipes.xcodeproj/project.pbxproj`

**P1-6** — 16 replacements across Debug and Release, rewriting placeholder purpose strings:

| Key | Was | Now |
|---|---|---|
| `NSNearbyInteractionUsageDescription` | `testing` | full sentence |
| `NSCameraUsageDescription` | `"take pictures of food (AI)"` | full sentence |
| `NSPhotoLibraryUsageDescription` | `"store pictures or upload"` | full sentence |
| `NSLocationAlwaysUsageDescription` | `"finding shops"` | full sentence |
| `NSLocationUsageDescription` | `"Notifications access"` (misleading) | full sentence |
| `NSFaceIDUsageDescription` | `"SSO - Sign in automatically"` | full sentence |
| `NSLocationWhenInUseUsageDescription` | conflicted with Info.plist | now matches Info.plist exactly |
| `NSLocationAlwaysAndWhenInUseUsageDescription` | conflicted with Info.plist | now matches Info.plist exactly |

Backup of the original at `/tmp/pbxproj.bak` (sandbox — copy it out if you want it kept).
Structural validation after edit: braces 177/177, parens 122/122, quotes even,
`archiveVersion` and `rootObject` intact, no `;;`.

---

## Verification performed

- All three plists parse under `plistlib`.
- Brace / paren / bracket balance confirmed on all four Swift files with a
  comment- and string-aware scanner (the naive one false-positived on `//` inside URLs).
- No dangling references to the removed `saveOrUpdateIngredientToCloud`.
- Remaining `FrydgeManager()` call site is inside a `#Preview` — harmless.

**Not done:** no compile, no test run, no device testing. Please build before shipping.

---

## Deliberately left alone

- **`IngredientsDetailView.swift:6`** creates its own `ShoppingListManager()` instead of
  using the environment one — which would silently split the list. It has **zero call
  sites** and is dead code, so it is harmless today. Delete it or wire it to
  `@EnvironmentObject` before using it.
- **`NetworkMonitor`** is still a data race and still gates every sync (P2-1). The retry
  re-arming above blunts the cold-start symptom; the class still needs to become an actor.
- **Default-zone records, no change tokens, no subscriptions** (P1-2, P1-3) — structural,
  addressed by the `NSPersistentCloudKitContainer` migration, not by patching.
- **Whole-list last-writer-wins on the shopping list** (P0-4) — cannot be fixed without
  moving to per-item records. Still live. **This is the one remaining P0.**
- **7-day tombstone expiry** (P0-5) — deletes can still resurrect. Needs synced tombstones.

---

## Suggested test pass

1. Two devices, same Apple ID. Add on A, background/foreground B → item appears.
2. Photograph a fridge item, force a sync, reopen → **photo survives**.
3. Airplane mode, add three items, wait, restore network → all three reach CloudKit.
4. Kill the app mid-save repeatedly → list/fridge still decode on relaunch.
5. Fresh install on a device with a second iCloud account → no cross-account fridge.
6. Confirm launch logs now print permitted BG identifiers instead of the "not found" warning.
