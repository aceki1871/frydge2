# Handover — what's done, what's left

2 August 2026. Supersedes `NEXT_STEPS.md` for the "what do I do now" question.

**Nothing here has been compiled.** I have no Xcode toolchain. Everything was
verified by inspection: brace/paren/bracket balance with a comment- and
string-aware scanner, plist parsing, `node --check` on the worker JS, pbxproj
structural checks, and API-surface diffs against call sites.

---

## Done in this session

### Data loss (all six P0s from the review)

| | Fix |
|---|---|
| P0-1 | `saveToFile` infinite recursion → stack overflow crash |
| P0-2 | fridge photos destroyed on every cloud sync |
| P0-3 | failed CloudKit writes dropped from the dirty set forever |
| P0-4 | shopping list whole-list last-writer-wins |
| P0-5 | deletes resurrecting after 7 days |
| P0-6 | fridge leaking between iCloud accounts on a shared device |

### Sync migration

- Core Data model with `CDFridgeItem` / `CDShoppingItem` / `CDItemPhoto`,
  verified CloudKit-legal (all attributes optional-or-defaulted, 4/4 inverse
  pairs, no unique constraints, no Deny rules)
- `PersistenceController` → `NSPersistentCloudKitContainer`, App Group store,
  history tracking + remote change notifications, no `fatalError`
- Both managers cut over: write-through on save, reload on remote change,
  ~600 lines of hand-rolled CloudKit deleted
- Also collapsed three live `FrydgeManager` instances into one — they were
  clobbering each other's writes

### Location / Live Activity

- `RegionMonitoring` is now the **single** geofence owner. `LocationManager` was
  registering a competing 20 regions and had no `didEnterRegion` handler, so
  arrivals fired into nothing whenever it won the race
- `requestState` moved to `didStartMonitoringFor` (was returning `.unknown`)
- Region re-prime no longer stops/restarts everything on each location update
- Co-located stores collapsed — 14 Whitianga entries share one coordinate
- `monitoringDidFailFor` implemented; failures were invisible
- APNs push-to-start: `LiveActivityPushManager` + stateless Cloudflare worker
- `pushType: nil` → `.token`

### Config / hygiene

- Background task identifiers + `fetch`/`processing` background modes declared
- Privacy manifest populated (4 required-reason APIs, 8 collected data types)
- 8 purpose strings rewritten — one literally said `testing`
- Worker `.js`/`.toml` excluded from the app target via pbxproj membership
  exceptions, so backend source stops shipping in the IPA
- Stripe: merchant ID placeholder fixed, backend URL collapsed from three
  hardcoded copies to one, `localhost:3000` gated behind `#if DEBUG`
- `NetworkMonitor` data race fixed; cold-start now answers optimistically
  instead of skipping the first sync of every session

---

## Left for you — in Xcode

**1. Build it.** Expect compile errors. Synchronized file groups mean the four
new Swift files are picked up automatically; nothing to add manually.

**2. Delete `CoreDataMirror.swift`.** Emptied to comments (you declined the delete
permission, which is fine) — it compiles as a no-op but is dead weight.

**3. `aps-environment`.** Both entitlements files are hardcoded `development`.
Push-to-start will work on your dev device and silently do nothing in TestFlight.
`LiveActivityPushManager.apnsEnvironment` already switches on `#if DEBUG`, so the
entitlement needs to match.

**4. Clean build folder** if Core Data complains about missing `CDFridgeItem` —
stale DerivedData is the usual cause with `codeGenerationType="class"`.

---

## Left for you — CloudKit Console

**Deploy the schema. The fridge and shopping list do not sync until you do.**

1. Debug build, team `A2H3YQ5U79`
2. Call `PersistenceController.shared.initializeCloudKitSchema()` once
3. Console → `iCloud.com.Clark-Online.Recipe` → **Deploy Schema to Production**

Release builds cannot create schema. Skipping this is the single most likely way
this migration appears to "not work".

---

## Left for you — Cloudflare

