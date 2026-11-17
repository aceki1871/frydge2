# Phase 1 — model layer

Applied 2 August 2026. Follows `PHASE0_CHANGES.md`.

**Phase 1 is inert.** `PersistenceController.shared` is a lazy `static let` and nothing
references it yet, so none of this executes at runtime. The app behaves exactly as it did
after Phase 0. That is deliberate — it means Phase 1 can be built, inspected and committed
without risking user data, and Phase 2 turns it on.

**Not compiled** — no Xcode toolchain available here. Build before relying on it.

---

## Files

| File | Change |
|---|---|
| `FrydgeRecipesCoreData.xcdatamodel/Contents` | 3 new entities |
| `FrydgeRecipesCoreData.xcdatamodeld/.xccurrentversion` | new — pins the current model version |
| `PersistenceController.swift` | rewritten for `NSPersistentCloudKitContainer` |
| `CoreDataMapping.swift` | new — domain mapping + fetch helpers |

---

## 1. The model

Three entities added alongside the existing (still unused) `FrydgeRecipe`.

```
CDFridgeItem                     CDShoppingItem
  id            UUID               id            UUID
  name          String             name          String
  quantity      String             quantity      String
  unit          String             unit          String
  expirationDate Date              location      String
  location      String             dietaryTagsJSON String
  dietaryTagsJSON String           createdAt     Date
  lifecycleRaw  String             updatedAt     Date
  quantityUsed  Double             deletedAt     Date?   ← soft delete
  createdAt     Date               photos ──┐
  updatedAt     Date                        │
  deletedAt     Date?  ← soft delete        │
  photos ──┐                                │
           │                                │
           └──────► CDItemPhoto ◄───────────┘
                      id         UUID
                      data       Binary (external storage)
                      sortIndex  Int16
                      createdAt  Date
                      fridgeItem   ─► CDFridgeItem   (inverse: photos, Nullify)
                      shoppingItem ─► CDShoppingItem (inverse: photos, Nullify)
```

Three decisions worth flagging:

**Deletion is a synced fact.** `deletedAt: Date?` instead of a local tombstone. The old
design kept tombstones in `UserDefaults.standard` — per-device, never synced, pruned at
7 days — which is why deleted fridge items came back. A soft-delete row replicates through
CloudKit like any other change, so every device learns about it. `purgeSoftDeleted(olderThan:)`
hard-deletes rows after 30 days, by which point the delete has already propagated.

**Photos are their own entity with external binary storage.** Previously the entire
shopping list — including every base64 photo — was one JSON blob in one `CKAsset`, so
renaming one item re-uploaded every photo on every item. Now a photo is a separate row and
editing an item's name touches nothing else.

**`dietaryTags` is a JSON string, not a transformable.** `Set<String>` does not mirror to
CloudKit. Encoding is centralised in `DietaryTagCoding` and **sorted** before encoding, so
a set that hasn't semantically changed doesn't produce a byte-different string and a
spurious CloudKit write.

### CloudKit legality — verified

`NSPersistentCloudKitContainer` refuses to load the store at launch if the model breaks its
rules. Checked programmatically against the parsed model:

- every attribute is optional or has a default value — **pass**
- every relationship is optional and has a correctly paired inverse — **pass** (4/4 pairs)
- no uniqueness constraints — **pass**
- no `Deny` delete rules — **pass**

Because unique constraints are forbidden, uniqueness on `id` is enforced in code instead,
via `upsertFridgeItem(id:)` / `upsertShoppingItem(id:)`.

Also removed `usedWithSwiftData="YES"` from the model root. Nothing uses SwiftData, and
pointing both SwiftData and `NSPersistentCloudKitContainer` at one model is a known source
of trouble.

---

## 2. `PersistenceController`

Was 30 lines with a `fatalError`. Now:

- **`NSPersistentCloudKitContainer`**, private database scope, container
  `iCloud.com.Clark-Online.Recipe` (matches the existing entitlement — no provisioning change needed).
