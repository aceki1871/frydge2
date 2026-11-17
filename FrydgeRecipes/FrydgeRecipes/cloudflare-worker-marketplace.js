/**
 * ⚠️ STALE COPY — DO NOT DEPLOY OR TREAT AS REFERENCE (flagged 2026-08-15)
 *
 * The deployed worker has diverged from this file:
 *   • /marketplace/orders/create and /marketplace/terminal/orders/create now
 *     accept `venueId` and resolve the seller's Stripe account server-side
 *     (from venueId, or from sellerUserId registered at Connect onboarding).
 *     Client-supplied `sellerAccountId` is IGNORED — this file still trusts it.
 * The deployed source is the single source of truth, not this file.
 *
 * REFERENCE ADDITIONS (2026-08-23) — reconcile these with the deployed worker:
 *   • /marketplace/terminal/connection-token — platform-account Stripe Terminal
 *     connection token for marketplace sellers' Tap to Pay (no clerk JWT).
 *     Optionally returns TERMINAL_LOCATION_ID (a tml_ on the platform account)
 *     so the app knows where to register the reader.
 *   • /marketplace/terminal/orders/create — order + card_present PaymentIntent
 *     collected on the seller's iPhone. Buyer identity optional (walk-ups).
 *   • DEFAULT_PLATFORM_FEE_BPS dropped 500 → 200: the marketplace cut is
 *     deliberately much smaller than the clerk/store system's, so small
 *     vendors and start-ups can afford to sell here. Must match
 *     MarketplaceFees.feeBps in the app.
 *
 * Cloudflare Worker — Frydge marketplace orders
 *
 * Route: https://frydge2.com/marketplace/*
 *
 * WHY THIS EXISTS
 *   Before this, a buyer could pay and neither party had any record. Payment
 *   succeeded and `MarketplaceCheckoutView` called `dismiss()`. This worker is
 *   the durable record of "money moved, goods owed".
 *
 * WHY IT'S A SEPARATE WORKER
 *   `/stripe/*` is already served by an older build under a name we haven't
 *   identified. New route, new worker, no collision.
 *
 * LIFECYCLE
 *   pending_payment ──(webhook: payment_intent.succeeded)──► paid
 *                   └─(webhook: payment_intent.payment_failed)──► payment_failed
 *   paid ──(seller marks ready)──► ready ──(buyer confirms)──► received
 *   any  ──(webhook: charge.refunded)──► refunded
 *   any  ──(webhook: charge.dispute.created)──► disputed
 *
 * AUTHORITY
 *   Only the Stripe webhook may set `paid`. The app cannot self-report payment —
 *   a client claiming success is not evidence.
 *
 * ⚠️ AUTHENTICATION LIMITATION — READ THIS
 *   Callers authenticate with a shared key and then *assert* their CloudKit user
 *   ID. A hostile client could pass someone else's ID and read their orders, or
 *   confirm receipt on their behalf. That is a real hole.
 *
 *   It is deliberately shipped this way as a first pass because the alternative
 *   (server-side CloudKit token validation) is substantial work. Do not treat
 *   this as production-grade auth. The fix is to verify a signed identity token
 *   from the app rather than trusting the body.
 *
 * SECRETS
 *   wrangler secret put STRIPE_SECRET_KEY     -c wrangler-marketplace.toml
 *   wrangler secret put STRIPE_WEBHOOK_SECRET -c wrangler-marketplace.toml
 *   wrangler secret put FRYDGE_RELAY_KEY      -c wrangler-marketplace.toml
 *
 * BINDINGS
 *   DB — D1 database `frydge-marketplace`
 */

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, X-Frydge-Key, Stripe-Signature",
};

