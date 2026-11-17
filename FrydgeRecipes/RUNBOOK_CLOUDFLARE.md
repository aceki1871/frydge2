# Runbook — Cloudflare Workers

Step by step, specific to Frydge. Every command is copy-pasteable.

**Your setup:** domain `frydge2.com`, three workers, all deployed from
`FrydgeRecipes/`. Wrangler config files live next to the worker they deploy.

| Worker | Config | Routes | Status |
|---|---|---|---|
| `frydge2-recipe-sharing` | `wrangler.toml` | `/recipe/*`, `/images/*`, `/api/share-recipe`, `/.well-known/*` | ✅ deployed |
| `frydge2-stripe-payments` | `wrangler-stripe.toml` | `/stripe/*` | ⚠️ **name mismatch — see below** |
| `frydge2-live-activity` | `wrangler-liveactivity.toml` | `/live-activity/*` | ✅ **deployed 2 Aug 2026** |

## Live Activity worker — DONE

Deployed, secrets set, auth verified.

- Version `107f3843-5bec-4634-86dd-ed9928c507fb`
- Route bound: `frydge2.com/live-activity/*`
- `APNS_KEY_P8` set (piped from the `.p8`, avoiding clipboard mangling)
- `FRYDGE_RELAY_KEY` set to `frydge2liveactivity`
- Unauthenticated POST → `401 Unauthorized` ✅

Auth is **fail-closed**: a missing `FRYDGE_RELAY_KEY` returns `503`, it does not
silently disable the check. The first deploy had this wrong — the guard was
`if (env.FRYDGE_RELAY_KEY && …)`, so an unset secret left the relay open.

Deploys are run from `~/Downloads/frydge-workers/` because Terminal cannot read
iCloud Drive (macOS TCC → `EPERM: uv_cwd`). **Those are copies** — edits made
there must be copied back to `FrydgeRecipes/FrydgeRecipes/`.

Nothing further can be tested until the app builds and yields a real
push-to-start token.

---

## ⚠️ The Stripe worker is already live under a different name

`wrangler deployments list --name frydge2-stripe-payments` → `code 10007, does not
exist`. But `POST /stripe/create-payment-intent` with `{}` returns
`{"error":"Missing or invalid amount"}` — while the code in this repo returns
`"amount and currency are required"`.

Different string, same CORS headers. So an **older build of this same worker** is
serving `/stripe/*` under some other script name.

**Do not deploy `wrangler-stripe.toml` until that name is identified** — you'd
either hit a route conflict or end up with two workers contesting `/stripe/*`.

```
open "https://dash.cloudflare.com/?to=/frydge2.com/workers/routes"
```

Then rename `name =` in `wrangler-stripe.toml` to match, so the deploy updates it
in place rather than creating a second worker.

> **Verified 2 Aug 2026.** `wrangler deployments list --name frydge2-stripe-payments`
> returns `code 10007 — This Worker does not exist on your account`, and
> `GET /stripe/create-payment-intent` returns an empty body from the static host
> rather than the worker's plain-text `Not Found`. The config file's own header
> comment describes exactly this symptom. Meanwhile
> `GET /.well-known/apple-app-site-association` returns real JSON, confirming the
> recipe-sharing worker *is* live — so this is not an account or auth problem.
>
> **Diagnostic worth remembering:** an unbound route falls through to the static
> site. If a `/stripe/*` POST returns 405 with an empty body, the worker isn't
> deployed.

---

## Part 0 — One-time prerequisites

### 0.1 Install Wrangler

```bash
npm install -g wrangler
wrangler --version
```

Anything 3.x or later is fine.

### 0.2 Log in

```bash
wrangler login
```

Opens a browser. Authorise the Cloudflare account that owns `frydge2.com`.

Verify you're in the right account:

```bash
wrangler whoami
```

### 0.3 Confirm the zone exists

```bash
wrangler deployments list --name frydge2-stripe-payments
```

If that errors with "worker not found", the Stripe worker was deployed from the
dashboard rather than the CLI, or you're in the wrong account. Check the
Cloudflare dashboard → Workers & Pages before continuing.

---

## Part 1 — Deploy the Live Activity worker (new)

This is the one that doesn't exist yet.

### 1.1 Set the APNs private key

```bash
cd ~/Library/Mobile\ Documents/com~apple~CloudDocs/FrydgeRecipes/FrydgeRecipes
wrangler secret put APNS_KEY_P8 -c wrangler-liveactivity.toml
```

