# Frydge 2.0 — Full Code Review

**Reviewed:** 2 August 2026
**Scope:** `FrydgeRecipes.xcodeproj` — 266 Swift files, ~51,750 LOC, 6 targets
**Review basis:** static reading of source, project file, entitlements, plists, CloudKit call sites. No build or runtime execution.

Every claim below cites `file:line`. Where I could not verify something without running the app, it is marked **[needs runtime check]**.

---

## 1. Verdict up front

The app works, and a lot of it is thoughtfully written — the tombstone logic, the per-user file scoping, the widget snapshot pipeline all show someone who has been bitten before and reacted. But the sync layer is a hand-built distributed database, and it has the failure modes hand-built distributed databases always have. There are **four independent silent data-loss paths** and **one guaranteed crash** in the code that persists the shopping list.

**On the iCloud sync question:** do not repair the current CloudKit layer. Migrate the fridge and shopping list to `NSPersistentCloudKitContainer`. Reasoning in §7.

Severity counts:

| | Count |
|---|---|
| P0 — crash or silent data loss | 6 |
| P1 — feature broken / App Store risk | 7 |
| P2 — architecture & correctness | 9 |
| P3 — hygiene | 6 |

---

## 2. System map

### 2.1 Targets

| Target | Bundle ID | Entitlements |
|---|---|---|
| FrydgeRecipes (app) | `Clark-Online.Recipes` | CloudKit, App Group, Sign in with Apple, APNs, Apple Pay, associated domains, ubiquity-KVS, private-cloud-compute |
| listwidgetExtension | `…​.listwidget` | App Group only |
| FrydgeRecipesLiveActivityExtension | `…​.FrydgeRecipesLiveActivity` | App Group only |
| ShoppingListNotificationExtension | `…​.ShoppingListNotificationExtension` | App Group, APNs |
| ShareViewController | `…​.ShareViewController` | App Group only |
| Frydge2Watch Watch App | — | **no entitlements file at all** |

Build config: Swift language mode **5.0**, `SWIFT_APPROACHABLE_CONCURRENCY = YES`, `objectVersion = 100` (Xcode 16+ synchronized file groups). Deployment targets are inconsistent across targets: **18.0, 26.0 and 26.5** all appear.

Dependencies: SwiftSoup, stripe-ios-spm, stripe-terminal-ios. All pinned via SPM. No CocoaPods/Carthage.

### 2.2 Where data actually lives

This is the core of the problem. **Fridge and shopping-list state has four concurrent homes with no single owner:**

```
                    ┌─────────────────────────────────┐
                    │  @Published in-memory arrays    │
                    │  FrydgeManager.storedIngredients│
                    │  ShoppingListManager.items      │
                    └────────────┬────────────────────┘
                                 │ writes fan out on every mutation
          ┌──────────────────────┼──────────────────────┬─────────────────┐
          ▼                      ▼                      ▼                 ▼
 ┌─────────────────┐  ┌────────────────────┐  ┌──────────────────┐  ┌───────────┐
 │ JSON file       │  │ App Group          │  │ CloudKit         │  │ Widget    │
 │ Documents/ or   │  │ UserDefaults       │  │ private DB       │  │ Snapshot  │
 │ AppGroup dir    │  │ (3 separate keys)  │  │ default zone     │  │ (4th key) │
 └─────────────────┘  └────────────────────┘  └──────────────────┘  └───────────┘
```

Concretely:

| Data | In-memory | Disk | App Group UD | CloudKit |
|---|---|---|---|---|
| Fridge items | `FrydgeManager.storedIngredients` | `Documents/storedIngredients_<userID>.json` | — | `StoredIngredient` records, **default zone**, private DB |
| Shopping list | `ShoppingListManager.shoppingListItems` | `<AppGroup>/shoppingList_<userID>.json` | `shoppingList_structured_v1_<userID>`, `shoppingListItemsJSON`, `shoppingList` | one `UserShoppingList` record named `"ShoppingList"`, **CKAsset blob**, default zone |
| Deletion tombstones | `deletionTombstones` dict | — | `UserDefaults.standard` key `frydge_deletedTombstones_<userID>` | **never synced** |
| Legacy string lists | `ingredients` | `Documents/ingredients_<userID>.json` | — | — |

