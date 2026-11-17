/**
 * Cloudflare Worker — Frydge Stripe backend
 *
 * Deploy to: frydge2.com/stripe/*
 *
 * Required secrets (Cloudflare Dashboard → Worker → Settings → Variables & Secrets):
 *   STRIPE_SECRET_KEY      — sk_live_... or sk_test_...       ✅ already set
 *   STRIPE_PUBLISHABLE_KEY — pk_live_... or pk_test_...       ← ADD THIS (needed for Apple Pay token)
 *   STRIPE_CLIENT_ID       — ca_... (Connect client ID)       ✅ already set
 *   STRIPE_WEBHOOK_SECRET  — whsec_...                        ✅ already set
 *
 * Endpoints:
 *   POST /stripe/create-payment-intent      — Standard PaymentIntent (no Connect routing)
 *   POST /stripe/confirm-apple-pay          — Convert Apple Pay token → confirm PaymentIntent
 *   POST /stripe/connect/onboard            — Create Stripe Connect Express account + link
 *   POST /stripe/connect/account-status     — Check if a Connect account can accept charges
 *   POST /stripe/connect/create-intent      — PaymentIntent routed to a seller's Connect account
 */

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, X-Frydge-Key',
};

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS });
    }

    const { pathname } = new URL(request.url);

    // Every route here creates a PaymentIntent, mints a Connect onboarding link
    // or reads a Connect account with the platform secret key. None of that
    // may be reachable anonymously. The app sends the relay key as
    // `X-Frydge-Key` on all `/stripe/*` requests (see FrydgeBackend.swift).
    //
    // Fail CLOSED: a missing secret must disable the routes, not the check.
    // The secret is `wrangler secret put FRYDGE_RELAY_KEY` for this worker.
    //
    // This is a shared-client credential, not proof of a person's identity.
    // Per-user authorization (who may onboard which seller, who may charge
    // whom) still has to be established with a verified server session.
    if (!env.FRYDGE_RELAY_KEY) {
      return jsonError('Relay key not configured on the Worker', 503);
    }
    if (request.headers.get('X-Frydge-Key') !== env.FRYDGE_RELAY_KEY) {
      return jsonError('Unauthorized', 401);
    }

    switch (pathname) {
      case '/stripe/create-payment-intent':
        return request.method === 'POST' ? createPaymentIntent(request, env) : notFound();

      case '/stripe/confirm-apple-pay':
        return request.method === 'POST' ? confirmApplePay(request, env) : notFound();

      case '/stripe/connect/onboard':
        return request.method === 'POST' ? connectOnboard(request, env) : notFound();

      case '/stripe/connect/account-status':
        return request.method === 'POST' ? connectAccountStatus(request, env) : notFound();

      case '/stripe/connect/create-intent':
        return request.method === 'POST' ? connectCreateIntent(request, env) : notFound();

      default:
        return notFound();
    }
  },
};

// ---------------------------------------------------------------------------
// POST /stripe/create-payment-intent
// Body: { amount: number (cents), currency: string, metadata?: object }
// ---------------------------------------------------------------------------
async function createPaymentIntent(request, env) {
  let body;
  try { body = await request.json(); } catch { return jsonError('Invalid JSON body', 400); }

  const { amount, currency, metadata = {} } = body;
  if (!amount || !currency) return jsonError('amount and currency are required', 400);

  const params = new URLSearchParams({
    amount: String(Math.round(Number(amount))),
    currency: String(currency).toLowerCase(),
    'payment_method_types[]': 'card',
  });
  for (const [k, v] of Object.entries(metadata)) {
    params.append(`metadata[${k}]`, String(v));
  }

  const res = await stripePost('/v1/payment_intents', params, env.STRIPE_SECRET_KEY);
  const pi = await res.json();
  if (!res.ok) return jsonError(pi.error?.message ?? 'Stripe error', res.status);

  return jsonOK({ clientSecret: pi.client_secret, paymentIntentId: pi.id });
}