It will prompt for a value. Paste the **entire contents** of
`AuthKey_7XKRGZRVQD.p8`, including these lines:

```
-----BEGIN PRIVATE KEY-----
MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg...
-----END PRIVATE KEY-----
```

To get it on your clipboard:

```bash
cat ../AuthKey_7XKRGZRVQD.p8 | pbcopy
```

Then paste at the prompt and press Enter twice.

> **Common failure:** pasting only the base64 middle section. The worker's
> `importPKCS8()` strips the BEGIN/END lines itself, but it needs valid PKCS#8
> content. If it's wrong you'll get `JWT signing failed` on the first request.

### 1.2 Set the relay key

```bash
wrangler secret put FRYDGE_RELAY_KEY -c wrangler-liveactivity.toml
```

Enter: `frydge2liveactivity`

This must match `relayKey` in `LiveActivityPushManager.swift` (line ~55). If you
change one, change both.

### 1.3 Deploy

```bash
wrangler deploy -c wrangler-liveactivity.toml
```

Expected output ends with something like:

```
Uploaded frydge2-live-activity (1.2 sec)
Published frydge2-live-activity (0.4 sec)
  frydge2.com/live-activity/*
Current Deployment ID: ...
```

### 1.4 Verify the route bound

```bash
curl -i -X POST https://frydge2.com/live-activity/start \
  -H "Content-Type: application/json" \
  -d '{}'
```

**Expect `401 Unauthorized`** — that means the worker is live and rejecting an
unauthenticated request. 

If you get `405 Method Not Allowed` with an empty body, the route didn't bind and
you're hitting the static site instead. Check the `routes` block in
`wrangler-liveactivity.toml` and that `zone_name = "frydge2.com"` matches your zone.

### 1.5 Test with a real token

Run the app on a device, then in Console.app filter by:

- subsystem: `com.Clark-Online.Recipes`
- category: `LiveActivityPush`

Look for: `Push-to-start token updated (a1b2c3d4e5f6…)`

That's truncated in the log. To get the full token, add a temporary breakpoint or
print in `LiveActivityPushManager.start()`. Then:

```bash
curl -i -X POST https://frydge2.com/live-activity/start \
  -H "Content-Type: application/json" \
  -H "X-Frydge-Key: frydge2liveactivity" \
  -d '{
    "pushToStartToken": "PASTE_FULL_TOKEN_HERE",
    "storeName": "Test Store",
    "items": ["Milk 2L", "Bread", "Eggs"],
    "environment": "development"
  }'
```

**Success:** `{"ok":true,"store":"Test Store","items":3}` and a Live Activity
appears on the device within a second or two.

### 1.6 Troubleshooting the Live Activity worker

| Response | Meaning | Fix |
|---|---|---|
| `401 Unauthorized` | `X-Frydge-Key` missing or wrong | Match `relayKey` in Swift |
| `500 JWT signing failed` | `APNS_KEY_P8` malformed | Re-set the secret with the full PEM |
| `502` + `BadDeviceToken` | environment mismatch | Debug build → `"development"`. TestFlight → `"production"` **and** `aps-environment` must say `production` |
| `502` + `TopicDisallowed` | wrong bundle ID | Topic must be `Clark-Online.Recipes.push-type.liveactivity` |
| `502` + `ExpiredProviderToken` | clock skew or stale JWT | Worker caches 45 min; redeploy to clear |
| `200` but no Live Activity | payload/type mismatch | `attributes-type` must be exactly `ShoppingListActivityAttributes`, and `attributes` must contain exactly `storeName` |
| `405` empty body | route not bound | See 1.4 |

The worker returns APNs' rejection verbatim in the `apns` field, so read it.

---

## Part 2 — The Stripe worker (already live, needs auditing)

The worker is deployed, but its header comment claims secrets are set that
**the code never reads**. Verify what's actually there.

### 2.1 List current secrets

```bash
wrangler secret list -c wrangler-stripe.toml
```

### 2.2 What the code actually uses

Grepping `env.` in `cloudflare-worker-stripe-payments.js` returns exactly two:

| Secret | Used? | Where |
|---|---|---|
| `STRIPE_SECRET_KEY` | ✅ yes | every endpoint |
| `STRIPE_PUBLISHABLE_KEY` | ✅ yes | `/confirm-apple-pay` → `/v1/tokens` |
| `STRIPE_CLIENT_ID` | ❌ **never read** | documented in the header only |
| `STRIPE_WEBHOOK_SECRET` | ❌ **never read** | documented in the header only |