There is a **fifth** store that is entirely dead: Core Data. `FrydgeRecipesCoreData.xcdatamodeld` defines exactly one entity (`FrydgeRecipe`); `PersistenceController.swift` is referenced by nothing outside itself; there are **zero** uses of `@FetchRequest`, `NSManagedObject` or `managedObjectContext` in the codebase.

### 2.3 CloudKit topology

Container `iCloud.com.Clark-Online.Recipe`. Nine record types across all three databases:

| Record type | DB | Zone |
|---|---|---|
| `StoredIngredient` | private | default |
| `UserShoppingList` | private | default |
| `Recipe`, `RecipeIngredient`, `RecipePan`, `Pan`, `VendorProduct`, `InviteResponse` | public | default |
| `ShareAnchor`, `LeftoverNotice` | private + shared | custom zones |

**The shared-fridge feature is architecturally ahead of the personal one.** `SharedFrydgeManager` and `SharedShoppingListManager` use custom zones and register `CKRecordZoneSubscription` / `CKQuerySubscription` (`SharedFrydgeManager.swift:949, 977, 1031`; `SharedShoppingListManager.swift:859, 915, 967`). The user's *own* fridge and shopping list have **no subscriptions at all** and live in the default zone. That inversion is the root cause of most of §4.

---

## 3. P0 — Crash and silent data loss

### P0-1 · Infinite recursion in the shopping list save path → stack overflow crash

`FrydgeRecipes/ShoppingListManager.swift:462–472`

```swift
private func saveToFile() {
    do {
        let data = try JSONEncoder().encode(shoppingListItems)
        try data.write(to: localFileURL())
    } catch {
        saveToFile()                      // ← calls itself, unconditionally
        saveShoppingListToUserDefaults()
        refreshWidgetSnapshots()
    }
}
```

The `catch` block retries by calling itself with no attempt limit, no backoff, and no change in conditions. Any persistent write failure produces unbounded recursion and a stack-overflow crash on the main actor.

This is not theoretical. The file is written into the **App Group container**, which is subject to data protection. Realistic triggers:

- device locked while the notification extension or Live Activity mutates the list (`ShoppingListManager` is constructed in extension contexts via the app group)
- disk full
- App Group container unavailable (provisioning/entitlement mismatch after a profile change)

Each of those makes `data.write(to:)` throw *every* time, so the recursion never terminates.

**Fix:** delete the recursive call. Log, set a `needsSave` flag, retry on next foreground.

```swift
private func saveToFile() {
    do {
        let data = try JSONEncoder().encode(shoppingListItems)
        try data.write(to: localFileURL(), options: [.atomic])
        pendingDiskSave = false
    } catch {
        pendingDiskSave = true
        logger.error("shopping list save failed: \(error.localizedDescription)")
    }
}
```

---

### P0-2 · Every fridge-item photo is destroyed on the next cloud sync

Three facts combine:

1. `saveOrUpdateIngredientToCloud` writes eight fields to the `CKRecord` — `name`, `quantity`, `unit`, `expirationDate`, `location`, `dietaryTags`, `lifecycle`, `quantityUsed`. It does **not** write `userPhotoData` (`FrydgeManager.swift:657–684`).
2. `syncFromCloud` reconstructs `StoredIngredient` from those same eight fields (`FrydgeManager.swift:697–735`). `userPhotoData` defaults to `[]` (`FrydgeManager.swift:134`).
3. The merge then **overwrites** the local object wholesale:

```swift
// FrydgeManager.swift:745–747
for cloud in cloudItems {
    if pendingSyncIDs.contains(cloud.id) { continue }
    mergedByID[cloud.id] = cloud          // ← local item, with photos, replaced
}
```

A user photographs an item. The record is saved to CloudKit without the photo. On the next `syncFromCloud()` — triggered simply by opening `FridgeView` (`FridgeView.swift:202`) — the photo-less cloud copy replaces the local copy, and `saveStoredIngredientsToFile()` writes the loss to disk permanently.

Confirmed by grep: `record["userPhoto…"]` appears **nowhere** in the codebase.

**Fix (short term):** preserve local-only fields during merge.

```swift
for cloud in cloudItems {
    if pendingSyncIDs.contains(cloud.id) { continue }
    var merged = cloud
    merged.userPhotoData = mergedByID[cloud.id]?.userPhotoData ?? []
    mergedByID[cloud.id] = merged
}
```

**Fix (correct):** photos must not live in the record at all. Write them as `CKAsset`s, or better, keep them out of the sync model entirely and reference them by ID.

---

