# Next steps — deployment checklist

Everything I've written across this session is **unbuilt and undeployed**. This is
what stands between here and it actually running.

Ordered so that each step unblocks the next. **Step 1 first — nothing else matters
if the app doesn't compile.**

---

## 1. Xcode — build it

Nothing to add to the project manually. The project uses Xcode 16 synchronized
file groups (`objectVersion = 100`), so every new `.swift` file in `FrydgeRecipes/`
is picked up automatically:

- `CoreDataMapping.swift`
- `CoreDataHousekeeping.swift`
- `LiveActivityPushManager.swift`
- `PersistenceController.swift` (rewritten)

Two things to do by hand:

- **Delete `CoreDataMirror.swift`** from the project. It's emptied to comments and
  compiles as a no-op, but it's dead weight.
- **Check the Core Data model compiles.** `CDFridgeItem`, `CDShoppingItem` and
  `CDItemPhoto` use `codeGenerationType="class"`, so Xcode generates the classes.
  If it complains about missing types, clean build folder (⇧⌘K) first — stale
  DerivedData is the usual cause.

Expect the first build to surface a handful of errors. None of this has met a
compiler; I verified brace/paren balance and API surfaces only.

---

## 2. Xcode — `aps-environment` (you said you'd handle this)

`FrydgeRecipes/FrydgeRecipes.entitlements` and
`ShoppingListNotificationExtension/…entitlements` are both hardcoded to
`development`.

Push-to-start will work perfectly on your dev device and **silently do nothing in
TestFlight**. `LiveActivityPushManager.apnsEnvironment` already switches on
`#if DEBUG`, so the client will ask for the sandbox host in Debug and production in
Release — the entitlement needs to match or APNs returns `BadDeviceToken`.

The worker surfaces that error verbatim with a hint, so you'll know immediately.

---

## 3. CloudKit Console — deploy the schema ⚠️

**The fridge and shopping list do not sync until you do this.** Release builds
cannot create CloudKit schema.

1. Debug build on a device signed with team `A2H3YQ5U79`
2. Call `PersistenceController.shared.initializeCloudKitSchema()` once
   (`#if DEBUG` helper — call it from a debug button or the diagnostic view)
3. CloudKit Console → `iCloud.com.Clark-Online.Recipe` → **Deploy Schema to Production**

New record types will appear as `CD_CDFridgeItem`, `CD_CDShoppingItem`,
`CD_CDItemPhoto`. Your existing `StoredIngredient` / `UserShoppingList` types stay
untouched — nothing is overwritten.

---

## 4. Cloudflare — deploy the Live Activity worker

```bash
cd FrydgeRecipes
wrangler secret put APNS_KEY_P8      -c wrangler-liveactivity.toml
wrangler secret put FRYDGE_RELAY_KEY -c wrangler-liveactivity.toml
wrangler deploy                      -c wrangler-liveactivity.toml
```

- `APNS_KEY_P8` — the **full** contents of `AuthKey_7XKRGZRVQD.p8`, including the
  `-----BEGIN PRIVATE KEY-----` / `-----END PRIVATE KEY-----` lines.
- `FRYDGE_RELAY_KEY` — must match `relayKey` in `LiveActivityPushManager.swift`
  (currently `frydge2liveactivity`).

Constants already baked in from your existing worker: team `A2H3YQ5U79`,
key ID `7XKRGZRVQD`, bundle `Clark-Online.Recipes`, topic
`Clark-Online.Recipes.push-type.liveactivity`.

**Test it without walking to a shop:**

```bash
curl -X POST https://frydge2.com/live-activity/start \
  -H "Content-Type: application/json" \
  -H "X-Frydge-Key: frydge2liveactivity" \
  -d '{"pushToStartToken":"<from device log>","storeName":"Test Store",
       "items":["Milk","Bread"],"environment":"development"}'
```

The token is printed at launch: `Push-to-start token updated (…)`. Log via
`os.Logger`, subsystem `com.Clark-Online.Recipes`, category `LiveActivityPush`.

---

## 5. Cloudflare — the state of your other workers

