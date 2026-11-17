# Runbook — Stripe

Step by step, specific to Frydge. Pairs with `RUNBOOK_CLOUDFLARE.md`.

**What you're building:** a marketplace where buyers pay with Apple Pay or card,
and sellers receive money via Stripe Connect Express with a 5% platform fee.

Your app's flow, as actually implemented:

```
Buyer taps Pay
  └─ POST /stripe/connect/create-intent   (seller set)   → PaymentIntent + 5% fee
     or POST /stripe/create-payment-intent (no seller)
  └─ Apple Pay sheet (PassKit) → PKPaymentToken
  └─ POST /stripe/confirm-apple-pay
       ├─ /v1/tokens          (publishable key)  raw Apple Pay data → Stripe token
       ├─ /v1/payment_methods (secret key)       token → PaymentMethod
       └─ /v1/payment_intents/:id/confirm        → succeeded
```

---

## Part 1 — Account and keys

### 1.1 Create/access the account

<https://dashboard.stripe.com>. Use the **Test mode** toggle (top right) for
everything until Part 6.

### 1.2 Get your API keys

Developers → **API keys**.

| Key | Looks like | Goes where |
|---|---|---|
| Publishable | `pk_test_51…` | Worker secret **and** the iOS app |
| Secret | `sk_test_51…` | Worker secret **only — never in the app** |

> The publishable key is safe to ship in the app. The secret key must never leave
> the worker. If it ever lands in the iOS binary, roll it immediately.

### 1.3 Set the worker secrets

```bash
cd ~/Library/Mobile\ Documents/com~apple~CloudDocs/FrydgeRecipes/FrydgeRecipes
wrangler secret put STRIPE_SECRET_KEY      -c wrangler-stripe.toml
wrangler secret put STRIPE_PUBLISHABLE_KEY -c wrangler-stripe.toml
```

Both are needed. The Apple Pay flow calls `/v1/tokens` with the **publishable**
key (Stripe requires that specifically) and everything else with the secret key.

### 1.4 Set the publishable key in the app

The app currently ships with `StripeConfig.publishableKey` empty, so
`isConfigured` is false until a user finds the setup screen.

Two options:

**A. Hardcode the default** (recommended — the key is public by design). In
`StripeConfig.swift`:

```swift
static let defaultPublishableKey = "pk_test_51..."

static var publishableKey: String {
    get {
        let stored = UserDefaults.standard.string(forKey: publishableKeyKey) ?? ""
        return stored.isEmpty ? defaultPublishableKey : stored
    }
    set { UserDefaults.standard.set(newValue, forKey: publishableKeyKey) }
}
```

**B. Enter it manually** each install via the Quick Stripe Setup screen. Fine for
testing, not for shipping.

`backendBaseURL` already defaults to `https://frydge2.com/stripe`, so that's done.

---

## Part 2 — Enable Connect (required for seller payouts)

Without this, `/stripe/connect/onboard` fails.

1. Dashboard → **Connect** → **Get started**
2. Choose **Platform or marketplace**
3. Fill in the platform profile — business name, support email, statement descriptor
4. Settings → Connect → **Express** must be enabled

### 2.1 Set the Connect branding

Settings → Connect → **Branding**. Sellers see this during onboarding. Set at
minimum: business name, icon, brand colour.

### 2.2 Configure the redirect

Your app opens onboarding in `ASWebAuthenticationSession` and expects these deep
links back (from `StripeConnectManager.swift:115-116`):

```
frydge://stripe-connect-return
frydge://stripe-connect-refresh
```

`frydge` is already registered in `Info.plist` under `CFBundleURLSchemes`, so no
change needed. Express account links don't require pre-registering redirect URLs
in the dashboard — they're passed per-request.

### 2.3 Test it

```bash
curl -s -X POST https://frydge2.com/stripe/connect/onboard \
  -H "Content-Type: application/json" \
  -d '{"email":"seller@example.com",
       "returnUrl":"frydge://stripe-connect-return",
       "refreshUrl":"frydge://stripe-connect-refresh"}' | jq
```