### P0-3 · Failed cloud writes are dropped from the dirty set and never retried

`FrydgeManager.swift:605–618`

```swift
let ids = pendingSyncIDs
pendingSyncIDs.removeAll()               // ← cleared before any write succeeds
itemsToSync = storedIngredients.filter { ids.contains($0.id) }

for item in itemsToSync {
    if isTombstoned(item.id) { continue }
    saveOrUpdateIngredientToCloud(item)   // ← fire and forget
}
```

And the write itself (`FrydgeManager.swift:672–683`):

```swift
operation.modifyRecordsResultBlock = { result in
    switch result {
    case .success: print("[CK] Saved ingredient: \(item.name)")
    case .failure(let error): print("[CK ERROR] \(item.name): …")   // ← that's all
    }
}
```

The dirty set is emptied *synchronously*, before the asynchronous operation reports back. On failure — throttling, `.networkFailure` mid-flight, quota, `.serverRecordChanged` — the item is no longer in `pendingSyncIDs`, so nothing will ever push it again. The change is on this device only, forever, with a `print` as the sole record.

This is made near-certain by P1-2: one `CKModifyRecordsOperation` **per item**. A `syncStoredIngredientsToCloud()` (`pushAll: true`) on a 150-item fridge fires 150 separate operations back to back, which CloudKit will rate-limit with `CKError.requestRateLimited`. Those items are then silently dropped.

**Fix:** only remove IDs from `pendingSyncIDs` on confirmed success; batch into a single `CKModifyRecordsOperation`; honour `CKErrorRetryAfterKey`; handle `.serverRecordChanged` explicitly.

---

### P0-4 · Whole-list last-writer-wins destroys concurrent shopping-list edits

`ShoppingListManager.swift:597–648`. The entire list is one record, `"ShoppingList"`, with a JSON blob in a `CKAsset`. Pull logic:

```swift
guard cloudUpdatedAt > localUpdatedAt else { return }   // line 632
```

Then push replaces the whole asset.

Walk through a normal two-device day:

| t | iPhone | iPad | Server |
|---|---|---|---|
| T1 | — | adds *bread*, pushes | `[bread]`, updatedAt=T1 |
| T2 | offline, adds *milk* | — | `[bread]` |
| T3 | comes online, pulls | — | `cloudUpdatedAt(T1) > localUpdatedAt(T2)` is **false** → pull skipped |
| T4 | pushes `[milk]` | — | `[milk]` — **bread is gone** |

Bread is deleted from both devices with no error, no conflict UI, no trace. The comment on line 631 says the guard exists to "prevent stale cloud data from overwriting local deletes" — it does that, and in exchange it silently discards every remote addition made while this device was offline.

Compounding it, the push uses `privateDB.save(record)`, whose default policy is `.ifServerRecordUnchanged`. Concurrent writes therefore throw `.serverRecordChanged` — and the catch block is:

```swift
} catch {
    // best-effort            ← line 620
}
```

So the *other* failure mode is that the write silently does nothing.

**Fix:** per-item records with per-item timestamps, so two devices adding two different items merge instead of colliding. This falls out for free under `NSPersistentCloudKitContainer`.

---

### P0-5 · Deleted items resurrect after 7 days

Tombstones are stored in `UserDefaults.standard` (`FrydgeManager.swift:252–262`), which is **per-device, never synced**, and pruned after `tombstoneRetentionDays = 7` (`FrydgeManager.swift:250, 278–290`).

Sequence: iPhone deletes *eggs* → tombstone written on iPhone only → CloudKit delete succeeds → iPad, which has *eggs* in its local `storedIngredients_<userID>.json` and no tombstone, calls `syncStoredIngredientsToCloud(pushAll: true)` → *eggs* is re-uploaded → iPhone pulls it back.

Before day 7, iPhone's tombstone blocks it at `FrydgeManager.swift:705` and the item is only invisible on the iPhone (already wrong — it is live on the iPad). After day 7 the tombstone is pruned and *eggs* returns on every device.

The three "IMPORTANT: do not untombstone here" comments (`FrydgeManager.swift:1107, 1147`) show this was diagnosed and patched around rather than fixed. The patch cannot work, because deletion is not a fact the local device can hold alone.

**Fix:** deletion must be a synced fact — a soft-delete flag on a synced record, or a tombstone record type in CloudKit. `NSPersistentCloudKitContainer` handles this natively.

---