`STRIPE_CLIENT_ID` is only needed for Connect **OAuth**. This worker uses Connect
**Express** (`/v1/accounts` with `type=express`), which doesn't use it. Harmless
but misleading — delete the line from the header comment.

`STRIPE_WEBHOOK_SECRET` matters more: **there is no webhook endpoint at all.**
See Part 3 of the Stripe runbook.

### 2.3 Set the two that matter

```bash
wrangler secret put STRIPE_SECRET_KEY      -c wrangler-stripe.toml
wrangler secret put STRIPE_PUBLISHABLE_KEY -c wrangler-stripe.toml
```

Use **test keys** (`sk_test_…` / `pk_test_…`) until you've tested end to end.

### 2.4 Test each endpoint

**Create a PaymentIntent:**

```bash
curl -s -X POST https://frydge2.com/stripe/create-payment-intent \
  -H "Content-Type: application/json" \
  -d '{"amount": 1250, "currency": "nzd", "metadata": {"test": "true"}}' | jq
```

Expect `{"clientSecret":"pi_..._secret_...","paymentIntentId":"pi_..."}`.

> `amount` is in **cents**. 1250 = $12.50.

**Connect onboarding:**

```bash
curl -s -X POST https://frydge2.com/stripe/connect/onboard \
  -H "Content-Type: application/json" \
  -d '{
    "email": "seller@example.com",
    "returnUrl": "frydge://stripe-connect-return",
    "refreshUrl": "frydge://stripe-connect-refresh"
  }' | jq
```

Expect `{"accountId":"acct_...","onboardingUrl":"https://connect.stripe.com/setup/..."}`.

> Fails with "Only Standard accounts can be created" until Connect is enabled —
> see the Stripe runbook Part 2.

**Account status:**

```bash
curl -s -X POST https://frydge2.com/stripe/connect/account-status \
  -H "Content-Type: application/json" \
  -d '{"accountId": "acct_PASTE_FROM_ABOVE"}' | jq
```

Expect `{"chargesEnabled":false,"payoutsEnabled":false,"detailsSubmitted":false}`
before onboarding is completed — all three flip to `true` afterwards.

**Connect PaymentIntent (5% platform fee):**

```bash
curl -s -X POST https://frydge2.com/stripe/connect/create-intent \
  -H "Content-Type: application/json" \
  -d '{
    "amount": 2000,
    "currency": "nzd",
    "sellerAccountId": "acct_PASTE_HERE"
  }' | jq
```

`applicationFeeAmount` defaults to 5% (100 cents on 2000). Pass it explicitly to
override.

> Fails with "destination account cannot accept charges" until that seller has
> finished onboarding.

`/stripe/confirm-apple-pay` can't be curl-tested — it needs a real
`PKPaymentToken` from a device.

---

## Part 3 — Housekeeping

### 3.1 Undeployed worker

`cloudflare-worker-product-matching.js` has **no wrangler config** and has never
been deployed. Either write one:

```toml
name = "frydge2-product-matching"
main = "cloudflare-worker-product-matching.js"
compatibility_date = "2026-05-25"
routes = [{ pattern = "frydge2.com/products/*", zone_name = "frydge2.com" }]
```

…or delete the file.

### 3.2 Orphan drafts

`stripe-backend-configured.js` and `stripe-backend-example.js` look like earlier
Node/Express drafts superseded by the worker. Confirm, then delete.

### 3.3 Tail logs while testing

```bash
wrangler tail frydge2-live-activity
wrangler tail frydge2-stripe-payments
```

Leave running in a second terminal while you test from the device. This is by far
the fastest way to see what a failing request actually did.

### 3.4 Rolling back

```bash
wrangler deployments list  --name frydge2-live-activity
wrangler rollback <DEPLOYMENT_ID> --name frydge2-live-activity
```

---

## Quick reference — your values

```
Domain            frydge2.com
Apple Team ID     A2H3YQ5U79
Bundle ID         Clark-Online.Recipes
APNs Key ID       7XKRGZRVQD
APNs topic        Clark-Online.Recipes.push-type.liveactivity
Merchant ID       merchant.com.Clark-Online.Recipe
iCloud container  iCloud.com.Clark-Online.Recipe
```