// ---------------------------------------------------------------------------
// POST /stripe/confirm-apple-pay
//
// Converts a raw Apple Pay PKPaymentToken into a Stripe PaymentMethod and
// confirms an existing PaymentIntent. Full server-side flow, no Stripe iOS SDK needed.
//
// Flow:
//   1. iOS creates a PaymentIntent via /create-payment-intent or /connect/create-intent
//   2. iOS presents Apple Pay sheet (PassKit), gets PKPayment on authorisation
//   3. iOS POSTs here with the token data
//   4. This endpoint:
//        a. Creates a Stripe Token from the raw Apple Pay paymentData (publishable key)
//        b. Creates a Stripe PaymentMethod from that token (secret key)
//        c. Confirms the PaymentIntent
//
// Body: {
//   paymentIntentId: string,
//   paymentData: string,            ← base64-encoded PKPaymentToken.paymentData
//   transactionIdentifier: string,  ← PKPaymentToken.transactionIdentifier
//   paymentNetwork?: string,        ← e.g. "Visa", "MasterCard"
//   sellerAccountId?: string        ← acct_... (Connect); if present adds transfer_data
// }
// ---------------------------------------------------------------------------
async function confirmApplePay(request, env) {
  let body;
  try { body = await request.json(); } catch { return jsonError('Invalid JSON body', 400); }

  const { paymentIntentId, paymentData, transactionIdentifier, paymentNetwork, sellerAccountId } = body;
  if (!paymentIntentId || !paymentData || !transactionIdentifier) {
    return jsonError('paymentIntentId, paymentData, and transactionIdentifier are required', 400);
  }

  // Step 1 — Create Stripe Token from Apple Pay data (requires publishable key per Stripe docs)
  const tokenParams = new URLSearchParams({
    pk_token: paymentData,
    pk_token_transaction_identifier: transactionIdentifier,
  });
  if (paymentNetwork) tokenParams.append('pk_token_payment_network', paymentNetwork);

  const tokenRes = await stripePost('/v1/tokens', tokenParams, env.STRIPE_PUBLISHABLE_KEY);
  const tokenData = await tokenRes.json();
  if (!tokenRes.ok) {
    return jsonError(`Apple Pay token error: ${tokenData.error?.message ?? 'unknown'}`, 400);
  }

  // Step 2 — Create PaymentMethod from the Stripe token
  const pmParams = new URLSearchParams({
    'type': 'card',
    'card[token]': tokenData.id,
  });
  const pmRes = await stripePost('/v1/payment_methods', pmParams, env.STRIPE_SECRET_KEY);
  const pm = await pmRes.json();
  if (!pmRes.ok) {
    return jsonError(`PaymentMethod error: ${pm.error?.message ?? 'unknown'}`, 400);
  }

  // Step 3 — Confirm the PaymentIntent
  const confirmParams = new URLSearchParams({
    payment_method: pm.id,
    return_url: 'frydge://payment-return',
  });
  if (sellerAccountId) {
    confirmParams.append('transfer_data[destination]', sellerAccountId);
  }

  const confirmRes = await stripePost(
    `/v1/payment_intents/${paymentIntentId}/confirm`,
    confirmParams,
    env.STRIPE_SECRET_KEY
  );
  const pi = await confirmRes.json();
  if (!confirmRes.ok) {
    return jsonError(`Confirmation error: ${pi.error?.message ?? 'unknown'}`, 400);
  }

  if (pi.status !== 'succeeded') {
    return jsonError(`Payment status: ${pi.status}. Additional action may be required.`, 402);
  }

  return jsonOK({ success: true, paymentIntentId: pi.id, status: pi.status });
}