### P0-6 · Fridge data leaks between iCloud accounts on a shared device

`FrydgeManager.swift:202–206`

```swift
private var userID: String {
    if let v = UserDefaults.standard.string(forKey: "appleUserID"), !v.isEmpty { return v }
    return "local"                     // ← shared across all users of this device
}
```

Compare `ShoppingListManager.swift:112–131`, which solves exactly this with an `installScopedID`, and explicitly documents why:

> `/// Prevents "local" bucket being shared across different iCloud users on the same device.`

`FrydgeManager` never got the same treatment. Before `appleUserID` resolves — first launch, iCloud signed out, network unavailable, or a CloudKit hiccup — all fridge state reads and writes `storedIngredients_local.json`. User A's fridge is visible to User B on a family iPad.

There is also a **migration gap**: `loadStoredIngredientsFromFile` (`FrydgeManager.swift:796–819`) migrates from the unscoped legacy `storedIngredients.json`, but **not** from `storedIngredients_local.json`. Items written during the pre-resolution window are orphaned on disk the moment `appleUserID` resolves.

**Fix:** copy `ShoppingListManager`'s `installScopedID` pattern into `FrydgeManager`, and add a `_local` → `_<userID>` migration.

---

## 4. P1 — Broken features and App Store risk

### P1-1 · Background sync cannot run — the identifiers are not declared

`AppDelegateWrapper.swift:262–270` registers two background tasks:

```swift
BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.Clark-Online.Recipes.refresh", …)
BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.Clark-Online.Recipes.processing", …)
```

`BGTaskSchedulerPermittedIdentifiers` does **not** exist in `FrydgeRecipes/Info.plist` (verified: zero occurrences), and there is no corresponding `INFOPLIST_KEY_` build setting.

`UIBackgroundModes` contains only `location` and `remote-notification` (`Info.plist`) — **`fetch` and `processing` are both absent**, so `BGAppRefreshTaskRequest` cannot be honoured even if the identifiers were declared.

The code already knows. `AppDelegateWrapper.swift:111–116` is a diagnostic that prints *"No BGTaskSchedulerPermittedIdentifiers found in Info.plist"* — a check that has been failing since it was written.

Registering an undeclared identifier raises `NSInternalInconsistencyException` on some OS versions and is a hard `submit()` failure on others. **[needs runtime check]** — but either way, background refresh is dead, and `scheduleAppRefresh()`'s `catch` just prints.

### P1-2 · No CloudKit subscriptions for the user's own data

Verified by exhaustive grep: `CKSubscription` / `CKQuerySubscription` / `CKRecordZoneSubscription` appear only in `SharedFrydgeManager`, `SharedShoppingListManager` and `NotificationDiagnosticView`. Neither `StoredIngredient` nor `UserShoppingList` has one.

Combined with `FrydgeRecipesApp.swift:303–307`, where the `scenePhase == .active` handler calls **only** `drainWidgetTicks()` and not `syncFromCloud()`, the actual sync trigger surface is:

- `FridgeView.swift:202, 280` — on appear / pull-to-refresh
- `ShoppingListView.swift:1266, 1272, 1346` — on appear / pull-to-refresh

That is it. Add an item on your iPhone; your iPad shows it only when you next navigate to that specific screen. There is no push, no background pull, no foreground pull.

### P1-3 · Records are in the default zone, so incremental sync is structurally impossible

`FrydgeManager.swift:660` and `ShoppingListManager.swift:600` both construct `CKRecord.ID(recordName:)` with no `zoneID` — the default zone.

The default zone does not support `CKFetchRecordZoneChangesOperation`, which means **change tokens cannot be used**, which means every sync is a full-table `CKQuery` scan. It also cannot be shared via `CKShare`.

`ProfileView.swift:910` and `:982` query zones named `"ShoppingListZone"` and `"FrydgeFridgeZone"`:

```swift
let zoneID = CKRecordZone.ID(zoneName: "FrydgeFridgeZone", ownerName: CKCurrentUserDefaultName)
let (matches, _) = try await privateDB.records(matching: query, inZoneWith: zoneID)
```

Nothing anywhere writes to those zones. These queries return empty forever. **[needs runtime check on what UI depends on them]**

### P1-4 · The full-fetch query discards its cursor — large fridges never fully sync

`FrydgeManager.swift:689–691`

```swift
let query = CKQuery(recordType: "StoredIngredient", predicate: NSPredicate(value: true))
let results = try await privateDB.records(matching: query)
// results.queryCursor is never read
```

