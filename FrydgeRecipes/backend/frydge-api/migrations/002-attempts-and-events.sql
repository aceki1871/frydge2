-- frydge-marketplace — migration 002: checkout attempts + webhook events
--
-- Additive only. Apply once to an existing database that already has
-- 001-baseline.sql (the live schema as of 2 Nov 2026):
--   wrangler d1 execute frydge-marketplace --remote --file migrations/002-attempts-and-events.sql
--
-- Why:
-- * `orders.attempt_id` lets /marketplace/orders/create reserve the order row
--   under a client-generated checkout-attempt id before the PaymentIntent
--   exists, so a retried, duplicated or concurrent request resolves to the SAME
--   order and PaymentIntent instead of a second charge.
-- * `stripe_events` records every verified webhook delivery by Stripe event id
--   in the same batch as the order update, so redeliveries are idempotent and
--   events for orders we cannot match yet are kept for reconciliation instead
--   of being acknowledged and lost.

ALTER TABLE orders ADD COLUMN attempt_id TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_orders_attempt
  ON orders (attempt_id);

CREATE TABLE IF NOT EXISTS stripe_events (
  event_id          TEXT PRIMARY KEY,   -- evt_... (Stripe's id)
  event_type        TEXT NOT NULL,
  payment_intent_id TEXT,
  order_id          TEXT,               -- NULL when no order matched (outcome = 'unmatched')
  outcome           TEXT NOT NULL,      -- applied:<status> | alreadyApplied | fulfilmentPreserved | staleFailure | ignoredRegression | unmatched
  received_at       INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_stripe_events_unmatched
  ON stripe_events (outcome, payment_intent_id);
