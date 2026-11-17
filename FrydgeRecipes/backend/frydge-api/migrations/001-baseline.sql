-- frydge-marketplace — migration 001: baseline
--
-- The live schema exactly as `sqlite_master` reported it on 2 Nov 2026
-- (see ../../deployed/d1-frydge-marketplace-schema.json). Production already
-- has this; apply it only to fresh/staging databases:
--   wrangler d1 execute frydge-marketplace-staging --env staging --remote --file migrations/001-baseline.sql
--
-- `channel` was added to production with a bare ALTER TABLE at some point
-- after the original schema file was written; it is folded in here.

CREATE TABLE IF NOT EXISTS orders (
  id                     TEXT PRIMARY KEY,           -- ord_<uuid>
  payment_intent_id      TEXT UNIQUE,                -- pi_... (Stripe's ID)

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
  metadata               TEXT,

  -- "online" (app checkout) or "in_person" (Tap to Pay on the seller's phone)
  channel                TEXT
);

CREATE INDEX IF NOT EXISTS idx_orders_buyer
  ON orders (buyer_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_orders_seller
  ON orders (seller_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_orders_payment_intent
  ON orders (payment_intent_id);

CREATE TABLE IF NOT EXISTS order_events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  order_id    TEXT NOT NULL,
  event_type  TEXT NOT NULL,   -- created | payment_intent_attached | webhook | seller_ready | buyer_confirmed | refunded
  from_status TEXT,
  to_status   TEXT,
  source      TEXT,            -- app | terminal | stripe_webhook
  detail      TEXT,            -- JSON
  created_at  INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_order_events_order
  ON order_events (order_id, created_at DESC);