`records(matching:)` returns at most `CKQueryOperation.maximumResults` (~100 by default) plus a cursor. The cursor is dropped. A fridge with more than one page of items will pull only the first page. Because the merge is a union, the missing items are not deleted locally — but they will never arrive on a fresh device, so **a new device restores a partial fridge and shows no error**.

This also requires `recordName` to be marked queryable in the CloudKit schema; if the index is missing in Production the query throws and lands in the `catch` at line 761, which prints and returns. **[needs runtime check against the Production schema]**

### P1-5 · Privacy manifest declares nothing, while the app collects a lot

`PrivacyInfo.xcprivacy` in full:

```xml
<key>NSPrivacyTracking</key>        <false/>
<key>NSPrivacyCollectedDataTypes</key>  <array/>
<key>NSPrivacyTrackingDomains</key>     <array/>
<key>NSPrivacyAccessedAPITypes</key>    <array/>
```

All four are empty. The app in fact:

- stores the user's **email address and name** (`appleEmail`, `appleGivenName`, `appleFamilyName` in UserDefaults)
- requests **precise background location** (`UIBackgroundModes: location`, always-usage description present)
- captures **photos** (camera and photo library)
- processes **payments** via Stripe and Stripe Terminal

and uses at least two required-reason API categories that must be declared:

| API | Category |
|---|---|
| `UserDefaults` | `CA92.1` |
| File timestamp (`Data(contentsOf:)`, `FileManager` attributes) | `C617.1` / `0A2A.1` |

An empty `NSPrivacyCollectedDataTypes` alongside this is an inaccurate privacy declaration, and the missing required-reason declarations trigger automated App Store Connect rejection (ITMS-91053).

### P1-6 · Purpose strings are placeholders

From `project.pbxproj`:

```
INFOPLIST_KEY_NSCameraUsageDescription      = "take pictures of food (AI)"
INFOPLIST_KEY_NSPhotoLibraryUsageDescription = "store pictures or upload"
INFOPLIST_KEY_NSLocationAlwaysUsageDescription = "finding shops"
INFOPLIST_KEY_NSLocationUsageDescription    = "Notifications access"
INFOPLIST_KEY_NSNearbyInteractionUsageDescription = testing
```

`"testing"` is shipping to users. App Review guideline 5.1.1 requires purpose strings that clearly explain the use; these are sentence fragments and one is a literal placeholder. `NSLocationUsageDescription = "Notifications access"` is actively misleading.

### P1-7 · Two competing sources of Info.plist truth

The main app sets `INFOPLIST_FILE = FrydgeRecipes/Info.plist`, and *also* defines ~19 `INFOPLIST_KEY_*` build settings. `NSLocationWhenInUseUsageDescription` is defined in **both**, with different text:

- Info.plist: *"Frydge uses your location to show nearby stores on the marketplace map and sort them by distance."*
- Build setting: *"Allow notifications to get updates when near a store."*

Which one reaches the user depends on Xcode's merge behaviour for the toolchain in use. Pick one mechanism. **[needs runtime check — inspect the built `.app`'s Info.plist]**

---

## 5. P2 — Architecture and correctness

### P2-1 · `NetworkMonitor` is a data race and gates every sync

`NetworkMonitor.swift` in full is 30 lines, and it is load-bearing — `isNetworkAvailable()` is the first guard in `syncDirtyToCloud`, `runPendingSync`, `flushTombstonesToCloud`, `deleteItem`, `deleteSelected`, `clearAll`, `ShoppingListManager.syncToCloud`.

```swift
class NetworkMonitor {                          // not Sendable, not an actor
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    private init() {
        monitor.pathUpdateHandler = { path in … }
        monitor.start(queue: queue)
    }

    func isNetworkAvailable() -> Bool {
        monitor.currentPath.status == .satisfied   // read from @MainActor callers
    }
}
```

Three problems:

1. **Race.** `currentPath` is mutated on the private queue and read from the main actor with no synchronisation. Under Swift 6 strict concurrency this is a hard error; today it is a latent race.
2. **Cold start returns `false`.** `NWPathMonitor.start(queue:)` is asynchronous; `currentPath.status` is not `.satisfied` until the first path update lands. The first sync attempt after launch is therefore skipped. Because `runPendingSync` returns early *and the debounced task has already been consumed*, nothing retries — the pending IDs sit until the user happens to mutate something else. Add one item at launch and background the app, and it may never reach CloudKit.
3. **Cross-singleton init off-main.** `pathUpdateHandler` calls `Networking.shared.syncOfflineRecipes()` from the monitor queue, forcing lazy initialisation of another singleton on a background thread.