| Worker | Config | Status |
|---|---|---|
| `cloudflare-worker-recipe-sharing.js` | `wrangler.toml` | routed |
| `cloudflare-worker-stripe-payments.js` | `wrangler-stripe.toml` | routed |
| `cloudflare-worker-live-activity.js` | `wrangler-liveactivity.toml` | **new — deploy it** |
| `cloudflare-worker-product-matching.js` | — | **no config, never deployed** |
| `stripe-backend-configured.js` | — | orphan |
| `stripe-backend-example.js` | — | orphan |

Worth deciding what `cloudflare-worker-product-matching.js` is for — it has no
wrangler config, so it has never been deployed. The two `stripe-backend-*.js` files
look like earlier drafts superseded by the worker; if so, delete them.

⚠️ **These `.js` and `.toml` files live inside `FrydgeRecipes/`, which is a
synchronized group — so they're almost certainly being copied into your app bundle
as resources.** No secrets are exposed (they're all Wrangler secrets, correctly),
but your backend source ships to every user. Move them to a sibling folder like
`workers/` outside the target.

---

## 6. Stripe — what's actually unconfigured

The endpoints line up — the app calls exactly what the worker implements:

```
/stripe/create-payment-intent     ✓
/stripe/confirm-apple-pay         ✓
/stripe/connect/onboard           ✓
/stripe/connect/account-status    ✓
/stripe/connect/create-intent     ✓
```

Worker secrets needed (per `wrangler-stripe.toml`):

```bash
wrangler secret put STRIPE_SECRET_KEY      -c wrangler-stripe.toml
wrangler secret put STRIPE_PUBLISHABLE_KEY -c wrangler-stripe.toml
```

**Three client-side problems:**

1. **Merchant identifier mismatch.** Your entitlement is
   `merchant.com.Clark-Online.Recipe` and `ApplePaymentHandler.swift:41` hardcodes
   that correctly — but `StripeConfig.swift:47` defaults to
   `merchant.com.yourcompany.frydge`. Anything reading `StripeConfig.merchantIdentifier`
   before it's been set gets a placeholder that will fail Apple Pay.

2. **`StripeConfig` is empty until someone fills it in by hand.** `publishableKey`
   and `backendBaseURL` both default to `""`, and `isConfigured` is false until a
   user visits the setup screen. Nothing seeds them. `StripePaymentService.swift:65`
   falls back to `https://frydge2.com/stripe`, but `StripeConnectManager` and
   `ApplePaymentHandler` hardcode it separately — three sources of truth.
   Suggest: default `backendBaseURL` to `https://frydge2.com/stripe` and ship the
   publishable key (it's public by design), so the app works out of the box.

3. **`QuickStripeSetup.swift` offers `http://localhost:3000`** as a selectable
   backend (lines 88, 211, 216, 242) in a shipping build.

**Stripe Dashboard side:** Connect must be enabled for seller payouts, and
`StripeConfig.terminalLocationId` needs a real `tml_…` if you want Tap to Pay.

---

## 7. Still open

- **Marketplace has no order model.** Payment succeeds → `dismiss()`. Nothing
  persists, so neither buyer nor seller has a record. This is the actual "end to
  end" gap and needs a design decision from you — see the end of my last message.
- **Move `AuthKey_7XKRGZRVQD.p8` and `APNCertificates.p12` out of the repo folder**
  once the Wrangler secret is set. `.gitignore` correctly excludes them and they
  are *not* tracked — but they're sitting in iCloud Drive.
- **Get the repo out of iCloud Drive.** There's a `.git 2/` conflict directory and
  an `oldzips 2/`. iCloud's dataless-file eviction broke `git` entirely during this
  review.

---

## Suggested order for one sitting

1. Build in Xcode, fix compile errors
2. Deploy CloudKit schema → test fridge/list sync on two devices
3. Deploy the Live Activity worker → curl-test push-to-start
4. Fix `aps-environment`, then TestFlight and re-test the push
5. Then decide on the marketplace order model

Steps 2 and 3 are independent — do whichever you have patience for first.
