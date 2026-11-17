-- Frydge marketplace — D1 migration 002: checkout attempts + webhook events
--
-- Additive only. Apply once to an existing database AFTER schema-marketplace.sql:
--   wrangler d1 execute frydge-marketplace --file=schema-marketplace-002-attempts-and-events.sql --remote
--
-- Fresh databases get the same columns/tables from schema-marketplace.sql and
-- must NOT run this file (ALTER TABLE ADD COLUMN fails if the column exists).
--
-- Why:
-- * `orders.attempt_id` lets /orders/create reserve the order row under a
--   client-generated checkout-attempt ID before the PaymentIntent exists, so a
--   retried, duplicated or concurrent request resolves to the SAME order and
--   PaymentIntent instead of a second charge.
-- * `stripe_events` records every verified webhook delivery by Stripe event ID
--   in the same batch as the order update, so redeliveries are idempotent and
--   events for orders we cannot match yet are kept for reconciliation instead
--   of being acknowledged and lost.

ALTER TABLE orders ADD COLUMN attempt_id TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_orders_attempt
  ON orders (attempt_id);

CREATE TABLE IF NOT EXISTS stripe_events (
  event_id          TEXT PRIMARY KEY,   -- evt_... (Stripe's ID)
  event_type        TEXT NOT NULL,
  payment_intent_id TEXT,
  order_id          TEXT,               -- NULL when no order matched (outcome = 'unmatched')
  outcome           TEXT NOT NULL,      -- applied:<status> | alreadyApplied | fulfilmentPreserved | staleFailure | ignoredRegression | unmatched
  received_at       INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_stripe_events_unmatched
  ON stripe_events (outcome, payment_intent_id);
