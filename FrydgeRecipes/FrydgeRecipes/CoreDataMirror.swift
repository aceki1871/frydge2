//
//  CoreDataMirror.swift
//  FrydgeRecipes
//
//  ⚠️ SUPERSEDED — SAFE TO DELETE THIS FILE.
//
//  This held the Phase 2 dual-write scaffolding: a one-time JSON→Core Data
//  importer plus a debounced mirror that kept a Core Data copy in step behind the
//  JSON files while they were still the source of truth.
//
//  Phase 3a/3b made Core Data the source of truth directly:
//    * FrydgeManager and ShoppingListManager now read and write it themselves
//    * each seeds itself from its own JSON backup on first launch after upgrade
//      (`seedFromBackupJSON()`), so the shared importer is redundant
//    * leaving the importer live would be actively harmful — it could write a
//      stale snapshot over the live store
//
//  The one piece still needed — purging soft-deleted rows past the retention
//  window — moved to CoreDataHousekeeping.swift.
//
//  The file has been emptied rather than removed so it compiles as a no-op.
//  Delete it from the project when convenient; nothing references it.
//
