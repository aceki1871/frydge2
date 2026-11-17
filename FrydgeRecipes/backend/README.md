# Backend inventory (repair plan workstream E)

Recorded 2 November 2026 from the Cloudflare account "Joshs" (id `3aecfa3f…`) using
read-only API calls. Nothing was deployed, deleted or reconfigured.

`deployed/` holds the exact bundles the Cloudflare API returned for each live
Worker. They are the authoritative source until an editable source tree is
reconstructed. Secret values were never downloaded; only binding names are listed.

## Live Workers

| Worker | Deployed | Entry file | Called by |
| --- | --- | --- | --- |
| `frydge-api` | 2026-08-14 (version `a337639c`) | `index.js` (esbuild bundle, 1542 lines) | `FrydgeBackend.host` → `/marketplace/*`, `/stripe/*`; also `/api/*` auth, venues, super-admin |
| `frydge-products` | 2026-08-05 (`a08a371f`) | `products-worker.js` | `OpenFoodFactsService` |
| `grocery-price-server` | 2026-06-06 (`ae4edb11`) | `index.js` (3.2 MB, bundled data) | `BarcodeScannerView`, `WidgetPriceFetcher` |
| `frydge2-recipe-sharing` | 2026-05-24 (`cf730439`) | `cloudflare-worker-recipe-sharing.js` | `FrydgeRecipeShareService`, universal links |
| `frydge2-live-activity` | 2026-08-02 (`7da3572b`) | `cloudflare-worker-live-activity.js` | `LiveActivityPushManager` |

Workers named in the repo's `wrangler-marketplace.toml` (`frydge2-marketplace`) and
`wrangler-stripe.toml` (`frydge2-stripe`) **do not exist** on the account. Their
routes are served by `frydge-api` on `frydge-api.davekitson-read.workers.dev`.
Treat those two toml files and `FrydgeRecipes/cloudflare-worker-marketplace.js` /
`cloudflare-worker-stripe-payments.js` as archival: deploying them would create
new Workers that the app never calls.

## `frydge-api` bindings (names only)

| Type | Name | Target |
| --- | --- | --- |
| D1 | `FRYDGE_DB` | `frydge-production` (`17ad308f…`) |
| D1 | `MARKETPLACE_DB` | `frydge-marketplace` (`a0fcde9b…`) |
| KV | `FRYDGE_CACHE` | |
| R2 | `FRYDGE_ASSETS` | |
| plain text | `APNS_KEY_ID`, `APNS_TEAM_ID`, `APP_BUNDLE_ID` | |
| secret | `FRYDGE_RELAY_KEY`, `JWT_SECRET`, `MARKETPLACE_WEBHOOK_SECRET`, `RESEND_API_KEY`, `STRIPE_CLIENT_ID`, `STRIPE_PUBLISHABLE_KEY`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` | |

Compatibility date: 2024-09-01.

Other D1 databases on the account: `frydge-product-prices`, `givemeasecond`.

## Route contract comparison

Deployed `frydge-api` routes relevant to the app:

```
/marketplace/orders/create        /marketplace/orders/get
/marketplace/orders/list          /marketplace/orders/mark-ready
/marketplace/orders/confirm-received
/marketplace/orders/refund        (not in repo source)
/marketplace/terminal/connection-token
/marketplace/terminal/orders/create
/marketplace/webhook
/stripe/create-payment-intent     /stripe/confirm-apple-pay
/stripe/connect/onboard           /stripe/connect/account-status
/stripe/connect/create-intent
/api/stripe/terminal/connection-token   /api/stripe/webhook
```

Gaps found:

- **`GET /marketplace/config` is not served.** `MarketplaceAvailability` fetches it
  on every foreground to decide whether App Store builds show the marketplace.
  The repo worker implements it; the deployed bundle does not. The client's
  fallback on a 404 is what currently gates production.
- **Idempotent checkout (F2) is not deployed.** The bundle contains no
  `attemptId` handling and the live `frydge-marketplace` schema has only
  `orders` and `order_events`. Repo migration
  `schema-marketplace-002-attempts-and-events.sql` has not been applied.
- **Webhook event dedup (F3) is not deployed.** No `stripe_events` table exists
  live although `schema-marketplace.sql` in the repo declares one.
- **Schema drift.** Live `orders` has an extra `channel TEXT` column added by
  `ALTER TABLE`; the repo schema file does not declare it.
- The relay-key gate (`X-Frydge-Key` / `FRYDGE_RELAY_KEY`) **is** present in the
  deployed bundle, so the client header already matches production.

Live `frydge-marketplace` schema snapshot: `deployed/d1-frydge-marketplace-schema.json`.

## Next steps before deploying F

1. Reconstruct an editable source tree for `frydge-api` from `deployed/frydge-api/index.js`
   (it is a bundle of several modules; the `/api/*` auth and super-admin routes have
   no counterpart in this repo and must be preserved).
2. Port the F changes (attempt reservation, stable idempotency key, event dedup,
   fulfilment-preserving transitions, `/marketplace/config`) into that tree.
3. Apply migration 002 to a staging copy of `frydge-marketplace` first; add the
   `channel` column to the repo schema.
4. Deploy to a staging route with test-mode Stripe keys and run the F test matrix.

Josh must confirm the deployed source matches before any `wrangler deploy`.