Also: gating on reachability at all is the wrong shape. CloudKit already queues and retries; the correct pattern is to attempt the operation and handle `CKError.networkUnavailable`.

**Fix:** make it an `actor`, or expose an `AsyncStream`, and delete the reachability guards from the CloudKit paths.

### P2-2 · Core Data is dead weight sitting exactly where the fix belongs

`PersistenceController.swift` is 30 lines, referenced by nothing, containing:

```swift
container.loadPersistentStores { storeDescription, error in
    if let error = error as NSError? {
        fatalError("Unresolved error \(error), \(error.userInfo)")   // line 23
    }
}
```

`fatalError` on store load is the standard Xcode template and is wrong for shipping code — a corrupt or migration-failed store crashes the app on launch with no recovery. It is currently harmless only because nothing constructs it.

The model has one entity (`FrydgeRecipe`). This is the natural landing zone for the migration in §7.

### P2-3 · Non-atomic writes to the primary local stores

`FrydgeManager.swift:790` — `try data.write(to: url)`
`ShoppingListManager.swift:465` — `try data.write(to: localFileURL())`

Neither passes `.atomic`. A kill mid-write (backgrounding, jetsam, crash) truncates the file, and the next `JSONDecoder().decode` throws. In `FrydgeManager` that lands in the `catch` at line 799, tries the legacy file, and prints an error — the fridge silently comes back empty.

Notably, 14 *other* write sites in the codebase **do** use `.atomic` (`RecipeListModel.swift:195`, `ProductImageCacheManager.swift:169`, `StockAvailability.swift:205`, etc.). The two most important files are the two that don't.

### P2-4 · Whole-list photo blobs re-uploaded on every keystroke

`ShoppingListItem.userPhotoData: [Data]` (`ShoppingListManager.swift:16`) is encoded inline in the JSON that becomes the `CKAsset`. Sync is debounced at 1.5s (`ShoppingListManager.swift:665`), so adding one item re-serialises and re-uploads **every photo on every item**. With ten photographed items at ~500 KB each that is a 5 MB upload per edit.

### P2-5 · `savePolicy = .changedKeys` on a freshly-constructed record is a blind overwrite

`FrydgeManager.swift:661, 671`

```swift
let record = CKRecord(recordType: "StoredIngredient", recordID: recordID)  // no recordChangeTag
…
operation.savePolicy = .changedKeys
```

A newly constructed `CKRecord` carries no `recordChangeTag`, so there is no server-record comparison to make — every key is "changed". This is effectively `.allKeys` with no conflict detection: a concurrent edit from another device is overwritten without a `.serverRecordChanged` error ever being raised.

### P2-6 · Duplicated manager hierarchies

`FrydgeManager` (1,152 lines) and `SharedFrydgeManager` (1,046 lines) independently implement `deleteItem`, `adjustedExpiryDate`, `daysFromToday`, `loadItems`. `ShoppingListManager` (671) and `SharedShoppingListManager` (1,034) both implement `refreshWidgetSnapshots`. Expiry-shelf-life logic in particular is duplicated verbatim, so the two fridges will drift.

Only the *Shared* variants got zones and subscriptions. The personal ones are the older, worse copy.

### P2-7 · Oversized view files

| File | Lines | Nested `var body` |
|---|---|---|
| `ShoppingListView.swift` | 3,487 | 12 view structs in one file |
| `RecipeDetailView.swift` | 1,986 | |
| `RecipeListView.swift` | 1,574 | |
| `RecipeEditorView.swift` | 1,376 | |
| `ProfileView.swift` | 1,319 | |

`ShoppingListView.swift` also contains CloudKit calls (`privateCloudDatabase`, `sharedCloudDatabase`, zone manipulation at line 985) — persistence logic living inside a view file. Same in `ProductDetailsView.swift:1127–1142`, which writes records directly into a shared zone.

### P2-8 · Errors are swallowed at scale

- 218 `try?` expressions
- 30+ `catch` blocks whose entire body is `// best-effort` or `// ignore`
- 559 `print()` calls and no `os.Logger` anywhere