// Marketplace cut. Kept low on purpose — the P2P marketplace is for small
// vendors; the clerk/store system carries the bigger-business pricing.
// Must match MarketplaceFees.feeBps in MarketplaceOrderService.swift.
const DEFAULT_PLATFORM_FEE_BPS = 200; // 2.00%

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, { headers: CORS });
    }

    const { pathname } = new URL(request.url);

    // The webhook authenticates by Stripe signature, NOT the relay key.
    if (pathname === "/marketplace/webhook") {
      return request.method === "POST" ? handleWebhook(request, env) : notFound();
    }

    // Fail closed — a missing secret must not disable auth.
    if (!env.FRYDGE_RELAY_KEY) {
      return json({ error: "Relay key not configured on the Worker" }, 503);
    }
    if (request.headers.get("X-Frydge-Key") !== env.FRYDGE_RELAY_KEY) {
      return json({ error: "Unauthorized" }, 401);
    }

    // GET /marketplace/config — launch gate read by MarketplaceAvailability
    // in the app. MARKETPLACE_ENABLED is a plain var in
    // wrangler-marketplace.toml; flip it and redeploy to go live, no app
    // update required. Anything other than the string "true" is OFF.
    // ⚠️ ADD THIS ROUTE TO THE DEPLOYED WORKER — this file is a stale copy.
    if (pathname === "/marketplace/config") {
      if (request.method !== "GET") return notFound();
      return json({ marketplaceEnabled: env.MARKETPLACE_ENABLED === "true" });
    }

    if (request.method !== "POST") return notFound();

    switch (pathname) {
      case "/marketplace/orders/create":            return createOrder(request, env);
      case "/marketplace/orders/list":              return listOrders(request, env);
      case "/marketplace/orders/get":               return getOrder(request, env);
      case "/marketplace/orders/mark-ready":        return markReady(request, env);
      case "/marketplace/orders/confirm-received":  return confirmReceived(request, env);
      case "/marketplace/terminal/connection-token": return terminalConnectionToken(request, env);
      case "/marketplace/terminal/orders/create":   return createTerminalOrder(request, env);
      default:                                      return notFound();
    }
  },
};

// ---------------------------------------------------------------------------
// POST /marketplace/orders/create
//
// Creates the PaymentIntent AND the order row in one call, so an order can never
// exist without an intent or vice versa.
//
// Body: {
//   attemptId,                       // client-generated, reused across retries
//   buyerUserId, sellerUserId?, sellerAccountId?,
//   listingId?, listingTitle?, quantity?,
//   amount (cents), currency,
//   applicationFeeAmount?, metadata?
// }
// Returns: { orderId, paymentIntentId, clientSecret, status, resumed }
//
// Order of operations matters for money:
//   1. reserve the order row under attemptId (unique) — no Stripe call yet
//   2. create the PaymentIntent with Idempotency-Key derived from the reserved
//      order ID, so every retry of this attempt reuses one key
//   3. attach the PaymentIntent to the row
// A retry at any point finds the reserved row and resumes from where it got to,
// so a lost response, an app restart or two concurrent taps cannot create a
// second order or a second charge.
// ---------------------------------------------------------------------------
async function createOrder(request, env) {
  const body = await readJSON(request);
  if (!body) return json({ error: "Invalid JSON" }, 400);

  const {
    buyerUserId, sellerUserId, sellerAccountId,
    listingId, listingTitle, quantity = 1,
    amount, currency, applicationFeeAmount, metadata = {},
  } = body;

  const attemptId = validAttemptId(body.attemptId);
  if (!attemptId) return json({ error: "attemptId is required (8–128 chars, [A-Za-z0-9_-])" }, 400);
  if (!buyerUserId) return json({ error: "buyerUserId is required" }, 400);
  if (!amount || !Number.isFinite(Number(amount))) return json({ error: "amount is required (cents)" }, 400);
  if (!currency) return json({ error: "currency is required" }, 400);

  const amountCents = Math.round(Number(amount));
  if (amountCents <= 0) return json({ error: "amount must be positive" }, 400);

  const fee = applicationFeeAmount != null
    ? Math.round(Number(applicationFeeAmount))
    : Math.round((amountCents * DEFAULT_PLATFORM_FEE_BPS) / 10000);

  // 1. Reserve (or resume) the order under this attempt.
  const reservation = await reserveOrder(env, attemptId, {
    buyerUserId, sellerUserId: sellerUserId ?? null, sellerAccountId: sellerAccountId ?? null,
    listingId: listingId ?? null, listingTitle: listingTitle ?? null, quantity: Number(quantity) || 1,
    amountCents, currency: String(currency).toLowerCase(), fee: sellerAccountId ? fee : 0,
    metadata, source: "app",
  });
  if (reservation.error) return reservation.error;
  const row = reservation.row;

  // 2./3. Create or resume the PaymentIntent for the reserved order.
  const outcome = await ensurePaymentIntent(env, row, (orderId) => {
    const params = new URLSearchParams({
      amount: String(row.amount),
      currency: row.currency,
      "payment_method_types[]": "card",
      "metadata[frydge_order_id]": orderId,
      "metadata[frydge_attempt_id]": attemptId,
      "metadata[buyer_user_id]": row.buyer_user_id,
    });
    if (row.seller_user_id) params.append("metadata[seller_user_id]", row.seller_user_id);
    if (row.listing_id) params.append("metadata[listing_id]", row.listing_id);
    for (const [k, v] of Object.entries(metadata)) {
      params.append(`metadata[${k}]`, String(v));
    }
    if (row.seller_account_id) {
      params.append("transfer_data[destination]", row.seller_account_id);
      params.append("application_fee_amount", String(row.platform_fee));
    }
    return params;
  });
  if (outcome.error) return outcome.error;

  return json({
    orderId: row.id,
    paymentIntentId: outcome.pi.id,
    clientSecret: outcome.pi.client_secret,
    status: row.status,
    resumed: outcome.resumed,
  });
}