Open the returned `onboardingUrl` in a browser. In test mode Stripe offers a
**"Skip this form"** button — use it to instantly create a fully-onboarded test
seller. Then confirm:

```bash
curl -s -X POST https://frydge2.com/stripe/connect/account-status \
  -H "Content-Type: application/json" \
  -d '{"accountId":"acct_..."}' | jq
```

All three flags should now be `true`.

> Onboarding links are **single-use and expire in ~5 minutes**. Generate a fresh
> one each time — that's what `refreshUrl` is for.

---

## Part 3 — Webhooks ⚠️ not implemented

**Your worker has no webhook endpoint.** `STRIPE_WEBHOOK_SECRET` is documented in
the header comment but never read by the code.

This matters more than it sounds. Without webhooks:

- if the app is killed between "Apple Pay authorised" and "confirm returned", you
  never learn whether the payment succeeded
- disputes, refunds and failed payouts don't reach your system
- `payment_intent.succeeded` is the only trustworthy confirmation a payment
  completed — the client's word isn't sufficient

This is the same gap as the missing order model: money moves and nothing durable
records it.

**When you're ready**, the endpoint needs to:

1. Read the raw request body (not parsed JSON — signature is over raw bytes)
2. Verify `Stripe-Signature` against `STRIPE_WEBHOOK_SECRET` using HMAC-SHA256
3. Handle at minimum: `payment_intent.succeeded`, `payment_intent.payment_failed`,
   `account.updated`, `charge.dispute.created`
4. Return 200 fast — Stripe retries on timeout

Then register it: Dashboard → Developers → **Webhooks** → Add endpoint →
`https://frydge2.com/stripe/webhook`, select those events, copy the `whsec_…` into
the secret.

Say the word and I'll write it — it's ~120 lines and pairs naturally with the
order model.

---

## Part 4 — Apple Pay

Three separate places must agree, and a mismatch in any one fails silently.

### 4.1 Apple Developer portal

1. <https://developer.apple.com/account> → Certificates, IDs & Profiles
2. Identifiers → **Merchant IDs** → confirm `merchant.com.Clark-Online.Recipe` exists
3. Identifiers → App IDs → `Clark-Online.Recipes` → **Apple Pay Payment Processing**
   enabled, and that merchant ID selected

### 4.2 Xcode

Signing & Capabilities → **Apple Pay** → `merchant.com.Clark-Online.Recipe` ticked.

Already correct in `FrydgeRecipes.entitlements`:

```xml
<key>com.apple.developer.in-app-payments</key>
<array><string>merchant.com.Clark-Online.Recipe</string></array>
```

And now correct in code — `StripeConfig.defaultMerchantIdentifier` was previously
the template placeholder `merchant.com.yourcompany.frydge`, which silently broke
Apple Pay for anyone who hadn't run setup.

### 4.3 Stripe dashboard

Settings → Payments → **Apple Pay** → add `merchant.com.Clark-Online.Recipe`.

> **You do not need Apple Pay domain verification.** That's for Apple Pay on the
> Web. Your app uses PassKit in-app, which doesn't require the
> `apple-developer-merchantid-domain-association` file. You already have one in
> `.well-known/` — harmless, but it's not what makes in-app Apple Pay work.

### 4.4 Test it

Apple Pay **cannot be tested in the Simulator** for real tokens. On a physical
device:

1. Wallet → add a [Stripe test card](https://docs.stripe.com/testing#cards)
2. Run a Debug build, go to checkout, tap the Apple Pay button
3. Watch `wrangler tail frydge2-stripe-payments` for the `/confirm-apple-pay` call

Expected worker response: `{"success":true,"paymentIntentId":"pi_...","status":"succeeded"}`

| Error | Cause |
|---|---|
| `Apple Pay token error: …` | `STRIPE_PUBLISHABLE_KEY` not set on the worker |
| `Payment status: requires_action` | 3DS required — test card that needs SCA; the worker returns 402 and the app has no handler for this |
| Sheet doesn't appear | merchant ID mismatch between entitlement, portal and Stripe |
| `PaymentMethod error` | secret key wrong or in the wrong mode (test key + live intent) |

---

## Part 5 — Tap to Pay (optional)

Only if you want sellers taking contactless payments on their own iPhone.

1. Stripe requires **explicit approval** — request it: Dashboard → Terminal →
   Tap to Pay on iPhone
2. Create a Terminal Location: Dashboard → Terminal → Locations → Add
3. Copy the `tml_…` ID
4. In the app: Quick Stripe Setup → Terminal Location ID field, or set
   `StripeConfig.terminalLocationId` directly

`StripeConfig.hasTerminalLocation` checks the `tml_` prefix. The
`stripe-terminal-ios` SPM package is already a dependency.

Requires iPhone XS or later, iOS 16.7+, and the entitlement
`com.apple.developer.proximity-reader.payment.acceptance` — **which is not in
your entitlements file**. You'll need to request it from Apple and add it.

---

## Part 6 — Going live

Work through in order.

- [ ] Full test-mode purchase, end to end, on a physical device
- [ ] Connect seller onboarded and `chargesEnabled: true`
- [ ] Platform fee lands correctly (check the Stripe dashboard payment detail)
- [ ] **Order model built** — currently payment succeeds and nothing persists
- [ ] **Webhook endpoint built and registered** — see Part 3
- [ ] Activate your Stripe account (business details, bank account, tax info)
- [ ] Swap both worker secrets to live keys:
      ```bash
      wrangler secret put STRIPE_SECRET_KEY      -c wrangler-stripe.toml
      wrangler secret put STRIPE_PUBLISHABLE_KEY -c wrangler-stripe.toml
      ```
- [ ] Swap the publishable key in the app to `pk_live_…`
- [ ] Confirm the platform fee percentage is what you actually want (hardcoded 5%
      at `cloudflare-worker-stripe-payments.js:265`)
- [ ] Re-test with a real card and a small real amount
- [ ] Refund it, confirm the refund flows back

> **Test and live keys are not interchangeable.** A `pk_test_` in the app with an
> `sk_live_` on the worker produces confusing "No such payment_intent" errors.
> Change both together.

---

## Known gaps in the current implementation

Found while reading the code — none of these are configuration problems:

1. **No order model.** `MarketplaceCheckoutView` takes payment and calls
   `dismiss()`. Nothing persists. Neither buyer nor seller has a record.
2. **No webhooks.** Part 3.
3. **No 3DS/SCA handling.** The worker returns 402 on `requires_action` and the
   app has no path to present the challenge. Fine in NZ for low-value card
   payments; will fail for UK/EU customers where SCA is mandatory — and you have
   UK stores in your store list.
4. **Platform fee is hardcoded 5%** in the worker with no per-listing override
   reaching it from the app.
5. **No idempotency keys.** A retried `/create-payment-intent` creates a second
   PaymentIntent. Stripe supports `Idempotency-Key` on the request header; the
   worker doesn't send one.

Items 1–3 are what stand between this and taking real money safely.

---

## Quick reference

```
Worker base       https://frydge2.com/stripe
Merchant ID       merchant.com.Clark-Online.Recipe
Bundle ID         Clark-Online.Recipes
Apple Team ID     A2H3YQ5U79
Platform fee      5% (worker line 265)
Connect type      Express
Return URL        frydge://stripe-connect-return
Refresh URL       frydge://stripe-connect-refresh
```

Test cards: <https://docs.stripe.com/testing>
- `4242 4242 4242 4242` — succeeds
- `4000 0025 0000 3155` — requires 3DS (will currently fail in-app, see gap 3)
- `4000 0000 0000 9995` — declined, insufficient funds
