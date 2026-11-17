/**
 * Cloudflare Worker — Live Activity push-to-start relay for Frydge.
 *
 * WHAT IT DOES
 *   Receives an arrival ping from the app and relays it to APNs as a
 *   push-to-start Live Activity notification. ActivityKit will not let an app
 *   start a Live Activity from the background, so a geofence arrival can only
 *   raise one via APNs. This is that hop.
 *
 * STATELESS BY DESIGN
 *   The device sends its own push-to-start token with each request, so this
 *   Worker never stores device tokens. Nothing to leak, nothing to expire.
 *
 * ROUTE
 *   POST https://frydge2.com/live-activity/start
 *
 * SECRETS (set once, never commit):
 *   wrangler secret put APNS_KEY_P8   -c wrangler-liveactivity.toml
 *   wrangler secret put FRYDGE_RELAY_KEY -c wrangler-liveactivity.toml
 *
 *   APNS_KEY_P8 is the full contents of AuthKey_7XKRGZRVQD.p8, including the
 *   -----BEGIN PRIVATE KEY----- / -----END PRIVATE KEY----- lines.
 *
 * REQUEST BODY
 *   {
 *     "pushToStartToken": "<hex>",
 *     "storeName": "Pak'nSave Westgate",
 *     "items": ["Milk 2L", "Bread"],
 *     "environment": "development" | "production"
 *   }
 */

const TEAM_ID = "A2H3YQ5U79";
const KEY_ID = "7XKRGZRVQD";
const BUNDLE_ID = "Clark-Online.Recipes";

// Live Activity pushes use a dedicated topic suffix.
const APNS_TOPIC = `${BUNDLE_ID}.push-type.liveactivity`;

// Must match the `attributes-type` to the Swift ActivityAttributes type name.
const ATTRIBUTES_TYPE = "ShoppingListActivityAttributes";

const APNS_HOSTS = {
  development: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
};

// APNs caps provider tokens at 1 hour; refresh well inside that.
const TOKEN_TTL_MS = 45 * 60 * 1000;
let cachedJWT = null;
let cachedJWTAt = 0;

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return json({ error: "Method not allowed" }, 405);
    }

    // Fail CLOSED. This was previously `if (env.FRYDGE_RELAY_KEY && ...)`, which
    // meant a missing secret disabled the check entirely and left the relay open
    // to anyone. A misconfiguration should never silently remove authentication.
    if (!env.FRYDGE_RELAY_KEY) {
      return json({ error: "Relay key not configured on the Worker" }, 503);
    }
    if (request.headers.get("X-Frydge-Key") !== env.FRYDGE_RELAY_KEY) {
      return json({ error: "Unauthorized" }, 401);
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: "Invalid JSON" }, 400);
    }

    const { pushToStartToken, storeName, items, environment } = body || {};

    if (!pushToStartToken || typeof pushToStartToken !== "string") {
      return json({ error: "pushToStartToken required" }, 400);
    }
    if (!storeName || typeof storeName !== "string") {
      return json({ error: "storeName required" }, 400);
    }
    if (!/^[0-9a-fA-F]+$/.test(pushToStartToken)) {
      return json({ error: "pushToStartToken must be hex" }, 400);
    }

    const host = APNS_HOSTS[environment] || APNS_HOSTS.production;
    const list = Array.isArray(items) ? items.filter((s) => typeof s === "string") : [];

    let jwt;
    try {
      jwt = await getProviderToken(env);
    } catch (err) {
      return json({ error: "JWT signing failed", detail: String(err) }, 500);
    }

    // Live Activity push payload. `event: "start"` is what creates the activity;
    // `attributes` must match the Swift ActivityAttributes exactly or APNs
    // accepts the push and iOS silently drops it.
    const payload = {
      aps: {
        timestamp: Math.floor(Date.now() / 1000),
        event: "start",
        "attributes-type": ATTRIBUTES_TYPE,
        attributes: {
          storeName: storeName,
        },
        "content-state": {
          shoppingListItems: list,
          checkedItems: [],
          // Mirrors attributes.storeName. The app keeps the store in the
          // content state so one activity can retarget as the shopper moves
          // between stores; attributes are frozen by ActivityKit.
          storeName: storeName,
        },
        // Shown if the Live Activity can't be presented (e.g. user disabled them).
        alert: {
          title: `You're at ${storeName}`,
          body: list.length
            ? `${list.length} item${list.length === 1 ? "" : "s"} on your list`
            : "Your shopping list is empty",
        },
      },
    };

    const apnsResponse = await fetch(`${host}/3/device/${pushToStartToken}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": APNS_TOPIC,
        "apns-push-type": "liveactivity",
        "apns-priority": "10",
        "apns-expiration": String(Math.floor(Date.now() / 1000) + 3600),
      },
      body: JSON.stringify(payload),
    });

    const apnsBody = await apnsResponse.text();

    if (!apnsResponse.ok) {
      // Surface the APNs reason verbatim — "BadDeviceToken" almost always means
      // the environment doesn't match the app's aps-environment entitlement.
      return json(
        {
          error: "APNs rejected the push",
          status: apnsResponse.status,
          apns: apnsBody,
          hint:
            apnsResponse.status === 400 && apnsBody.includes("BadDeviceToken")
              ? `Token was issued for a different APNs environment. App sent "${environment}"; check aps-environment in the entitlements.`
              : undefined,
        },
        502
      );
    }

    return json({ ok: true, store: storeName, items: list.length });
  },
};

// MARK: - APNs provider token (ES256 JWT)

async function getProviderToken(env) {
  const now = Date.now();
  if (cachedJWT && now - cachedJWTAt < TOKEN_TTL_MS) {
    return cachedJWT;
  }

  const pem = env.APNS_KEY_P8;
  if (!pem) throw new Error("APNS_KEY_P8 secret not set");

  const key = await importPKCS8(pem);

  const header = { alg: "ES256", kid: KEY_ID };
  const claims = { iss: TEAM_ID, iat: Math.floor(now / 1000) };

  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claims))}`;

  // WebCrypto returns the raw r||s pair (64 bytes), which is exactly the
  // JWS ES256 signature format. No DER unwrapping needed.
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput)
  );

  cachedJWT = `${signingInput}.${b64urlBytes(new Uint8Array(signature))}`;
  cachedJWTAt = now;
  return cachedJWT;
}

async function importPKCS8(pem) {
  const cleaned = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");

  const raw = Uint8Array.from(atob(cleaned), (c) => c.charCodeAt(0));

  return crypto.subtle.importKey(
    "pkcs8",
    raw,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
}

// MARK: - Helpers

function b64url(str) {
  return b64urlBytes(new TextEncoder().encode(str));
}

function b64urlBytes(bytes) {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}
