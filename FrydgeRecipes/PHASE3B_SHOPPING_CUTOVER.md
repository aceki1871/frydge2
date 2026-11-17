# Phase 3b — shopping list cutover

Applied 2 August 2026. Follows `PHASE3A_FRIDGE_CUTOVER.md`.

**This closes the last P0.** Every finding from `CODE_REVIEW_2026-08.md` rated P0 is now
either fixed or structurally impossible.

**Not compiled.** I did this before you reported back on the 3a device test — worth knowing,
because if 3a has a problem, 3b almost certainly shares it. Build and test both together.

---

## What happened

`ShoppingListManager.swift`: 700 → 764 lines (the sync code deleted was dense; the
replacement is longer but does less).

Deleted:

- the whole-list **`CKAsset` blob**. The entire list — every item, every photo — was one
  JSON blob in one CKRecord named `"ShoppingList"`
- `localUpdatedAt` / `localRevisionKey` revision tracking
- the `guard cloudUpdatedAt > localUpdatedAt else { return }` that caused **P0-4**
- the 1.5s debounced `syncToCloud()` Combine sink
- `privateDB`, `recordType`, all `CKRecord` handling
- `NetworkMonitor` gating

Added, mirroring 3a: `writeThroughToStore()`, `reloadFromStore()`,
`startObservingRemoteChanges()`, `writePhotosThroughToStore(id:photos:)`,
`seedFromBackupJSON()`.

### The loop this design invites, and how it's blocked

`ShoppingListManager` has something `FrydgeManager` doesn't: a Combine sink on
`$shoppingListItems` that saves on **every** change. With a remote-change observer also
assigning to that array, the two feed each other:

```
remote change → reloadFromStore() → assigns array → sink fires → saveToFile()
             → writeThroughToStore() → store changes → remote change → …
```

Blocked with an `isApplyingRemoteChange` flag. `applyWithoutPersisting(_:)` raises it,
assigns, refreshes the widget snapshot, lowers it; the sink checks it and bails. This was
the single most likely way for this phase to go wrong.

---

## P0-4 is dead

The old failure, from the review:

| t | iPhone | iPad | Server |
|---|---|---|---|
| T1 | — | adds *bread*, pushes | `[bread]` |
| T2 | offline, adds *milk* | — | `[bread]` |
| T3 | online, pulls → **skipped** (local newer) | — | `[bread]` |
| T4 | pushes `[milk]` | — | `[milk]` — **bread gone** |

Now each item is its own row with its own `deletedAt`. *bread* and *milk* are unrelated
records; there is no whole-list revision to compare and nothing to overwrite. Both survive.

---

## Widget pipeline: untouched

Deliberately. The App Group `UserDefaults` snapshot (`shoppingListItemsJSON`, the legacy
`shoppingList` array, and `WidgetSnapshot`) is what the widget, Live Activity and
notification extension read. That layer was never the problem, so it still runs on every
save — 31 references intact. `drainWidgetTicks()` is unchanged.

---

## Phase 2 scaffolding retired

`CoreDataMirror` was the dual-write bridge. Both managers now seed themselves from their
own JSON backup, so the shared importer is not just redundant but **harmful** — it could
write a stale snapshot over the live store. Removed from the launch path.

The one piece still wanted (purging soft-deleted rows past retention) is now
`CoreDataHousekeeping.swift`.

`CoreDataMirror.swift` has been **emptied to comments** rather than deleted — you declined
the delete permission, which is fine. It compiles as a no-op and nothing references it.
**Please remove it from the project in Xcode when convenient.**

---

## Full P0 status

| | Finding | Status |
|---|---|---|
| P0-1 | `saveToFile` infinite recursion | fixed, Phase 0 |
| P0-2 | photos destroyed on sync | fixed Phase 0; now structural (separate rows) |
| P0-3 | failed writes silently dropped | fixed Phase 0; now CloudKit's durable queue |
| P0-4 | whole-list last-writer-wins | **fixed, Phase 3b** |
| P0-5 | deletes resurrect after 7 days | fixed, Phase 3a |
| P0-6 | fridge leaks across iCloud accounts | fixed, Phase 0 |

Remaining from the review, all lower severity:

- **P2-1** `NetworkMonitor` is still a data race — but no longer gates any sync path.
  Callers left: `SharedFrydgeManager`, `SharedShoppingListManager`, `Networking`.
- **P2-6** `SharedFrydgeManager` / `SharedShoppingListManager` still hand-rolled CloudKit.
  Intentional — `CKShare` is a different model, out of scope.
- **P2-7** `ShoppingListView.swift` still 3,487 lines.
- **P2-8** 559 `print` calls; the new files use `os.Logger`.

---

## ⚠️ Before you run any of this

1. Debug build, correct team → `PersistenceController.shared.initializeCloudKitSchema()`
2. CloudKit Console → **Deploy Schema to Production**

Both the fridge and the shopping list now depend on it, and there is no old CKRecord path
left underneath to cover for it.

Rollback: both managers still write their JSON backups on every save, so reverting the
Phase 3 commits restores the old behaviour with data intact.

---

## Test pass — two real devices, same Apple ID

The P0-4 regression test first, since it's the whole point:

1. Add *bread* on A, let it sync. Put B in airplane mode. Add *milk* on B. Bring B online.
   → **both items present on both devices.** This failed before.
2. Tick an item off in the widget while the app is backgrounded → `drainWidgetTicks()` still applies it.
3. Delete on A while B is offline → stays deleted after B reconnects.
4. Edit quantity on A and unit on B simultaneously → both survive.
5. Add a photo to a list item, then rename the item → photo unaffected, not re-uploaded.
6. Upgrade path: old build → add items → install this build → log shows
   `Seeded N shopping items into Core Data`, nothing lost.
7. Watch for a refresh loop: add one item and confirm the store settles instead of
   continuously writing. If `isApplyingRemoteChange` is wrong, this is where it shows.
8. Live Activity and lock-screen widget still populate.

---

## What I'd do next, in order

1. **Build both cutovers and run the test matrix.** Everything above is unverified by a compiler.
2. Deploy the CloudKit schema.
3. TestFlight to yourself for a week before wider release — sync bugs surface over days, not minutes.
4. Then the cleanup backlog: `NetworkMonitor` as an actor, splitting `ShoppingListView`,
   `os.Logger` migration, and the `.git`-in-iCloud-Drive problem from P3-5.