- **Store lives in the App Group container.** Nothing used Core Data before, so there is no
  migration cost, and it means the widget and extensions can read the store directly in a
  later phase instead of going through the three mirrored `UserDefaults` keys.
- **History tracking + remote change notifications** both enabled. These are mandatory —
  without the first, the store can't compute what to push; without the second, the UI never
  learns a pull landed. Omitting them is the most common reason "CloudKit sync doesn't work".
- **`fatalError` gone.** A failed load now logs and falls back to an in-memory store so the
  app launches instead of crashing, and sets `isDegraded` so Phase 2 knows not to run the
  migration against a broken store.
- **Merge policy `mergeByPropertyObjectTrump`.** A remote edit to `name` and a local edit to
  `quantity` on the same item both survive. This is exactly what the old whole-list design
  could not do.
- `newBackgroundContext()`, `saveIfNeeded(_:)`, and a `preview` controller for SwiftUI.
- `os.Logger` rather than `print` — first component in the app to have queryable logs.

---

## 3. `CoreDataMapping.swift`

Pure, side-effect-free mapping so Phase 3 can swap the store underneath `FrydgeManager` and
`ShoppingListManager` **without touching any view** — including the 3,487-line
`ShoppingListView`.

- `CDFridgeItem.toStoredIngredient()` / `.apply(_:includingPhotos:in:)`
- `CDShoppingItem.toShoppingListItem()` / `.apply(_:includingPhotos:in:)`
- `fetchRequestForActiveItems()` — filters `deletedAt == nil`
- `softDelete()`, `purgeSoftDeleted(olderThan:)`
- `upsertFridgeItem(id:)` / `upsertShoppingItem(id:)`

One detail that matters for cost: `apply(...)` **compares before assigning**. Core Data marks
a property dirty on any assignment, and a dirty property is a CloudKit write — so blind
assignment would push the entire fridge on every UI refresh. Same reasoning behind
`replacePhotos` bailing out when the bytes are unchanged.

---

## ⚠️ Required manual step before this works for real users

`NSPersistentCloudKitContainer` cannot create its CloudKit schema from a Release build.
You must, once:

1. Run a **Debug** build on a device signed with the right team.
2. Call `PersistenceController.shared.initializeCloudKitSchema()` (the `#if DEBUG` helper).
3. Open the **CloudKit Console** → `iCloud.com.Clark-Online.Recipe` → **Deploy Schema to Production**.

Skip this and sync silently does nothing in TestFlight and the App Store — no error, no
crash, just no data moving. It is the single most common way this migration goes wrong.

Note the new record types (`CD_CDFridgeItem`, `CD_CDShoppingItem`, `CD_CDItemPhoto`) sit
alongside your existing `StoredIngredient` / `UserShoppingList` types. Nothing is
overwritten, which is what makes the Phase 2 dual-write approach safe.

---

## What is still true after Phase 1

Phase 1 changes no runtime behaviour, so every sync bug from the review that Phase 0 didn't
fix is still live:

- **P0-4** shopping list whole-list last-writer-wins — still drops concurrent edits
- **P0-5** 7-day tombstone expiry — deletes still resurrect
- **P1-2** no push subscriptions on personal data
- **P1-3** records still in the default zone
- **P1-4** query cursor still discarded, so >100 items never fully sync

These die in Phase 3 when the managers cut over.

---

## Next: Phase 2 — dual-write migration

1. One-time import: read `storedIngredients_<userID>.json` and `shoppingList_<userID>.json`
   into Core Data via the upsert helpers; set a `didMigrateToCoreData` flag.
2. Keep writing the App Group `UserDefaults` snapshot — the widget pipeline is fine and
   should survive untouched.
3. Keep the existing CKRecord layer readable for one release, so a user mid-upgrade across
   two devices doesn't lose data.
4. Guard the whole thing on `!PersistenceController.shared.isDegraded`.

Say the word and I'll start it.