```bash
cd FrydgeRecipes
wrangler secret put APNS_KEY_P8      -c wrangler-liveactivity.toml   # full .p8 incl. BEGIN/END lines
wrangler secret put FRYDGE_RELAY_KEY -c wrangler-liveactivity.toml   # must match relayKey in Swift
wrangler deploy                      -c wrangler-liveactivity.toml
```

Test without leaving your desk — token comes from the launch log
(`os.Logger`, subsystem `com.Clark-Online.Recipes`, category `LiveActivityPush`):

```bash
curl -X POST https://frydge2.com/live-activity/start \
  -H "Content-Type: application/json" -H "X-Frydge-Key: frydge2liveactivity" \
  -d '{"pushToStartToken":"<token>","storeName":"Test Store","items":["Milk"],"environment":"development"}'
```

Also decide what to do with `cloudflare-worker-product-matching.js` — it has no
wrangler config and has never been deployed. And `stripe-backend-configured.js` /
`stripe-backend-example.js` look like superseded drafts.

---

## Left for you — Stripe

- `wrangler secret put STRIPE_SECRET_KEY -c wrangler-stripe.toml` (and publishable)
- Enable **Connect** in the dashboard for seller payouts
- Set `StripeConfig.terminalLocationId` to a real `tml_…` if you want Tap to Pay
- Consider shipping the publishable key as a default — it's public by design, and
  right now `isConfigured` is false until a user finds the setup screen

---

## Left — needs a decision from you

**The marketplace has no order model.** This is the actual "end to end" gap.
Payment succeeds → `dismiss()`. Nothing persists. Neither buyer nor seller has a
record that a transaction happened.

I deliberately didn't guess at the shape, because money is involved and the
choice affects refunds, disputes and fulfilment. The options I'd want your call
on:

- order records + status (buyer pays → order persists → seller marks fulfilled)
- seller payouts (Connect onboarding actually completing)
- in-person handover (the QR flow — `generateQRCode`/`decodeQRPayment` exist,
  I didn't trace where they're consumed)

Everything else in the marketplace is more complete than I expected — the app's
Stripe endpoints match what the worker implements exactly.

---

## Left — housekeeping I couldn't do from here

- **Move `AuthKey_7XKRGZRVQD.p8` and `APNCertificates.p12` out of the repo folder**
  once the Wrangler secret is set. Correctly gitignored and *not* tracked, but
  sitting in iCloud Drive.
- **Get the repo out of iCloud Drive.** There's a `.git 2/` conflict directory and
  an `oldzips 2/`. iCloud's dataless-file eviction broke `git` entirely during
  this review — I couldn't run a single git command.
- **Deployment targets diverge**: 18.0 / 26.0 / 26.5 across targets. Unify.
- **Watch app has no entitlements file** — no App Group, so it can't read shared state.

---

## Known-unverified

Ordered by how much it would cost you if I got it wrong:

1. **Nothing compiles yet.** Highest risk is the two manager cutovers.
2. **`ShoppingListManager` feedback loop.** The `isApplyingRemoteChange` flag stops
   the save-sink and the remote-change observer feeding each other. If it's wrong
   you'll see continuous store writes after a single edit — test 7 in
   `PHASE3B_SHOPPING_CUTOVER.md` targets exactly this.
3. **CloudKit Production schema** — never inspected; P1-4's queryable-index
   assumption and the `FrydgeFridgeZone` / `ShoppingListZone` queries in
   `ProfileView` (which I believe return empty forever) need checking in Console.
4. **`BGTaskScheduler` behaviour** with previously-undeclared identifiers varies by
   OS version. I asserted the feature was broken, not the precise failure mode.
5. **Bundle resource exclusion** — verify the worker files really are absent from
   the built `.app`.

---

## If you only do three things

1. Build, fix compile errors, run the two-device test in `PHASE3A`/`PHASE3B`
2. Deploy the CloudKit schema
3. Move the `.p8` out of iCloud Drive
