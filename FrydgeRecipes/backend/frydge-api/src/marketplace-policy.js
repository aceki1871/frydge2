// Pure marketplace policy helpers. No I/O, no Cloudflare bindings, so they can
// be unit-tested with `node --test` and reused by the worker in src/index.js.

/** Marketplace cut in basis points. Must match MarketplaceFees.feeBps in the app. */
export const MARKETPLACE_FEE_BPS = 200;

/** Client-generated checkout-attempt id, reused on every retry of one checkout. */
export function validAttemptId(value) {
  return typeof value === "string" && /^[A-Za-z0-9_-]{8,128}$/.test(value) ? value : null;
}

/** The fields that must not change between retries of one attempt. */
export function attemptFingerprint(o) {
  return JSON.stringify({
    buyer: o.buyerUserId ?? null,
    seller: o.sellerUserId ?? null,
    venue: o.venueId ?? null,
    listing: o.listingId ?? null,
    quantity: Number(o.quantity) || 1,
    amount: Number(o.amountCents),
    currency: String(o.currency).toLowerCase(),
    channel: o.channel ?? "online",
  });
}

export function fingerprintOfRow(row) {
  let venueId = null;
  try { venueId = JSON.parse(row.metadata ?? "{}")?.venueId ?? null; } catch { /* keep null */ }
  return attemptFingerprint({
    buyerUserId: row.buyer_user_id, sellerUserId: row.seller_user_id, venueId,
    listingId: row.listing_id, quantity: row.quantity,
    amountCents: row.amount, currency: row.currency, channel: row.channel ?? "online",
  });
}

/**
 * Payment-state transition policy. Payment state and fulfilment progress share
 * the `status` column, so these rules keep fulfilment (`ready`, `received`)
 * from being wound back by a redelivered or late payment event, and keep
 * terminal payment outcomes (`refunded`, `disputed`) from being overwritten by
 * anything earlier in the lifecycle.
 *
 *   pending_payment  + paid              -> paid
 *   pending_payment  + payment_failed    -> payment_failed
 *   payment_failed   + paid              -> paid            (retry after decline)
 *   paid/ready/received + payment_failed -> unchanged       (stale failure)
 *   ready/received   + paid              -> unchanged, stripe_status refreshed
 *   any              + refunded/disputed -> refunded/disputed
 *   refunded/disputed + paid/failed      -> unchanged
 */
export function decidePaymentTransition(current, incoming) {
  const fulfilled = ["ready", "received"];
  const terminalPayment = ["refunded", "disputed"];

  if (current === incoming) return { next: null, reason: "alreadyApplied" };
  if (terminalPayment.includes(current) && !terminalPayment.includes(incoming)) {
    return { next: null, reason: "ignoredRegression" };
  }
  if (incoming === "paid" && fulfilled.includes(current)) {
    return { next: null, reason: "fulfilmentPreserved", refreshStripeStatus: true };
  }
  if (incoming === "payment_failed" && current !== "pending_payment") {
    return { next: null, reason: "staleFailure" };
  }
  return { next: incoming, reason: null };
}

/** Stripe event types the marketplace webhook acts on, mapped to order status. */
export const HANDLED_EVENTS = Object.freeze({
  "payment_intent.succeeded": "paid",
  "payment_intent.payment_failed": "payment_failed",
  "charge.refunded": "refunded",
  "charge.dispute.created": "disputed",
});
