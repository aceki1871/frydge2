# Phase 3a — fridge cutover

Applied 2 August 2026. Follows `PHASE2_DUAL_WRITE.md`.

**Scope call:** I did the **fridge only**, not both managers. Phase 3 changes the source of
truth, has no fallback, and I cannot compile here. Splitting it halves the blast radius and
gives you a reviewable unit. `ShoppingListManager` is untouched and still runs the Phase 2
dual-write, so the shopping list behaves exactly as it did yesterday. Phase 3b does it.

**Not compiled.** This is the first phase that changes user-visible behaviour. Build it,
then test on two real devices before it goes near TestFlight.

---

## What happened

`FrydgeManager.swift`: **1,312 → 994 lines.** 318 lines of the hardest code in the app deleted.

Gone:

- `CKRecord` push and pull, `makeRecord`, `pushToCloud`
- the per-device `UserDefaults` tombstone dictionary — `tombstone`, `untombstone`,
  `isTombstoned`, `pruneOldTombstonesIfNeeded`, `shouldSkipCloudRecord`,
  `flushTombstonesToCloud`, `loadDeletionTombstones`, `saveDeletionTombstones`
- `pendingSyncIDs`, `debouncedSyncTask`, `scheduleDebouncedSync`, `runPendingSync`
- `scheduleRetry`, `consecutiveSyncFailures`, `mergeRetryDelay` (my own Phase 0 work — its
  job is now done by CloudKit)
- the full-table `CKQuery` with the discarded cursor
- `deleteRecordCompat` and its dead `#available(iOS 15.0)` branch
- every `NetworkMonitor.isNetworkAvailable()` gate

Added, roughly 90 lines:

```
mutation ──► storedIngredients ──► saveStoredIngredientsToFile()
                                     ├─► writeThroughToStore()   ← source of truth
                                     └─► writeBackupJSON()       ← rollback only

NSPersistentStoreRemoteChange ──debounce 300ms──► reloadFromStore()
                                                   └─► storedIngredients
```

- `writeThroughToStore()` — upserts present items, **soft-deletes absent ones**
- `reloadFromStore()` — the only path that refreshes the array from persistence
- `startObservingRemoteChanges()` — CloudKit merges now reach the UI with no manual pull
- `writePhotosThroughToStore(id:photos:)` — photos as separate external-storage rows

### No feedback loop

Worth being explicit, since it's the obvious way this design goes wrong:
`reloadFromStore()` calls `writeBackupJSON()`, **not** `saveStoredIngredientsToFile()`.
If it called the latter it would write straight back into the store, trigger another remote
change, and spin. The two paths are deliberately separate functions.

---

## Public API: unchanged

Every signature external callers use is preserved, so `FridgeView`, `ShoppingListView` and
the rest needed **zero changes**:

| Method | Now does |
|---|---|
| `syncFromCloud()` | re-reads the store (CloudKit keeps it current) |
| `syncStoredIngredientsToCloud()` | write-through |
| `syncDirtyToCloud(pushAll:)` | write-through |
| `enqueueCloudSync(for:)` | no-op — already persisted |
| `loadStoredIngredientsFromFile()` | Core Data first, JSON only if store is empty |
| `deleteItem/deleteSelected/clearAll` | remove from array + persist → soft delete |

All 34 methods verified present; codebase-wide scan for references to deleted symbols came
back clean.

---

## Bugs this actually kills

| | Was | Now |
|---|---|---|
| **P0-5** | deletes resurrected after 7 days | `deletedAt` is a synced fact; no expiry |
| **P1-2** | no push; only refreshed on `onAppear` | `NSPersistentStoreRemoteChange` observer |
| **P1-3** | default zone, no change tokens | container manages its own zone + tokens |
| **P1-4** | query cursor discarded, >100 items never fully synced | no query; incremental sync |
| **P0-3** | failed writes silently dropped | durable offline queue |
| **P2-1** | `NetworkMonitor` race gating every sync | gates removed from this path entirely |

**Deleting while offline now works and stays deleted.** That was structurally impossible before.

---

## Still outstanding

- **P0-4** shopping list whole-list last-writer-wins — untouched, waiting on Phase 3b.
- `NetworkMonitor` is still a data race for its remaining callers (`ShoppingListManager`,
  `SharedFrydgeManager`). Fewer callers now, same bug.
- `SharedFrydgeManager` / `SharedShoppingListManager` still use raw CloudKit. That's
  intentional — `CKShare` sharing is a different model and out of scope.

---

## ⚠️ Do this before running

The CloudKit schema step is no longer optional-until-later — **the fridge now depends on it**:

1. Debug build, correct team → `PersistenceController.shared.initializeCloudKitSchema()`
2. CloudKit Console → **Deploy Schema to Production**

Without it the fridge works locally but syncs nothing, and there is no longer an old
CKRecord path underneath to cover for it.

A rollback safety net does exist: `storedIngredients_<userID>.json` is still written on
every save, so reverting this commit restores the old behaviour with data intact.

---

## Test pass — do these on two real devices, same Apple ID

1. Add on A → appears on B **without opening the fridge screen** (this is new).
2. Delete on A while **B is offline** → bring B online → stays deleted. Wait 8+ days if you
   can stomach it; that's the P0-5 case.
3. Edit the *name* on A and the *quantity* on B simultaneously → both survive (property-level merge).
4. Airplane mode, add 5 items, force-quit, reconnect → all 5 sync.
5. Photo round-trip; then rename the item → photo unaffected.
6. Upgrade path: install the old build, add items, install this build → log shows
   `Seeded N fridge items into Core Data`, nothing lost.
7. 200+ items → all present on a fresh device (the P1-4 case).
8. Leftovers: add, set portions, let expire, `purgeExpiredLeftovers`.

---

## Next: Phase 3b — shopping list

Same treatment for `ShoppingListManager`: write-through, remote-change reload, delete
`syncToCloud`/`syncFromCloud` and the whole-list `CKAsset` blob. Keeps the App Group
`UserDefaults` snapshot so the widget and Live Activity are unaffected.

That kills P0-4, the last remaining P0.

Honest recommendation: **build and device-test Phase 3a before I do 3b.** If something in
the fridge cutover is wrong, you want to find it in one manager, not two.
