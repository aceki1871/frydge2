// Run with:  node --test test/
// Pure-function coverage for the marketplace payment policy (plan workstream
// F2/F3). Route-level behaviour against D1 and Stripe is exercised on the
// staging Worker, not here.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  MARKETPLACE_FEE_BPS,
  HANDLED_EVENTS,
  validAttemptId,
  attemptFingerprint,
  fingerprintOfRow,
  decidePaymentTransition,
} from "../src/marketplace-policy.js";

test("fee rate matches the app's MarketplaceFees.feeBps (2%)", () => {
  assert.equal(MARKETPLACE_FEE_BPS, 200);
});

test("attemptId must be 8–128 URL-safe characters", () => {
  assert.equal(validAttemptId("abc"), null);
  assert.equal(validAttemptId("has space!"), null);
  assert.equal(validAttemptId(42), null);
  assert.equal(validAttemptId("chk_0123456789"), "chk_0123456789");
  assert.equal(validAttemptId("a".repeat(129)), null);
});

test("fingerprint of a stored row matches the draft it was reserved from", () => {
  const draft = {
    buyerUserId: "_buyer", sellerUserId: "_seller", venueId: null,
    listingId: "lst_1", quantity: 2, amountCents: 1250, currency: "NZD", channel: "online",
  };
  const row = {
    buyer_user_id: "_buyer", seller_user_id: "_seller", listing_id: "lst_1",
    quantity: 2, amount: 1250, currency: "nzd", channel: "online", metadata: "{}",
  };
  assert.equal(fingerprintOfRow(row), attemptFingerprint(draft));
});

test("fingerprint changes when the money or the counterparty changes", () => {
  const base = { buyerUserId: "b", sellerUserId: "s", listingId: "l", quantity: 1, amountCents: 100, currency: "nzd" };
  assert.notEqual(attemptFingerprint(base), attemptFingerprint({ ...base, amountCents: 101 }));
  assert.notEqual(attemptFingerprint(base), attemptFingerprint({ ...base, sellerUserId: "other" }));
  assert.notEqual(attemptFingerprint(base), attemptFingerprint({ ...base, channel: "in_person" }));
});

test("venueId reserved in metadata takes part in the fingerprint", () => {
  const row = {
    buyer_user_id: "b", seller_user_id: null, listing_id: null, quantity: 1,
    amount: 500, currency: "nzd", channel: "in_person", metadata: JSON.stringify({ venueId: "ven_9" }),
  };
  assert.equal(
    fingerprintOfRow(row),
    attemptFingerprint({ buyerUserId: "b", venueId: "ven_9", quantity: 1, amountCents: 500, currency: "nzd", channel: "in_person" })
  );
});

test("normal payment lifecycle", () => {
  assert.deepEqual(decidePaymentTransition("pending_payment", "paid"), { next: "paid", reason: null });
  assert.deepEqual(decidePaymentTransition("pending_payment", "payment_failed"), { next: "payment_failed", reason: null });
  assert.deepEqual(decidePaymentTransition("payment_failed", "paid"), { next: "paid", reason: null });
});

test("duplicate success after fulfilment does not regress ready/received", () => {
  assert.equal(decidePaymentTransition("ready", "paid").next, null);
  assert.equal(decidePaymentTransition("ready", "paid").reason, "fulfilmentPreserved");
  assert.equal(decidePaymentTransition("received", "paid").refreshStripeStatus, true);
});

test("a stale failure cannot undo a payment", () => {
  for (const s of ["paid", "ready", "received"]) {
    assert.equal(decidePaymentTransition(s, "payment_failed").reason, "staleFailure");
  }
});

test("refund and dispute are terminal", () => {
  assert.equal(decidePaymentTransition("received", "refunded").next, "refunded");
  assert.equal(decidePaymentTransition("paid", "disputed").next, "disputed");
  assert.equal(decidePaymentTransition("refunded", "paid").reason, "ignoredRegression");
  assert.equal(decidePaymentTransition("disputed", "payment_failed").reason, "ignoredRegression");
  // A dispute after a refund is still recorded.
  assert.equal(decidePaymentTransition("refunded", "disputed").next, "disputed");
});

test("same status twice is a no-op", () => {
  assert.equal(decidePaymentTransition("paid", "paid").reason, "alreadyApplied");
});

test("only the four lifecycle events are handled", () => {
  assert.deepEqual(Object.keys(HANDLED_EVENTS).sort(), [
    "charge.dispute.created", "charge.refunded", "payment_intent.payment_failed", "payment_intent.succeeded",
  ]);
});