The `print`s are the only diagnostic signal, and they do not exist in Release builds' unified log in any queryable form. When a user reports "my list lost an item", there is no way to find out why.

### P2-9 · Dead availability branches

`FrydgeManager.swift:939` and `:1027` — `if #available(iOS 15.0, *)` with a `deleteRecordCompat` continuation fallback, against a deployment target of 18.0. The fallback path (`FrydgeManager.swift:1055–1067`) is unreachable.

---

## 6. P3 — Hygiene

1. **Deployment targets diverge across targets: 18.0 / 26.0 / 26.5.** Any target on 26.x cannot be installed by a user whose main app target allows 18.0. Unify.
2. **The Watch App has no entitlements file** — no App Group, so it cannot read shared state.
3. **Backend source likely ships inside the app bundle.** With `PBXFileSystemSynchronizedRootGroup` and the only membership exception being `Info.plist`, the `.js` and `.toml` files sitting in `FrydgeRecipes/` (`cloudflare-worker-stripe-payments.js`, `cloudflare-worker-recipe-sharing.js`, `stripe-backend-configured.js`, `wrangler.toml`, `wrangler-stripe.toml`) are non-source files inside a synchronized group and will be copied as bundle resources. No secrets are exposed — the Stripe keys are correctly Wrangler secrets, confirmed in `wrangler-stripe.toml:11–13` — but the server logic is readable by anyone who unzips the IPA. **[needs runtime check — inspect the built `.app`]** Move them out of the target folder.
4. **`http://localhost:3000` in shipping code.** `QuickStripeSetup.swift:88, 211, 216, 242` — a dev backend toggle reachable in a release build.
5. **iCloud Drive is corrupting the git repository.** There is a `.git 2/` directory containing a duplicate `objects/` tree, and an `oldzips 2/` folder — classic iCloud Drive conflict artifacts. Git repos should not live in iCloud Drive; iCloud's dataless-file eviction also broke `git` entirely during this review (`.git/HEAD` was unreadable). Move the working copy to a local path and push to a real remote.
6. **Credentials sitting in the working tree.** `APNCertificates.p12` and `AuthKey_7XKRGZRVQD.p8` are at the repo root. `.gitignore:26–27` correctly excludes `*.p12` and `*.p8`, and I confirmed neither appears in `.git/index` — so they are **not tracked**. But they are in an iCloud-synced folder, which is a different exposure. Move them to a password manager and rotate the APNs key if it has ever been shared.

### Good news worth stating

- **No hardcoded secrets in Swift.** An exhaustive scan for `apiKey|secret|token|Bearer|sk_live|sk_test|pk_live|AIza` assigned to string literals returned zero hits.
- **No cleartext HTTP to production endpoints** and no ATS exceptions.
- **Only 2 `as!` casts, 0 `try!`, 1 `fatalError`** across 51,750 lines. That is unusually disciplined.
- **33 Swift Testing cases exist and do run** — `GroceryMatchingTests.swift` (32 `@Test`) and `FrydgeRecipesTests.swift` (1). I initially flagged these as excluded from the test target; that was wrong. The project uses Xcode 16 synchronized file groups (`objectVersion = 100`), so files are included by folder membership, not by individual `pbxproj` entries. Retracted.
- The shared-fridge implementation is genuinely well built — custom zones, zone subscriptions, per-list query subscriptions. The fix for the personal fridge is largely to bring it up to that standard.

---

## 7. Recommendation on iCloud sync

You asked me to review first and then advise. Here is the advice.

### Migrate to `NSPersistentCloudKitContainer`. Do not repair the current layer.

The current design needs, at minimum: a custom record zone, zone change tokens, a `CKDatabaseSubscription` with push, a durable operation queue with retry and `CKErrorRetryAfterKey` handling, `.serverRecordChanged` conflict resolution, synced tombstones, asset externalisation for photos, and cursor-based pagination. That is roughly what `NSPersistentCloudKitContainer` is — you would be reimplementing it, in an app that already has four sources of truth and no tests around any of them.

The counter-argument is real and worth naming: `NSPersistentCloudKitContainer` gives you less control, no server-side validation, awkward schema migration, and it will not help the *public* database work (`Recipe`, `VendorProduct`, marketplace) which must stay on raw CloudKit. So this is a migration for `StoredIngredient` and `UserShoppingList` **only** — the two record types with the data-loss bugs.

