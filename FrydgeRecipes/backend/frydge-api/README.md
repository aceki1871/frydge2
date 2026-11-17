# frydge-api Worker

Editable source for the Worker the app actually talks to
(`https://frydge-api.davekitson-read.workers.dev`). Reconstructed on
2 November 2026 from the deployed bundle in `../deployed/frydge-api/` and then
patched for repair-plan workstream F. Nothing has been deployed from here.

| Path | Purpose |
| --- | --- |
| `src/index.js` | Worker entry. Portal `/api/*`, marketplace `/marketplace/*`, legacy `/stripe/*`. |
| `src/marketplace-policy.js` | Pure payment policy: attempt ids, fingerprints, transition table. Unit-tested. |
| `migrations/001-baseline.sql` | The live `frydge-marketplace` schema as recorded on 2 Nov 2026. |
| `migrations/002-attempts-and-events.sql` | Adds `orders.attempt_id` and `stripe_events`. Required by this source. |
| `test/policy.test.mjs` | `node --test test/policy.test.mjs` |
| `wrangler.toml` | Production bindings (ids match the dashboard) and a `staging` environment with placeholders. |

## What changed versus the deployed bundle

Only the marketplace section. The portal, venue, timesheet, product and legacy
Stripe handlers are byte-for-byte the deployed logic with esbuild's `__name`
wrappers removed.

- **Idempotent checkout (F2).** `/marketplace/orders/create` and
  `/marketplace/terminal/orders/create` require `attemptId`. The order row is
  reserved under that id before any Stripe call; the PaymentIntent is created
  with idempotency key `pi:<orderId>` and attached with a conditional update.
  A retry resumes the same order and intent; a changed payload under the same
  `attemptId` is rejected with 409. The app already sends `attemptId`.
- **Webhook de-duplication and transitions (F3).** `/marketplace/webhook`
  records every verified event in `stripe_events` in the same D1 batch as the
  order update. `decidePaymentTransition` stops a redelivered success from
  winding `ready`/`received` back to `paid`, ignores stale failures, and keeps
  `refunded`/`disputed` terminal. Unmatched events are stored as `unmatched`
  for reconciliation instead of being acknowledged and lost. Missing webhook
  secret now fails closed (503).
- **Conditional seller/buyer actions.** `mark-ready`, `confirm-received` and
  `refund` write `WHERE status = <the status we read>` so a concurrent webhook
  cannot be overwritten; a lost race returns 409.
- **Launch gate.** `GET /marketplace/config` returns
  `{ marketplaceEnabled }` from the `MARKETPLACE_ENABLED` var. The create
  routes refuse (503) while it is off, so the kill switch is enforced
  server-side, not only in the app.
- **Fee rate.** Default fee is 2% (`MARKETPLACE_FEE_BPS = 200`) to match
  `MarketplaceFees.feeBps` in the app. The deployed bundle defaulted to 5%;
  the app always sends `applicationFeeAmount`, so this only affects clients
  that omit it. The fee is also clamped to `[0, amount]`.
- **Fee clamp and account resolution.** Seller payout account is still
  resolved from `venues`/`organisations` or `p2p_sellers`; a client-supplied
  `sellerAccountId` is only used when neither matches (unchanged behaviour,
  now documented).

Not changed, still open from the plan: `/marketplace/*` trusts the user ids in
the request body (F1 server session). That needs an identity design decision
before it can be implemented.

## Running the unit tests

```
cd backend/frydge-api
node --test test/policy.test.mjs
```

## Staging rollout (requires Josh)

1. Create `frydge-marketplace-staging` and `frydge-production-staging` D1
   databases, a staging KV namespace and R2 bucket; paste ids into
   `[env.staging]` in `wrangler.toml`.
2. Apply `migrations/001-baseline.sql` then `002-attempts-and-events.sql` to the
   staging marketplace DB. Seed `frydge-production-staging` from a copy of the
   portal schema.
3. `wrangler secret put` each secret for `--env staging` with **test-mode**
   Stripe keys and a staging webhook endpoint secret.
4. `wrangler deploy --env staging`, point a Debug build at the staging host via
   `FrydgeBackend.host`, and run the F test matrix: retry with the same
   `attemptId`, concurrent taps, lost response, duplicate webhook after
   `ready`, failed-then-succeeded intent, refund, dispute, unknown order.

## Production (requires Josh)

1. Apply `migrations/002-attempts-and-events.sql` to `frydge-marketplace`
   (additive; the Worker currently deployed ignores the new column/table).
2. `wrangler deploy` from this directory.
3. Flip `MARKETPLACE_ENABLED` to `"true"` and redeploy only when the launch
   gates in the plan pass.