// ---------------------------------------------------------------------------
// POST /marketplace/terminal/connection-token
//
// Stripe Terminal connection token from the PLATFORM account, for marketplace
// sellers using Tap to Pay on iPhone. The clerk/store system mints per-store
// tokens behind a clerk JWT; marketplace sellers only carry the relay key, so
// this route exists to keep small vendors out of the store-credential system.
//
// Optional env var TERMINAL_LOCATION_ID: a tml_ Terminal location on the
// platform account. Returned so the app knows where to register the reader
// without local configuration.
//
// Returns: { secret, locationId? }
// ---------------------------------------------------------------------------
async function terminalConnectionToken(request, env) {
  const res = await stripePost("/v1/terminal/connection_tokens", new URLSearchParams(), env.STRIPE_SECRET_KEY);
  const token = await res.json();
  if (!res.ok) return json({ error: token.error?.message ?? "Stripe error" }, res.status);

  return json({ secret: token.secret, locationId: env.TERMINAL_LOCATION_ID ?? null });
}

// ---------------------------------------------------------------------------
// POST /marketplace/terminal/orders/create
//
// Order + card_present PaymentIntent collected in person on the seller's
// iPhone via Tap to Pay. Walk-up buyers usually don't have the app, so
// buyerUserId is optional and defaults to "in-person".
//
// Routed as a destination charge to the seller's Connect account when one is
// registered for sellerUserId (same resolution as /orders/create in the
// deployed worker), keeping the marketplace fee. Without a Connect account the
// funds land in the platform account for manual payout.
//
// Body: {
//   sellerUserId, buyerUserId?, listingId?, listingTitle?,
//   amount (cents), currency, applicationFeeAmount?, metadata?
// }
// Returns: { orderId, paymentIntentId, clientSecret, status }
// ---------------------------------------------------------------------------
async function createTerminalOrder(request, env) {
  const body = await readJSON(request);
  if (!body) return json({ error: "Invalid JSON" }, 400);

  const {
    sellerUserId, buyerUserId = "in-person",
    listingId, listingTitle,
    amount, currency, applicationFeeAmount, metadata = {},
  } = body;

  const attemptId = validAttemptId(body.attemptId);
  if (!attemptId) return json({ error: "attemptId is required (8–128 chars, [A-Za-z0-9_-])" }, 400);
  if (!sellerUserId) return json({ error: "sellerUserId is required" }, 400);
  if (!amount || !Number.isFinite(Number(amount))) return json({ error: "amount is required (cents)" }, 400);
  if (!currency) return json({ error: "currency is required" }, 400);

  const amountCents = Math.round(Number(amount));
  if (amountCents <= 0) return json({ error: "amount must be positive" }, 400);

  const fee = applicationFeeAmount != null
    ? Math.round(Number(applicationFeeAmount))
    : Math.round((amountCents * DEFAULT_PLATFORM_FEE_BPS) / 10000);

  // The deployed worker resolves the seller's Connect account server-side from
  // sellerUserId (registered at Connect onboarding). Reference lookup:
  let sellerAccountId = null;
  try {
    const row = await env.DB.prepare(
      `SELECT account_id FROM seller_accounts WHERE user_id = ?`
    ).bind(sellerUserId).first();
    sellerAccountId = row?.account_id ?? null;
  } catch {
    // Table absent in this reference schema — funds stay on the platform account.
  }

  // Same reserve → create → attach sequence as /orders/create. See there.
  const reservation = await reserveOrder(env, attemptId, {
    buyerUserId, sellerUserId, sellerAccountId,
    listingId: listingId ?? null, listingTitle: listingTitle ?? null, quantity: 1,
    amountCents, currency: String(currency).toLowerCase(), fee: sellerAccountId ? fee : 0,
    metadata, source: "app_terminal",
  });
  if (reservation.error) return reservation.error;
  const row = reservation.row;

  const outcome = await ensurePaymentIntent(env, row, (orderId) => {
    const params = new URLSearchParams({
      amount: String(row.amount),
      currency: row.currency,
      "payment_method_types[]": "card_present",
      "metadata[frydge_order_id]": orderId,
      "metadata[frydge_attempt_id]": attemptId,
      "metadata[seller_user_id]": row.seller_user_id,
      "metadata[collection]": "tap_to_pay",
    });
    if (row.listing_id) params.append("metadata[listing_id]", row.listing_id);
    for (const [k, v] of Object.entries(metadata)) {
      params.append(`metadata[${k}]`, String(v));
    }
    if (row.seller_account_id) {
      params.append("transfer_data[destination]", row.seller_account_id);
      params.append("application_fee_amount", String(row.platform_fee));
    }
    return params;
  });
  if (outcome.error) return outcome.error;

  return json({
    orderId: row.id,
    paymentIntentId: outcome.pi.id,
    clientSecret: outcome.pi.client_secret,
    status: row.status,
    resumed: outcome.resumed,
  });
}

