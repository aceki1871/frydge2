-- Frydge marketplace — D1 schema
--
-- Apply with:
--   wrangler d1 execute frydge-marketplace --file=schema-marketplace.sql --remote
--
-- Design notes:
--
-- * An order has TWO parties, so it cannot live in either user's private
--   CloudKit database. It must also be authoritative — the buyer's phone saying
--   "I paid" is not evidence. Stripe's webhook writes here server-side.
--
-- * `payment_intent_id` is UNIQUE. Stripe retries webhooks, and a retried
--   delivery must not create a second order. Every write is an upsert on it.
--
-- * Money is stored in the smallest currency unit (cents), as INTEGER. Never
--   floats — 0.1 + 0.2 problems with real money are unforgivable.
--
-- * Timestamps are unix seconds (INTEGER) for easy comparison and no timezone
--   ambiguity.

CREATE TABLE IF NOT EXISTS orders (
  id                     TEXT PRIMARY KEY,           -- ord_<uuid>
  payment_intent_id      TEXT UNIQUE,                -- pi_... (Stripe's ID); NULL while reserved
  -- Client-generated checkout-attempt ID, reused across retries. The row is
  -- reserved under it BEFORE the PaymentIntent is created, so a retry resolves
  -- to the same order and the same Stripe idempotency key (pi:<order id>).
  attempt_id             TEXT,

  -- What was bought
  listing_id             TEXT,
  listing_title          TEXT,
  quantity               INTEGER NOT NULL DEFAULT 1,

  -- Who
  buyer_user_id          TEXT NOT NULL,              -- CloudKit user record name
  seller_user_id         TEXT,                       -- CloudKit user record name
  seller_account_id      TEXT,                       -- acct_... Stripe Connect

  -- Money, in cents
  amount                 INTEGER NOT NULL,
  currency               TEXT    NOT NULL,
  platform_fee           INTEGER NOT NULL DEFAULT 0,

  -- "online" (app checkout) or "in_person" (Tap to Pay). Present in the live
  -- database (added by ALTER TABLE); recorded here so fresh databases match.
  channel                TEXT,

  -- Lifecycle
  --   pending_payment  order created, payment not yet confirmed
  --   paid             webhook confirmed payment_intent.succeeded
  --   ready            seller marked it ready / handed over
  --   received         buyer confirmed receipt — terminal happy path
  --   cancelled        abandoned before payment
  --   payment_failed   webhook confirmed failure
  --   refunded         refunded via Stripe
  --   disputed         chargeback opened
  status                 TEXT NOT NULL DEFAULT 'pending_payment',

  -- Raw Stripe status, kept separately so our lifecycle and Stripe's never
  -- silently disagree without it being visible.
  stripe_status          TEXT,

  seller_marked_ready_at INTEGER,
  buyer_confirmed_at     INTEGER,

  created_at             INTEGER NOT NULL,
  updated_at             INTEGER NOT NULL,

  -- Free-form JSON for anything not worth a column yet.
  metadata               TEXT
);

-- Buyer's order list, newest first.
CREATE INDEX IF NOT EXISTS idx_orders_buyer
  ON orders (buyer_user_id, created_at DESC);

-- Seller's order list, newest first.
CREATE INDEX IF NOT EXISTS idx_orders_seller
  ON orders (seller_user_id, created_at DESC);

-- Webhook lookup path — must be fast, it runs on every Stripe event.
CREATE INDEX IF NOT EXISTS idx_orders_payment_intent
  ON orders (payment_intent_id);

-- Audit trail. Every status change is appended, never updated.
--
-- Without this you cannot answer "when did this order become disputed, and what
-- did we know at the time" — which is exactly the question that matters when
-- money is contested.
CREATE TABLE IF NOT EXISTS order_events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  order_id    TEXT NOT NULL,
  event_type  TEXT NOT NULL,   -- created | webhook | seller_ready | buyer_confirmed | ...
  from_status TEXT,
  to_status   TEXT,
  source      TEXT,            -- app | stripe_webhook
  detail      TEXT,            -- JSON
  created_at  INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_order_events_order
  ON order_events (order_id, created_at DESC);

-- One row per checkout attempt. Lets a retried or concurrent create find the
-- reserved order instead of inserting a second one.
CREATE UNIQUE INDEX IF NOT EXISTS idx_orders_attempt
  ON orders (attempt_id);

-- Every verified webhook delivery, keyed by Stripe's event ID. Inserted in the
-- same batch as the order update so redeliveries are idempotent, and kept for
-- events that matched no order so they can be reconciled rather than lost.
CREATE TABLE IF NOT EXISTS stripe_events (
  event_id          TEXT PRIMARY KEY,   -- evt_...
  event_type        TEXT NOT NULL,
  payment_intent_id TEXT,
  order_id          TEXT,               -- NULL when unmatched
  outcome           TEXT NOT NULL,      -- applied:<status> | alreadyApplied | fulfilmentPreserved | staleFailure | ignoredRegression | unmatched
  received_at       INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_stripe_events_unmatched
  ON stripe_events (outcome, payment_intent_id);