// ---------------------------------------------------------------------------
// POST /stripe/connect/onboard
//
// Creates a Stripe Connect Express account for a new marketplace seller and
// returns a one-time onboarding URL. Open it in ASWebAuthenticationSession.
//
// Also handles *resuming* onboarding for a seller who already has an account
// but hasn't finished (the "Complete setup" button): pass existingAccountId
// and we skip account creation, just minting a fresh account_link for it.
//
// Body:   { email?: string, existingAccountId?: string, returnUrl: string, refreshUrl: string }
// Response: { accountId: string, onboardingUrl: string }
// ---------------------------------------------------------------------------
async function connectOnboard(request, env) {
  let body;
  try { body = await request.json(); } catch { return jsonError('Invalid JSON body', 400); }

  const { email, returnUrl, refreshUrl, existingAccountId } = body;
  if (!returnUrl || !refreshUrl) {
    return jsonError('returnUrl and refreshUrl are required', 400);
  }

  // Resume flow: reuse the caller's existing account instead of creating one.
  let accountId = existingAccountId?.trim();

  if (!accountId) {
    // New seller — email is required to create the Express account.
    if (!email) return jsonError('email is required to create a new account', 400);

    const accountParams = new URLSearchParams({
      'type': 'express',
      email,
      'capabilities[card_payments][requested]': 'true',
      'capabilities[transfers][requested]': 'true',
      'business_type': 'individual',
    });
    const accountRes = await stripePost('/v1/accounts', accountParams, env.STRIPE_SECRET_KEY);
    const account = await accountRes.json();
    if (!accountRes.ok) {
      return jsonError(`Account creation error: ${account.error?.message ?? 'unknown'}`, 400);
    }
    accountId = account.id;
  }

  // Generate onboarding link (single-use, expires after ~5 min)
  const linkParams = new URLSearchParams({
    account: accountId,
    refresh_url: refreshUrl,
    return_url: returnUrl,
    type: 'account_onboarding',
  });
  const linkRes = await stripePost('/v1/account_links', linkParams, env.STRIPE_SECRET_KEY);
  const link = await linkRes.json();
  if (!linkRes.ok) {
    return jsonError(`Account link error: ${link.error?.message ?? 'unknown'}`, 400);
  }

  return jsonOK({ accountId, onboardingUrl: link.url });
}

// ---------------------------------------------------------------------------
// POST /stripe/connect/account-status
// Body:     { accountId: string }
// Response: { chargesEnabled: bool, payoutsEnabled: bool, detailsSubmitted: bool }
// ---------------------------------------------------------------------------
async function connectAccountStatus(request, env) {
  let body;
  try { body = await request.json(); } catch { return jsonError('Invalid JSON body', 400); }

  const { accountId } = body;
  if (!accountId) return jsonError('accountId is required', 400);

  const res = await fetch(`https://api.stripe.com/v1/accounts/${accountId}`, {
    headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` },
  });
  const account = await res.json();
  if (!res.ok) return jsonError(account.error?.message ?? 'Stripe error', res.status);

  return jsonOK({
    chargesEnabled: account.charges_enabled,
    payoutsEnabled: account.payouts_enabled,
    detailsSubmitted: account.details_submitted,
  });
}

// ---------------------------------------------------------------------------
// POST /stripe/connect/create-intent
//
// Creates a PaymentIntent that routes funds to a seller's Connect account,
// retaining a platform fee (default 5%).
//
// Body: {
//   amount: number (cents),
//   currency: string,
//   sellerAccountId: string,       ← acct_... Stripe Connect ID
//   applicationFeeAmount?: number, ← cents kept as platform fee (default = 5%)
//   metadata?: object
// }
// Response: { clientSecret: string, paymentIntentId: string }
// ---------------------------------------------------------------------------
async function connectCreateIntent(request, env) {
  let body;
  try { body = await request.json(); } catch { return jsonError('Invalid JSON body', 400); }

  const { amount, currency, sellerAccountId, applicationFeeAmount, metadata = {} } = body;
  if (!amount || !currency || !sellerAccountId) {
    return jsonError('amount, currency, and sellerAccountId are required', 400);
  }

  const roundedAmount = Math.round(Number(amount));
  const feeAmount = applicationFeeAmount != null
    ? Math.round(Number(applicationFeeAmount))
    : Math.round(roundedAmount * 0.05); // 5% platform fee

  const params = new URLSearchParams({
    amount: String(roundedAmount),
    currency: String(currency).toLowerCase(),
    'payment_method_types[]': 'card',
    'transfer_data[destination]': sellerAccountId,
    application_fee_amount: String(feeAmount),
  });
  for (const [k, v] of Object.entries(metadata)) {
    params.append(`metadata[${k}]`, String(v));
  }

  const res = await stripePost('/v1/payment_intents', params, env.STRIPE_SECRET_KEY);
  const pi = await res.json();
  if (!res.ok) return jsonError(pi.error?.message ?? 'Stripe error', res.status);

  return jsonOK({ clientSecret: pi.client_secret, paymentIntentId: pi.id });
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

function stripePost(path, params, key) {
  return fetch(`https://api.stripe.com${path}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: params.toString(),
  });
}

function jsonOK(data) {
  return new Response(JSON.stringify(data), {
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

function jsonError(message, status) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

function notFound() {
  return new Response('Not Found', { status: 404 });
}