// ---------------------------------------------------------------------------
// POST /marketplace/orders/list
// Body: { userId, role: "buyer" | "seller", limit? }
// ---------------------------------------------------------------------------
async function listOrders(request, env) {
  const body = await readJSON(request);
  if (!body) return json({ error: "Invalid JSON" }, 400);

  const { userId, role = "buyer", limit = 50 } = body;
  if (!userId) return json({ error: "userId is required" }, 400);
  if (role !== "buyer" && role !== "seller") {
    return json({ error: 'role must be "buyer" or "seller"' }, 400);
  }

  const column = role === "buyer" ? "buyer_user_id" : "seller_user_id";
  const capped = Math.min(Math.max(Number(limit) || 50, 1), 200);

  const { results } = await env.DB.prepare(
    `SELECT * FROM orders WHERE ${column} = ? ORDER BY created_at DESC LIMIT ?`
  ).bind(userId, capped).all();

  return json({ orders: (results ?? []).map(shapeOrder) });
}

// ---------------------------------------------------------------------------
// POST /marketplace/orders/get   Body: { orderId }
// ---------------------------------------------------------------------------
async function getOrder(request, env) {
  const body = await readJSON(request);
  if (!body?.orderId) return json({ error: "orderId is required" }, 400);

  const row = await env.DB.prepare(`SELECT * FROM orders WHERE id = ?`)
    .bind(body.orderId).first();
  if (!row) return json({ error: "Order not found" }, 404);

  const { results: events } = await env.DB.prepare(
    `SELECT * FROM order_events WHERE order_id = ? ORDER BY created_at DESC LIMIT 50`
  ).bind(body.orderId).all();

  return json({ order: shapeOrder(row), events: events ?? [] });
}

