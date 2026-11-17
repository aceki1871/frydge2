var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// cloudflare-worker-live-activity.js
var TEAM_ID = "A2H3YQ5U79";
var KEY_ID = "7XKRGZRVQD";
var BUNDLE_ID = "Clark-Online.Recipes";
var APNS_TOPIC = `${BUNDLE_ID}.push-type.liveactivity`;
var ATTRIBUTES_TYPE = "ShoppingListActivityAttributes";
var APNS_HOSTS = {
  development: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com"
};
var TOKEN_TTL_MS = 45 * 60 * 1e3;
var cachedJWT = null;
var cachedJWTAt = 0;
var cloudflare_worker_live_activity_default = {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return json({ error: "Method not allowed" }, 405);
    }
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
    const payload = {
      aps: {
        timestamp: Math.floor(Date.now() / 1e3),
        event: "start",
        "attributes-type": ATTRIBUTES_TYPE,
        attributes: {
          storeName
        },
        "content-state": {
          shoppingListItems: list,
          checkedItems: []
        },
        // Shown if the Live Activity can't be presented (e.g. user disabled them).
        alert: {
          title: `You're at ${storeName}`,
          body: list.length ? `${list.length} item${list.length === 1 ? "" : "s"} on your list` : "Your shopping list is empty"
        }
      }
    };
    const apnsResponse = await fetch(`${host}/3/device/${pushToStartToken}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": APNS_TOPIC,
        "apns-push-type": "liveactivity",
        "apns-priority": "10",
        "apns-expiration": String(Math.floor(Date.now() / 1e3) + 3600)
      },
      body: JSON.stringify(payload)
    });
    const apnsBody = await apnsResponse.text();
    if (!apnsResponse.ok) {
      return json(
        {
          error: "APNs rejected the push",
          status: apnsResponse.status,
          apns: apnsBody,
          hint: apnsResponse.status === 400 && apnsBody.includes("BadDeviceToken") ? `Token was issued for a different APNs environment. App sent "${environment}"; check aps-environment in the entitlements.` : void 0
        },
        502
      );
    }
    return json({ ok: true, store: storeName, items: list.length });
  }
};
async function getProviderToken(env) {
  const now = Date.now();
  if (cachedJWT && now - cachedJWTAt < TOKEN_TTL_MS) {
    return cachedJWT;
  }
  const pem = env.APNS_KEY_P8;
  if (!pem) throw new Error("APNS_KEY_P8 secret not set");
  const key = await importPKCS8(pem);
  const header = { alg: "ES256", kid: KEY_ID };
  const claims = { iss: TEAM_ID, iat: Math.floor(now / 1e3) };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claims))}`;
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput)
  );
  cachedJWT = `${signingInput}.${b64urlBytes(new Uint8Array(signature))}`;
  cachedJWTAt = now;
  return cachedJWT;
}
__name(getProviderToken, "getProviderToken");
async function importPKCS8(pem) {
  const cleaned = pem.replace(/-----BEGIN PRIVATE KEY-----/, "").replace(/-----END PRIVATE KEY-----/, "").replace(/\s+/g, "");
  const raw = Uint8Array.from(atob(cleaned), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    raw,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
}
__name(importPKCS8, "importPKCS8");
function b64url(str) {
  return b64urlBytes(new TextEncoder().encode(str));
}
__name(b64url, "b64url");
function b64urlBytes(bytes) {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
__name(b64urlBytes, "b64urlBytes");
function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" }
  });
}
__name(json, "json");
export {
  cloudflare_worker_live_activity_default as default
};
//# sourceMappingURL=cloudflare-worker-live-activity.js.map