The second counter-argument: shared fridges currently work via `CKShare` on custom zones, and `NSPersistentCloudKitContainer` sharing (`share(_:to:)`) is a different, more constrained model. If the shared-fridge feature is central to the product, scoping the migration to the *personal* fridge and shopping list only — and leaving `SharedFrydgeManager` on raw CloudKit — is the pragmatic split.

### Sequencing

**Phase 0 — stop the bleeding (do this first, independent of direction)**

These are small, surgical, and each fixes a live data-loss path:

1. Delete the recursive `saveToFile()` call. *(P0-1, one line)*
2. Preserve `userPhotoData` across the merge in `syncFromCloud`. *(P0-2, three lines)*
3. Only clear `pendingSyncIDs` on confirmed success. *(P0-3)*
4. Add `.atomic` to both file writes. *(P2-3, two lines)*
5. Give `FrydgeManager` the `installScopedID` treatment. *(P0-6)*
6. Add `BGTaskSchedulerPermittedIdentifiers` + `fetch`/`processing` background modes, or delete the `BGTaskScheduler` code. *(P1-1)*
7. Fill in the privacy manifest and rewrite the purpose strings. *(P1-5, P1-6)*

**Phase 1 — model layer**

Define `CDFridgeItem` and `CDShoppingItem` `NSManagedObject`s in the existing (currently unused) `FrydgeRecipesCoreData` model. Give both a `deletedAt: Date?` for soft-delete, and store photos as external binary attributes with `allowsExternalBinaryDataStorage`. Wire `PersistenceController` to `NSPersistentCloudKitContainer` with `.private` scope — and replace that `fatalError` with a recoverable path.

**Phase 2 — dual-write migration**

On first launch after upgrade: read the existing JSON files, insert into Core Data, mark migrated. Keep writing the app-group UserDefaults snapshot for the widget (that layer is fine and should survive). Keep the CKRecord layer readable for one release so users mid-upgrade across devices don't lose data.

**Phase 3 — cut over**

`FrydgeManager` / `ShoppingListManager` become thin façades over `NSFetchedResultsController`, keeping their existing public API so the 3,487-line `ShoppingListView` doesn't need to change. Delete `syncToCloud`, `syncFromCloud`, the tombstone machinery, `pendingSyncIDs`, and the debounce. That is roughly 600 lines of the hardest code in the app, deleted.

**Phase 4 — verify**

Two physical devices, same Apple ID. Test matrix: add/edit/delete on each while the other is offline; airplane-mode edits on both then reconnect; delete on A while B is offline for 8+ days (the P0-5 case); fresh install restore; 200+ items (the P1-4 pagination case); photo round-trip (the P0-2 case).

---

## 8. Suggested order of work

| Priority | Item | Effort |
|---|---|---|
| Now | P0-1 recursion crash | minutes |
| Now | P0-2 photo destruction | minutes |
| Now | P2-3 atomic writes | minutes |
| Now | P0-3 dirty-set clearing | ~1 hour |
| Now | P0-6 user scoping + `_local` migration | ~2 hours |
| This week | P1-5 / P1-6 privacy manifest + purpose strings | ~2 hours |
| This week | P1-1 background task declarations (or removal) | ~1 hour |
| This week | P3-5 get the repo out of iCloud Drive | ~30 min |
| Next | Phase 1–3 `NSPersistentCloudKitContainer` migration | 2–3 weeks |
| Ongoing | Split `ShoppingListView.swift`; move CloudKit out of views | incremental |
| Ongoing | Replace `print` with `os.Logger`; stop swallowing errors | incremental |

---

## 9. What I could not verify

Stated plainly, so nothing here reads as more certain than it is:

- **No build was run.** Compile errors, warnings, and Swift 6 diagnostics are unassessed.
- **The CloudKit Production schema was not inspected.** P1-4's queryable-index assumption and the existence of the `FrydgeFridgeZone` / `ShoppingListZone` zones need checking in the CloudKit Console.
- **`BGTaskScheduler` behaviour with undeclared identifiers** varies by OS version; I have asserted the feature is broken, not the precise failure mode.
- **Info.plist merge precedence** (P1-7) and **bundle resource inclusion** (P3-3) both need confirming against a built `.app`.
- I reviewed the sync layer, security surface, build config and data model in depth. The recipe import pipeline, grocery-provider scrapers, Stripe/marketplace flow, and the widget/Live Activity extensions had a lighter pass — happy to go deep on any of those next.