// ---------------------------------------------------------------------------
// POST /marketplace/orders/mark-ready
// Seller says the goods are ready/handed over.
// Body: { orderId, sellerUserId }
// ---------------------------------------------------------------------------
async function markReady(request, env) {
  const body = await readJSON(request);
  if (!body?.orderId || !body?.sellerUserId) {
    return json({ error: "orderId and sellerUserId are required" }, 400);
  }

  const row = await env.DB.prepare(`SELECT * FROM orders WHERE id = ?`)
    .bind(body.orderId).first();
  if (!row) return json({ error: "Order not found" }, 404);

  if (row.seller_user_id && row.seller_user_id !== body.sellerUserId) {
    return json({ error: "Not the seller on this order" }, 403);
  }

  // Only a paid order can be marked ready — otherwise a seller could mark ready
  // before the money actually arrived.
  if (row.status !== "paid") {
    return json({ error: `Cannot mark ready from status "${row.status}"` }, 409);
  }

  const now = Math.floor(Date.now() / 1000);
  await env.DB.prepare(
    `UPDATE orders SET status = 'ready', seller_marked_ready_at = ?, updated_at = ? WHERE id = ?`
  ).bind(now, now, body.orderId).run();

  await logEvent(env, body.orderId, "seller_ready", row.status, "ready", "app", null);

  return json({ ok: true, orderId: body.orderId, status: "ready" });
}

// ---------------------------------------------------------------------------
// POST /marketplace/orders/confirm-received
// Buyer confirms they got the goods. Terminal happy state.
// Body: { orderId, buyerUserId }
// ---------------------------------------------------------------------------
async function confirmReceived(request, env) {
  const body = await readJSON(request);
  if (!body?.orderId || !body?.buyerUserId) {
    return json({ error: "orderId and buyerUserId are required" }, 400);
  }

  const row = await env.DB.prepare(`SELECT * FROM orders WHERE id = ?`)
    .bind(body.orderId).first();
  if (!row) return json({ error: "Order not found" }, 404);

  if (row.buyer_user_id !== body.buyerUserId) {
    return json({ error: "Not the buyer on this order" }, 403);
  }

  // Allow from paid as well as ready — plenty of in-person handovers happen
  // before the seller remembers to tap anything.
  if (row.status !== "ready" && row.status !== "paid") {
    return json({ error: `Cannot confirm from status "${row.status}"` }, 409);
  }

  const now = Math.floor(Date.now() / 1000);
  await env.DB.prepare(
    `UPDATE orders SET status = 'received', buyer_confirmed_at = ?, updated_at = ? WHERE id = ?`
  ).bind(now, now, body.orderId).run();

  await logEvent(env, body.orderId, "buyer_confirmed", row.status, "received", "app", null);

  return json({ ok: true, orderId: body.orderId, status: "received" });
}

// ---------------------------------------------------------------------------
// POST /marketplace/webhook
//
// The authoritative source for payment status. Stripe signs every delivery;
// we verify before trusting anything.
// ---------------------------------------------------------------------------
async function handleWebhook(request, env) {
  if (!env.STRIPE_WEBHOOK_SECRET) {
    return json({ error: "Webhook secret not configured" }, 503);
  }

  const signature = request.headers.get("Stripe-Signature");
  if (!signature) return json({ error: "Missing Stripe-Signature" }, 400);

  // Signature is computed over the RAW body. Parsing first would break it.
  const raw = await request.text();

  const verified = await verifyStripeSignature(raw, signature, env.STRIPE_WEBHOOK_SECRET);
  if (!verified) return json({ error: "Signature verification failed" }, 400);

  let event;
  try { event = JSON.parse(raw); } catch { return json({ error: "Invalid JSON" }, 400); }

  const object = event.data?.object ?? {};
  const paymentIntentId = object.payment_intent ?? object.id;
  if (typeof event.id !== "string" || !event.id) {
    return json({ error: "Event has no id" }, 400);
  }

  // Always 200 for events we don't handle — Stripe retries non-2xx forever.
  const handled = {
    "payment_intent.succeeded":      "paid",
    "payment_intent.payment_failed": "payment_failed",
    "charge.refunded":               "refunded",
    "charge.dispute.created":        "disputed",
  };

  const incoming = handled[event.type];
  if (!incoming || !paymentIntentId) {
    return json({ received: true, ignored: event.type });
  }

  // Deduplicate by Stripe event ID. The event row is inserted in the SAME batch
  // as the order update below, so if the update fails the event is not recorded
  // and Stripe's redelivery is processed instead of skipped.
  const seen = await env.DB.prepare(`SELECT outcome FROM stripe_events WHERE event_id = ?`)
    .bind(event.id).first();
  if (seen) {
    return json({ received: true, duplicateEvent: event.id, outcome: seen.outcome });
  }

  const now = Math.floor(Date.now() / 1000);
  const row = await env.DB.prepare(`SELECT * FROM orders WHERE payment_intent_id = ?`)
    .bind(paymentIntentId).first();

  if (!row) {
    // No order yet for this intent (created outside this worker, or the create
    // call attached the intent after this event fired). Persist the verified
    // event so it can be reconciled later instead of being acknowledged and lost.
    await recordStripeEvent(env, event, paymentIntentId, null, "unmatched", now);
    return json({ received: true, unknownOrder: paymentIntentId, stored: true });
  }

  const decision = decidePaymentTransition(row.status, incoming);
  const statements = [];

  if (decision.next) {
    statements.push(env.DB.prepare(
      `UPDATE orders SET status = ?, stripe_status = ?, updated_at = ?
         WHERE id = ? AND status = ?`
    ).bind(decision.next, object.status ?? event.type, now, row.id, row.status));
    statements.push(env.DB.prepare(
      `INSERT INTO order_events (order_id, event_type, from_status, to_status, source, detail, created_at)
       VALUES (?,?,?,?,?,?,?)`
    ).bind(row.id, "webhook", row.status, decision.next, "stripe_webhook",
           JSON.stringify({ eventId: event.id, eventType: event.type }), now));
  } else if (decision.refreshStripeStatus) {
    // Fulfilment progress is preserved; only the raw provider status moves.
    statements.push(env.DB.prepare(
      `UPDATE orders SET stripe_status = ?, updated_at = ? WHERE id = ?`
    ).bind(object.status ?? event.type, now, row.id));
  }

  const outcome = decision.next ? `applied:${decision.next}` : decision.reason;
  statements.push(stripeEventInsert(env, event, paymentIntentId, row.id, outcome, now));

  try {
    await env.DB.batch(statements);
  } catch (err) {
    // A concurrent delivery of the same event won the race on the event_id
    // primary key: it has been (or is being) applied. Acknowledge.
    if (String(err?.message ?? err).includes("UNIQUE")) {
      return json({ received: true, duplicateEvent: event.id });
    }
    // Anything else: fail the request so Stripe redelivers.
    return json({ error: "Could not persist webhook" }, 500);
  }

  if (decision.next) {
    return json({ received: true, orderId: row.id, status: decision.next });
  }
  return json({ received: true, orderId: row.id, [decision.reason]: `${row.status} <- ${incoming}` });
}

/**
 * Payment-state transition policy. Payment state and fulfilment progress share
 * the `status` column in this schema, so the rules below keep fulfilment
 * (`ready`, `received`) from being wound back by a redelivered or late payment
 * event, and keep terminal payment outcomes (`refunded`, `disputed`) from being
 * overwritten by anything earlier in the lifecycle.
 *
 *   pending_payment  + paid            -> paid
 *   pending_payment  + payment_failed  -> payment_failed
 *   payment_failed   + paid            -> paid            (retry after decline)
 *   paid/ready/received + payment_failed -> unchanged     (stale failure)
 *   ready/received   + paid            -> unchanged, stripe_status refreshed
 *   any              + refunded/disputed -> refunded/disputed
 *   refunded/disputed + paid/payment_failed -> unchanged
 */
function decidePaymentTransition(current, incoming) {
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

function stripeEventInsert(env, event, paymentIntentId, orderId, outcome, now) {
  return env.DB.prepare(
    `INSERT INTO stripe_events (event_id, event_type, payment_intent_id, order_id, outcome, received_at)
     VALUES (?,?,?,?,?,?)`
  ).bind(event.id, event.type, paymentIntentId, orderId, outcome, now);
}

async function recordStripeEvent(env, event, paymentIntentId, orderId, outcome, now) {
  try {
    await stripeEventInsert(env, event, paymentIntentId, orderId, outcome, now).run();
  } catch {
    // Duplicate delivery of an unmatched event; already stored.
  }
}

/**
 * Verifies Stripe's `Stripe-Signature` header.
 *
 * Format: t=<unix>,v1=<hex hmac>,v1=<hex hmac>...
 * The signed payload is `${t}.${rawBody}`, HMAC-SHA256 with the whsec_ secret.
 */
async function verifyStripeSignature(rawBody, header, secret, toleranceSeconds = 300) {
  const parts = Object.create(null);
  for (const piece of header.split(",")) {
    const idx = piece.indexOf("=");
    if (idx === -1) continue;
    const k = piece.slice(0, idx).trim();
    const v = piece.slice(idx + 1).trim();
    if (k === "v1") (parts.v1 ??= []).push(v);
    else parts[k] = v;
  }

  if (!parts.t || !parts.v1?.length) return false;

  // Reject replays of old deliveries.
  const age = Math.abs(Math.floor(Date.now() / 1000) - Number(parts.t));
  if (!Number.isFinite(age) || age > toleranceSeconds) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${parts.t}.${rawBody}`)
  );

  const expected = [...new Uint8Array(mac)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  // Constant-time compare — a fast-exit compare leaks the signature byte by byte.
  return parts.v1.some((candidate) => timingSafeEqual(candidate, expected));
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function logEvent(env, orderId, type, fromStatus, toStatus, source, detail) {
  try {
    await env.DB.prepare(
      `INSERT INTO order_events (order_id, event_type, from_status, to_status, source, detail, created_at)
       VALUES (?,?,?,?,?,?,?)`
    ).bind(
      orderId, type, fromStatus, toStatus, source,
      detail ? JSON.stringify(detail) : null,
      Math.floor(Date.now() / 1000)
    ).run();
  } catch {
    // Audit logging must never fail the request it is describing.
  }
}

function shapeOrder(row) {
  return {
    id: row.id,
    paymentIntentId: row.payment_intent_id,
    listingId: row.listing_id,
    listingTitle: row.listing_title,
    quantity: row.quantity,
    buyerUserId: row.buyer_user_id,
    sellerUserId: row.seller_user_id,
    sellerAccountId: row.seller_account_id,
    amount: row.amount,
    currency: row.currency,
    platformFee: row.platform_fee,
    status: row.status,
    stripeStatus: row.stripe_status,
    sellerMarkedReadyAt: row.seller_marked_ready_at,
    buyerConfirmedAt: row.buyer_confirmed_at,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

// ---------------------------------------------------------------------------
// Checkout attempts
//
// The client generates one attemptId per checkout and reuses it on every retry.
// The order row is reserved under that attemptId (UNIQUE) before any Stripe
// call, and the PaymentIntent's idempotency key is derived from the reserved
// order ID, so a lost response, an app restart or concurrent taps all resolve
// to one order and one PaymentIntent. A changed payload under the same
// attemptId is rejected rather than silently charged.
// ---------------------------------------------------------------------------

function validAttemptId(value) {
  return typeof value === "string" && /^[A-Za-z0-9_-]{8,128}$/.test(value) ? value : null;
}

/** The fields that must not change between retries of one attempt. */
function attemptFingerprint(o) {
  return JSON.stringify({
    buyer: o.buyerUserId ?? null,
    seller: o.sellerUserId ?? null,
    listing: o.listingId ?? null,
    quantity: Number(o.quantity) || 1,
    amount: Number(o.amountCents),
    currency: String(o.currency).toLowerCase(),
  });
}

function fingerprintOfRow(row) {
  return attemptFingerprint({
    buyerUserId: row.buyer_user_id, sellerUserId: row.seller_user_id,
    listingId: row.listing_id, quantity: row.quantity,
    amountCents: row.amount, currency: row.currency,
  });
}

/**
 * Finds the order already reserved for `attemptId`, or inserts one. Returns
 * `{ row }` or `{ error: Response }`. The insert races safely: if two retries
 * arrive together, the UNIQUE index on attempt_id lets exactly one through and
 * the other reads the winner.
 */
async function reserveOrder(env, attemptId, draft) {
  const fingerprint = attemptFingerprint(draft);

  const resume = (row) => {
    if (fingerprintOfRow(row) !== fingerprint) {
      return { error: json({ error: "attemptId was already used with a different order" }, 409) };
    }
    return { row };
  };

  const existing = await env.DB.prepare(`SELECT * FROM orders WHERE attempt_id = ?`)
    .bind(attemptId).first();
  if (existing) return resume(existing);

  const orderId = `ord_${crypto.randomUUID()}`;
  const now = Math.floor(Date.now() / 1000);
  try {
    await env.DB.prepare(
      `INSERT INTO orders (
         id, attempt_id, payment_intent_id, listing_id, listing_title, quantity,
         buyer_user_id, seller_user_id, seller_account_id,
         amount, currency, platform_fee,
         status, stripe_status, created_at, updated_at, metadata
       ) VALUES (?,?,NULL,?,?,?,?,?,?,?,?,?,'pending_payment',NULL,?,?,?)`
    ).bind(
      orderId, attemptId, draft.listingId, draft.listingTitle, draft.quantity,
      draft.buyerUserId, draft.sellerUserId, draft.sellerAccountId,
      draft.amountCents, draft.currency, draft.fee,
      now, now, JSON.stringify(draft.metadata ?? {})
    ).run();
  } catch (err) {
    const winner = await env.DB.prepare(`SELECT * FROM orders WHERE attempt_id = ?`)
      .bind(attemptId).first();
    if (!winner) throw err;
    return resume(winner);
  }

  await logEvent(env, orderId, "created", null, "pending_payment", draft.source, { attemptId });

  const row = await env.DB.prepare(`SELECT * FROM orders WHERE id = ?`).bind(orderId).first();
  return { row };
}

/**
 * Creates the PaymentIntent for a reserved order, or fetches the existing one
 * when a previous attempt already got that far. `buildParams(orderId)` returns
 * the URLSearchParams for the create call. Returns `{ pi, resumed }` or
 * `{ error: Response }`.
 */
async function ensurePaymentIntent(env, row, buildParams) {
  if (row.payment_intent_id) {
    const res = await stripeGet(`/v1/payment_intents/${row.payment_intent_id}`, env.STRIPE_SECRET_KEY);
    const pi = await res.json();
    if (!res.ok) return { error: json({ error: pi.error?.message ?? "Stripe error" }, res.status) };
    return { pi, resumed: true };
  }

  // One idempotency key per reserved order, identical on every retry.
  const res = await stripePost("/v1/payment_intents", buildParams(row.id), env.STRIPE_SECRET_KEY, `pi:${row.id}`);
  const pi = await res.json();
  if (!res.ok) {
    // 409 = another retry with the same key is in flight at Stripe. The client
    // retries with the same attemptId and resumes once the row is attached.
    return { error: json({ error: pi.error?.message ?? "Stripe error" }, res.status) };
  }

  // Attach. Conditional so a concurrent retry cannot swap in a different intent.
  const now = Math.floor(Date.now() / 1000);
  await env.DB.prepare(
    `UPDATE orders SET payment_intent_id = ?, stripe_status = ?, updated_at = ?
       WHERE id = ? AND (payment_intent_id IS NULL OR payment_intent_id = ?)`
  ).bind(pi.id, pi.status, now, row.id, pi.id).run();

  await logEvent(env, row.id, "payment_intent_attached", "pending_payment", "pending_payment", "app", {
    paymentIntentId: pi.id,
  });

  return { pi, resumed: false };
}

function stripePost(path, params, key, idempotencyKey) {
  const headers = {
    Authorization: `Bearer ${key}`,
    "Content-Type": "application/x-www-form-urlencoded",
  };
  if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;

  return fetch(`https://api.stripe.com${path}`, {
    method: "POST",
    headers,
    body: params.toString(),
  });
}

function stripeGet(path, key) {
  return fetch(`https://api.stripe.com${path}`, {
    method: "GET",
    headers: { Authorization: `Bearer ${key}` },
  });
}

async function readJSON(request) {
  try { return await request.json(); } catch { return null; }
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

function notFound() {
  return new Response(JSON.stringify({ error: "Not Found" }), {
    status: 404,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}
