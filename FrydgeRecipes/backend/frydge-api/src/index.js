// frydge-api — Cloudflare Worker behind frydge-api.davekitson-read.workers.dev.
//
// Source reconstructed on 2 Nov 2026 from the deployed bundle
// (../../deployed/frydge-api/index.js, version a337639c) and then patched for
// repair-plan workstream F: idempotent checkout attempts, webhook event
// de-duplication with fulfilment-preserving transitions, conditional
// seller/buyer updates, the /marketplace/config launch gate and a server-side
// marketplace kill switch. Everything outside the marketplace section
// (/api/* portal auth, orgs, venues, timesheets, products, legacy /stripe/*)
// is the deployed code unchanged.
import {
  MARKETPLACE_FEE_BPS,
  HANDLED_EVENTS,
  validAttemptId,
  attemptFingerprint,
  fingerprintOfRow,
  decidePaymentTransition
} from "./marketplace-policy.js";

var CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET,POST,PATCH,DELETE,OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type,Authorization,X-Frydge-Key,Stripe-Signature"
};
function json(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json", ...CORS } });
}
function err(msg, status = 400) {
  return json({ error: msg }, status);
}
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return mismatch === 0;
}
async function verifyStripeSignature(rawBody, sigHeader, secret, toleranceSec = 300) {
  if (!sigHeader || !secret) return null;
  const parts = Object.fromEntries(sigHeader.split(",").map((p) => p.split("=", 2)).filter((p) => p.length === 2));
  const timestamp = parts.t, expected = parts.v1;
  if (!timestamp || !expected) return null;
  const age = Math.abs(Math.floor(Date.now() / 1e3) - Number(timestamp));
  if (!Number.isFinite(age) || age > toleranceSec) return null;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${rawBody}`));
  const computed = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return timingSafeEqual(computed, expected) ? JSON.parse(rawBody) : null;
}
var SUPER_ADMIN_EMAILS = ["josh1871@me.com"];
export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") return new Response(null, { headers: CORS });
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;
    if (path === "/marketplace/webhook") {
      return method === "POST" ? handleMarketplaceWebhook(request, env) : err("Not found", 404);
    }
    if (path.startsWith("/marketplace/")) {
      if (!env.FRYDGE_RELAY_KEY) return err("Relay key not configured on the Worker", 503);
      if (request.headers.get("X-Frydge-Key") !== env.FRYDGE_RELAY_KEY) return err("Unauthorized", 401);
      // Launch gate read by MarketplaceAvailability in the app. MARKETPLACE_ENABLED
      // is a plain var in wrangler.toml; anything other than "true" is OFF. This
      // is the server-side half of the kill switch: the create routes below also
      // refuse while it is off.
      if (path === "/marketplace/config") {
        if (method !== "GET") return err("Not found", 404);
        return json({ marketplaceEnabled: marketplaceEnabled(env) });
      }
      if (method !== "POST") return err("Not found", 404);
      return routeMarketplace(path, request, env);
    }
    if (path.startsWith("/stripe/")) {
      if (method !== "POST") return err("Not found", 404);
      if (!env.FRYDGE_RELAY_KEY) return err("Relay key not configured on the Worker", 503);
      if (request.headers.get("X-Frydge-Key") !== env.FRYDGE_RELAY_KEY) return err("Unauthorized", 401);
      return routeStripeLegacy(path, request, env);
    }
    if (path === "/api/stripe/webhook" && method === "POST") return handleStripeWebhook(request, env);
    const isPublic = path.startsWith("/api/auth") || path.startsWith("/api/menu/") || path.startsWith("/api/venues/nearby") || path === "/api/orders" && method === "POST" || path.match(/^\/api\/orders\/[\w-]+$/) && method === "GET";
    let userId = null;
    if (!isPublic) {
      const token = request.headers.get("Authorization")?.replace("Bearer ", "");
      if (!token) return err("Unauthorized", 401);
      userId = await verifyToken(env, token);
      if (!userId) return err("Unauthorized", 401);
    }
    request.userId = userId;
    if (path.startsWith("/api/super-admin/")) {
      const isSuperAdmin = await checkSuperAdmin(env, userId);
      if (!isSuperAdmin) return err("Forbidden", 403);
    }
    try {
      return await routeApi(path, method, request, env, url);
    } catch (e) {
      console.error("Worker error:", e.message);
      return err("Internal error: " + e.message, 500);
    }
  }
};
async function routeApi(path, method, request, env, url) {
  if (path === "/api/auth/email" && method === "POST") return handleEmailAuth(request, env);
  if (path === "/api/auth/register" && method === "POST") return handleEmailRegister(request, env);
  if (path === "/api/auth/apple" && method === "POST") return handleAppleAuth(request, env);
  if (path === "/api/auth/google" && method === "POST") return handleGoogleAuth(request, env);
  if (path === "/api/auth/session" && method === "POST") return handleCreateSession(request, env);
  if (path === "/api/auth/session" && method === "GET") return handleGetSession(request, env);
  if (path === "/api/auth/reset-password" && method === "POST") return handleResetPassword(request, env);
  if (path === "/api/me" && method === "GET") return handleGetMe(request, env);
  if (path === "/api/super-admin/orgs" && method === "GET") return handleListOrgs(request, env);
  if (path === "/api/super-admin/orgs" && method === "POST") return handleCreateOrg(request, env);
  if (path === "/api/super-admin/orgs/invite" && method === "POST") return handleInviteCompany(request, env);
  if (path.match(/^\/api\/super-admin\/orgs\/[\w-]+$/) && method === "GET") return handleGetOrg(request, env, path);
  if (path.match(/^\/api\/super-admin\/orgs\/[\w-]+$/) && method === "PATCH") return handleUpdateOrg(request, env, path);
  if (path.match(/^\/api\/super-admin\/orgs\/[\w-]+$/) && method === "DELETE") return handleDeleteOrg(request, env, path, url);
  if (path.match(/^\/api\/super-admin\/orgs\/[\w-]+\/logo$/) && method === "POST") return handleUploadOrgLogo(request, env, path);
  if (path === "/api/super-admin/users" && method === "GET") return handleListAllUsers(request, env);
  if (path.match(/^\/api\/super-admin\/users\/[\w-]+\/super-admin$/) && method === "PATCH") return handleToggleSuperAdmin(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/venues$/) && method === "GET") return handleListOrgVenues(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+$/) && method === "GET") return handleGetOrgSelf(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+$/) && method === "PATCH") return handleUpdateOrgSelf(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/members\/me$/) && method === "GET") return handleGetOwnMembership(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/members$/) && method === "GET") return handleListMembers(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/members$/) && method === "POST") return handleCreateMember(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/members\/[\w-]+\/timesheet$/) && method === "GET") return handleGetMemberTimesheet(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/members\/[\w-]+\/timesheet\/clock-in$/) && method === "POST") return handleTimesheetClockIn(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/members\/[\w-]+\/timesheet\/clock-out$/) && method === "POST") return handleTimesheetClockOut(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/members\/[\w-]+\/timesheet\/[\w-]+$/) && method === "PATCH") return handleUpdateTimesheetEntry(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/members\/[\w-]+\/timesheet\/[\w-]+$/) && method === "DELETE") return handleDeleteTimesheetEntry(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/members\/[\w-]+$/) && method === "PATCH") return handleUpdateMember(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/members\/[\w-]+$/) && method === "DELETE") return handleDeleteMember(request, env, path);
  if (path.match(/^\/api\/venues\/[\w-]+\/products$/) && method === "GET") return handleListProducts(request, env, path);
  if (path.match(/^\/api\/venues\/[\w-]+\/products$/) && method === "POST") return handleCreateProduct(request, env, path);
  if (path.match(/^\/api\/products\/[\w-]+$/) && method === "PATCH") return handleUpdateProduct(request, env, path);
  if (path.match(/^\/api\/products\/[\w-]+$/) && method === "DELETE") return handleDeleteProduct(request, env, path);
  if (path.match(/^\/api\/products\/[\w-]+\/image$/) && method === "POST") return handleUploadProductImage(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/products$/) && method === "GET") return handleListOrgProducts(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/rewards$/) && method === "GET") return handleGetRewards(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/rewards$/) && method === "PATCH") return handleUpdateRewards(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/promo-codes$/) && method === "GET") return handleListPromoCodes(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/promo-codes$/) && method === "POST") return handleCreatePromoCode(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/promo-codes\/[\w-]+$/) && method === "DELETE") return handleDeletePromoCode(request, env, path);
  if (path === "/api/orders" && method === "POST") return handleCreateOrder(request, env);
  if (path === "/api/orders" && method === "GET") return handleListOrders(request, env, url);
  if (path.match(/^\/api\/orders\/[\w-]+$/) && method === "GET") return handleGetOrder(request, env, path);
  if (path.match(/^\/api\/orders\/[\w-]+$/) && method === "PATCH") return handleUpdateOrder(request, env, path);
  if (path.match(/^\/api\/venues\/[\w-]+\/geofence$/) && method === "PATCH") return handleUpdateGeofence(request, env, path);
  if (path === "/api/venues/nearby" && method === "GET") return handleNearbyVenues(request, env, url);
  if (path.match(/^\/api\/menu\/[\w-]+$/) && method === "GET") return handleMenu(request, env, url);
  if (path === "/api/stripe/terminal/connection-token" && method === "POST") return handleTerminalConnectionToken(request, env);
  if (path.match(/^\/api\/venues\/[\w-]+\/terminal-location$/) && method === "POST") return handleCreateTerminalLocation(request, env, path);
  if (path.match(/^\/api\/orgs\/[\w-]+\/stripe-connect$/) && method === "POST") return handleStripeConnect(request, env, path);
  return err("Not found", 404);
}
function routeMarketplace(path, request, env) {
  switch (path) {
    case "/marketplace/orders/create":
      return createMarketplaceOrder(request, env, "online");
    case "/marketplace/orders/list":
      return listMarketplaceOrders(request, env);
    case "/marketplace/orders/get":
      return getMarketplaceOrder(request, env);
    case "/marketplace/orders/mark-ready":
      return markMarketplaceReady(request, env);
    case "/marketplace/orders/confirm-received":
      return confirmMarketplaceReceived(request, env);
    case "/marketplace/orders/refund":
      return refundMarketplaceOrder(request, env);
    case "/marketplace/terminal/connection-token":
      return marketplaceTerminalToken(env);
    case "/marketplace/terminal/orders/create":
      return createMarketplaceOrder(request, env, "in_person");
    default:
      return err("Not found", 404);
  }
}
function routeStripeLegacy(path, request, env) {
  switch (path) {
    case "/stripe/create-payment-intent":
      return legacyCreatePaymentIntent(request, env);
    case "/stripe/confirm-apple-pay":
      return legacyConfirmApplePay(request, env);
    case "/stripe/connect/onboard":
      return legacyConnectOnboard(request, env);
    case "/stripe/connect/account-status":
      return legacyConnectAccountStatus(request, env);
    case "/stripe/connect/create-intent":
      return legacyConnectCreateIntent(request, env);
    default:
      return err("Not found", 404);
  }
}
async function handleEmailAuth(request, env) {
  const { email, password } = await request.json();
  if (!email || !password) return err("Email and password required");
  const user = await env.FRYDGE_DB.prepare("SELECT * FROM portal_users WHERE email = ?").bind(email).first();
  if (!user || !user.password_hash) return err("Invalid credentials", 401);
  const valid = await verifyPassword(password, user.password_hash);
  if (!valid) return err("Invalid credentials", 401);
  const token = await generateToken(env, user.id);
  return json({ token, user: { id: user.id, name: user.name, email: user.email } });
}
async function handleEmailRegister(request, env) {
  const { email, password, name } = await request.json();
  if (!email || !password || !name) return err("Email, password, and name required");
  if (password.length < 8) return err("Password must be at least 8 characters");
  const existing = await env.FRYDGE_DB.prepare("SELECT id FROM portal_users WHERE email = ?").bind(email).first();
  if (existing) return err("Email already registered", 409);
  const userId = crypto.randomUUID();
  const hash = await hashPassword(password);
  await env.FRYDGE_DB.prepare("INSERT INTO portal_users (id, email, name, password_hash, created_at) VALUES (?, ?, ?, ?, ?)").bind(userId, email, name, hash, Date.now()).run();
  const token = await generateToken(env, userId);
  return json({ token, user: { id: userId, name, email } }, 201);
}
async function handleAppleAuth(request, env) {
  const { userID, firstName, email } = await request.json();
  let user = await env.FRYDGE_DB.prepare("SELECT * FROM portal_users WHERE apple_user_id = ?").bind(userID).first();
  if (!user) {
    const id = crypto.randomUUID();
    await env.FRYDGE_DB.prepare("INSERT INTO portal_users (id, apple_user_id, name, email, created_at) VALUES (?, ?, ?, ?, ?)").bind(id, userID, firstName || "User", email || "", Date.now()).run();
    user = { id, name: firstName, email };
  }
  const token = await generateToken(env, user.id);
  return json({ token, user: { id: user.id, name: user.name, email: user.email } });
}
async function handleGoogleAuth(request, env) {
  const { credential } = await request.json();
  const payload = JSON.parse(atob(credential.split(".")[1]));
  let user = await env.FRYDGE_DB.prepare("SELECT * FROM portal_users WHERE google_user_id = ?").bind(payload.sub).first();
  if (!user) {
    const id = crypto.randomUUID();
    await env.FRYDGE_DB.prepare("INSERT INTO portal_users (id, google_user_id, name, email, created_at) VALUES (?, ?, ?, ?, ?)").bind(id, payload.sub, payload.name, payload.email, Date.now()).run();
    user = { id, name: payload.name, email: payload.email };
  }
  const token = await generateToken(env, user.id);
  return json({ token, user: { id: user.id, name: user.name, email: user.email } });
}
async function handleGetMe(request, env) {
  const user = await env.FRYDGE_DB.prepare("SELECT id, name, email, super_admin FROM portal_users WHERE id = ?").bind(request.userId).first();
  if (!user) return err("User not found", 404);
  const { results: orgs } = await env.FRYDGE_DB.prepare("SELECT org_id, role FROM org_members WHERE user_id = ?").bind(request.userId).all();
  return json({ ...user, superAdmin: !!user.super_admin, orgs: orgs.map((o) => ({ orgId: o.org_id, role: o.role })) });
}
async function handleCreateSession(request, env) {
  const { token } = await request.json();
  if (!token) return err("Token required");
  const uid = await verifyToken(env, token);
  if (!uid) return err("Invalid token", 401);
  const sessionId = crypto.randomUUID().replace(/-/g, "");
  await env.FRYDGE_CACHE.put(`session:${sessionId}`, token, { expirationTtl: 3600 });
  return json({ sessionId });
}
async function handleGetSession(request, env) {
  const sessionId = new URL(request.url).searchParams.get("id");
  if (!sessionId) return err("Session ID required");
  const token = await env.FRYDGE_CACHE.get(`session:${sessionId}`);
  if (!token) return err("Session expired", 404);
  await env.FRYDGE_CACHE.delete(`session:${sessionId}`);
  return json({ token });
}
async function handleResetPassword(request, env) {
  const { newPassword, targetUserId } = await request.json();
  if (!newPassword) return err("New password required");
  if (newPassword.length < 8) return err("Password must be at least 8 characters");
  const requester = await env.FRYDGE_DB.prepare("SELECT super_admin FROM portal_users WHERE id = ?").bind(request.userId).first();
  const targetId = targetUserId || request.userId;
  if (targetId !== request.userId && !requester?.super_admin) return err("Unauthorized to reset other users passwords", 403);
  const hash = await hashPassword(newPassword);
  await env.FRYDGE_DB.prepare("UPDATE portal_users SET password_hash = ? WHERE id = ?").bind(hash, targetId).run();
  return json({ ok: true });
}
async function checkSuperAdmin(env, userId) {
  if (!userId) return false;
  const row = await env.FRYDGE_DB.prepare("SELECT email, super_admin FROM portal_users WHERE id = ?").bind(userId).first();
  return !!(row?.super_admin && SUPER_ADMIN_EMAILS.includes(row.email));
}
async function handleListOrgs(request, env) {
  const { results } = await env.FRYDGE_DB.prepare("SELECT * FROM organisations ORDER BY created_at DESC").all();
  return json(results);
}
async function handleGetOrg(request, env, path) {
  const org = await env.FRYDGE_DB.prepare("SELECT * FROM organisations WHERE id = ?").bind(path.split("/")[4]).first();
  if (!org) return err("Org not found", 404);
  return json(org);
}
async function handleCreateOrg(request, env) {
  const { name, slug, businessType, currency, brandColor } = await request.json();
  if (!name || !slug) return err("name and slug required");
  const existing = await env.FRYDGE_DB.prepare("SELECT id FROM organisations WHERE slug = ?").bind(slug).first();
  if (existing) return err("Slug already taken", 409);
  const orgId = crypto.randomUUID();
  await env.FRYDGE_DB.prepare(
    "INSERT INTO organisations (id, name, slug, brand_colour, business_type, currency, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)"
  ).bind(orgId, name, slug, brandColor || "#007AFF", businessType || "", currency || "NZD", Date.now()).run();
  const venueId = crypto.randomUUID();
  await env.FRYDGE_DB.prepare(
    "INSERT INTO venues (id, org_id, name, slug, currency, created_at) VALUES (?, ?, ?, ?, ?, ?)"
  ).bind(venueId, orgId, name, slug, currency || "NZD", Date.now()).run();
  return json({ id: orgId, venueId }, 201);
}
async function sendEmail(env, { to, subject, html }) {
  if (!env.RESEND_API_KEY) return { sent: false, reason: "RESEND_API_KEY not configured on the Worker" };
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: "Bearer " + env.RESEND_API_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ from: env.EMAIL_FROM || "Frydge <welcome@frydge2.com>", to: [to], subject, html })
    });
    if (!res.ok) {
      const body = await res.text().catch(() => "");
      return { sent: false, reason: `Resend ${res.status}: ${body.slice(0, 300)}` };
    }
    return { sent: true };
  } catch (e) {
    return { sent: false, reason: e.message };
  }
}
function emailShell(title, bodyHtml) {
  return `<div style="font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:480px;margin:0 auto;padding:32px 24px;color:#18181b">
    <div style="width:36px;height:36px;border-radius:10px;background:#3b82f6;color:#fff;display:flex;align-items:center;justify-content:center;font-weight:800;font-size:18px;margin-bottom:20px">F</div>
    <h1 style="font-size:20px;margin:0 0 16px">${title}</h1>
    ${bodyHtml}
    <p style="color:#71717a;font-size:12px;margin-top:32px">Sent by Frydge \u2014 if you weren't expecting this, you can ignore it.</p>
  </div>`;
}
function credentialsBlockHtml(loginUrl, email, temporaryPassword) {
  return `<div style="background:#f4f4f5;border-radius:10px;padding:16px 18px;margin:16px 0;font-size:14px;line-height:1.8">
      <div><strong>Email:</strong> ${escapeHtmlEmail(email)}</div>
      ${temporaryPassword ? `<div><strong>Temporary password:</strong> <code style="background:#e4e4e7;padding:2px 6px;border-radius:5px">${escapeHtmlEmail(temporaryPassword)}</code></div>` : `<div>Sign in with your existing Frydge password.</div>`}
    </div>
    <p><a href="${loginUrl}" style="display:inline-block;background:#3b82f6;color:#fff;text-decoration:none;padding:10px 20px;border-radius:8px;font-weight:600">Sign in \u2192</a></p>`;
}
function escapeHtmlEmail(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}
async function handleInviteCompany(request, env) {
  const { companyName, slug, businessType, currency, brandColor, ownerName, ownerEmail } = await request.json();
  if (!companyName || !slug || !ownerName || !ownerEmail) {
    return err("companyName, slug, ownerName, and ownerEmail are required");
  }
  const existingSlug = await env.FRYDGE_DB.prepare("SELECT id FROM organisations WHERE slug = ?").bind(slug).first();
  if (existingSlug) return err("Slug already taken", 409);
  const orgId = crypto.randomUUID();
  await env.FRYDGE_DB.prepare(
    "INSERT INTO organisations (id, name, slug, brand_colour, business_type, currency, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)"
  ).bind(orgId, companyName, slug, brandColor || "#007AFF", businessType || "", currency || "NZD", Date.now()).run();
  const venueId = crypto.randomUUID();
  await env.FRYDGE_DB.prepare(
    "INSERT INTO venues (id, org_id, name, slug, currency, created_at) VALUES (?, ?, ?, ?, ?, ?)"
  ).bind(venueId, orgId, companyName, slug, currency || "NZD", Date.now()).run();
  let user = await env.FRYDGE_DB.prepare("SELECT id FROM portal_users WHERE email = ?").bind(ownerEmail).first();
  let temporaryPassword = null;
  if (!user) {
    const userId = crypto.randomUUID();
    temporaryPassword = generateTempPassword();
    const hash = await hashPassword(temporaryPassword);
    await env.FRYDGE_DB.prepare("INSERT INTO portal_users (id, email, name, password_hash, created_at) VALUES (?, ?, ?, ?, ?)").bind(userId, ownerEmail, ownerName, hash, Date.now()).run();
    user = { id: userId };
  }
  const memberId = crypto.randomUUID();
  await env.FRYDGE_DB.prepare(
    "INSERT INTO org_members (id, org_id, user_id, role, discount_code, discount_value, discount_type, joined_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
  ).bind(memberId, orgId, user.id, "owner", "STAFF-" + Math.random().toString(36).slice(2, 7).toUpperCase(), 0, "percent", Date.now()).run();
  let stripeOnboardingUrl = null;
  if (env.STRIPE_SECRET_KEY) {
    try {
      const accountParams = new URLSearchParams({
        type: "express",
        country: "NZ",
        "capabilities[card_payments][requested]": "true",
        "capabilities[transfers][requested]": "true",
        "business_profile[name]": companyName
      });
      const accountRes = await fetch("https://api.stripe.com/v1/accounts", {
        method: "POST",
        headers: { Authorization: "Bearer " + env.STRIPE_SECRET_KEY, "Content-Type": "application/x-www-form-urlencoded" },
        body: accountParams
      });
      const account = await accountRes.json();
      if (accountRes.ok) {
        await env.FRYDGE_DB.prepare("UPDATE organisations SET stripe_account_id = ?, updated_at = ? WHERE id = ?").bind(account.id, Date.now(), orgId).run();
        const linkParams = new URLSearchParams({
          account: account.id,
          refresh_url: `https://manage.frydge2.com?org=${encodeURIComponent(orgId)}&stripe=refresh`,
          return_url: `https://manage.frydge2.com?org=${encodeURIComponent(orgId)}&stripe=return`,
          type: "account_onboarding"
        });
        const linkRes = await fetch("https://api.stripe.com/v1/account_links", {
          method: "POST",
          headers: { Authorization: "Bearer " + env.STRIPE_SECRET_KEY, "Content-Type": "application/x-www-form-urlencoded" },
          body: linkParams
        });
        const link = await linkRes.json();
        if (linkRes.ok) stripeOnboardingUrl = link.url;
      }
    } catch {
    }
  }
  const loginUrl = `https://manage.frydge2.com/?org=${encodeURIComponent(orgId)}`;
  const emailResult = await sendEmail(env, {
    to: ownerEmail,
    subject: `You're all set up on Frydge \u2014 ${companyName}`,
    html: emailShell(`Welcome to Frydge, ${escapeHtmlEmail(ownerName)} \u{1F44B}`, `
      <p><strong>${escapeHtmlEmail(companyName)}</strong> is ready to go. Here's how to sign in and start setting up your store:</p>
      ${credentialsBlockHtml(loginUrl, ownerEmail, temporaryPassword)}
      ${stripeOnboardingUrl ? `<p style="margin-top:20px">One more thing \u2014 you'll need to <a href="${stripeOnboardingUrl}">connect your bank account with Stripe</a> before you can accept online payments.</p>` : ""}
    `)
  });
  return json({
    orgId,
    venueId,
    ownerUserId: user.id,
    loginEmail: ownerEmail,
    temporaryPassword,
    // null if this person already had a Frydge login
    stripeOnboardingUrl,
    // null if Stripe account creation failed — retry via /api/orgs/:id/stripe-connect
    emailSent: emailResult.sent,
    emailError: emailResult.sent ? null : emailResult.reason
    // relay credentials yourself if this is non-null
  }, 201);
}
async function handleUpdateOrg(request, env, path) {
  const orgId = path.split("/")[4];
  const body = await request.json();
  const allowed = ["name", "slug", "logo_url", "brand_colour", "business_type", "currency", "onboarded"];
  const updates = Object.entries(body).filter(([k]) => allowed.includes(k));
  if (!updates.length) return err("Nothing to update");
  const set = updates.map(([k]) => `${k} = ?`).join(", ");
  await env.FRYDGE_DB.prepare(`UPDATE organisations SET ${set}, updated_at = ? WHERE id = ?`).bind(...updates.map(([, v]) => v), Date.now(), orgId).run();
  if (body.slug) await env.FRYDGE_DB.prepare("UPDATE venues SET slug = ? WHERE org_id = ?").bind(body.slug, orgId).run();
  if (body.name) await env.FRYDGE_DB.prepare("UPDATE venues SET name = ? WHERE org_id = ?").bind(body.name, orgId).run();
  return json({ ok: true });
}
async function handleDeleteOrg(request, env, path, url) {
  const orgId = path.split("/")[4];
  const force = url.searchParams.get("force") === "true";
  const org = await env.FRYDGE_DB.prepare("SELECT id, name FROM organisations WHERE id = ?").bind(orgId).first();
  if (!org) return err("Org not found", 404);
  const { results: venues } = await env.FRYDGE_DB.prepare("SELECT id FROM venues WHERE org_id = ?").bind(orgId).all();
  const venueIds = venues.map((v) => v.id);
  if (venueIds.length && !force) {
    const placeholders = venueIds.map(() => "?").join(",");
    const liveOrders = await env.FRYDGE_DB.prepare(
      `SELECT COUNT(*) as n FROM orders WHERE venue_id IN (${placeholders}) AND status NOT IN ('pending_payment','cancelled')`
    ).bind(...venueIds).first();
    if ((liveOrders?.n || 0) > 0) {
      return err(`This org has ${liveOrders.n} real order(s) on record. Re-send DELETE with ?force=true to delete the org anyway (orders are kept, not deleted \u2014 they'll just no longer be linked to a venue).`, 409);
    }
  }
  await env.FRYDGE_DB.prepare("DELETE FROM org_members WHERE org_id = ?").bind(orgId).run();
  try {
    await env.FRYDGE_DB.prepare("DELETE FROM org_rewards WHERE org_id = ?").bind(orgId).run();
  } catch {
  }
  try {
    await env.FRYDGE_DB.prepare("DELETE FROM promo_codes WHERE org_id = ?").bind(orgId).run();
  } catch {
  }
  if (venueIds.length) {
    const placeholders = venueIds.map(() => "?").join(",");
    await env.FRYDGE_DB.prepare(`DELETE FROM products WHERE venue_id IN (${placeholders})`).bind(...venueIds).run();
  }
  await env.FRYDGE_DB.prepare("DELETE FROM venues WHERE org_id = ?").bind(orgId).run();
  await env.FRYDGE_DB.prepare("DELETE FROM organisations WHERE id = ?").bind(orgId).run();
  return json({ ok: true, deleted: org.name });
}
async function handleGetOrgSelf(request, env, path) {
  const orgId = path.split("/")[3];
  const allowed = await hasVenueRole(env, request.userId, orgId, ["owner", "admin", "payment_receiver", "viewer"]) || await checkSuperAdmin(env, request.userId);
  if (!allowed) return err("Forbidden", 403);
  const org = await env.FRYDGE_DB.prepare("SELECT * FROM organisations WHERE id = ?").bind(orgId).first();
  if (!org) return err("Org not found", 404);
  return json(org);
}
async function handleListOrgVenues(request, env, path) {
  const orgId = path.split("/")[3];
  const allowed = await hasVenueRole(env, request.userId, orgId, ["owner", "admin", "payment_receiver", "viewer"]) || await checkSuperAdmin(env, request.userId);
  if (!allowed) return err("Forbidden", 403);
  const { results } = await env.FRYDGE_DB.prepare("SELECT * FROM venues WHERE org_id = ? ORDER BY created_at ASC").bind(orgId).all();
  return json(results);
}
async function handleUpdateOrgSelf(request, env, path) {
  const orgId = path.split("/")[3];
  const allowed = await hasVenueRole(env, request.userId, orgId, ["owner", "admin"]) || await checkSuperAdmin(env, request.userId);
  if (!allowed) return err("Only an owner, admin, or super admin can update this organisation", 403);
  const body = await request.json();
  const allowedFields = ["name", "slug", "logo_url", "brand_colour", "business_type", "currency"];
  const updates = Object.entries(body).filter(([k]) => allowedFields.includes(k));
  if (!updates.length) return err("Nothing to update");
  const set = updates.map(([k]) => `${k} = ?`).join(", ");
  await env.FRYDGE_DB.prepare(`UPDATE organisations SET ${set}, updated_at = ? WHERE id = ?`).bind(...updates.map(([, v]) => v), Date.now(), orgId).run();
  if (body.slug) await env.FRYDGE_DB.prepare("UPDATE venues SET slug = ? WHERE org_id = ?").bind(body.slug, orgId).run();
  if (body.name) await env.FRYDGE_DB.prepare("UPDATE venues SET name = ? WHERE org_id = ?").bind(body.name, orgId).run();
  return json({ ok: true });
}
async function handleListAllUsers(request, env) {
  const { results } = await env.FRYDGE_DB.prepare("SELECT id, name, email, super_admin, created_at FROM portal_users ORDER BY created_at DESC").all();
  return json(results);
}
async function handleToggleSuperAdmin(request, env, path) {
  const { superAdmin } = await request.json();
  await env.FRYDGE_DB.prepare("UPDATE portal_users SET super_admin = ? WHERE id = ?").bind(superAdmin ? 1 : 0, path.split("/")[4]).run();
  return json({ ok: true });
}
async function handleUploadOrgLogo(request, env, path) {
  const orgId = path.split("/")[4];
  try {
    const formData = await request.formData();
    const file = formData.get("logo");
    if (!file) return err("No logo file provided");
    const ext = (file.name || "logo.jpg").split(".").pop();
    const key = `orgs/${orgId}/logo.${ext}`;
    await env.FRYDGE_ASSETS.put(key, file.stream(), { httpMetadata: { contentType: file.type || "image/jpeg" } });
    const logoUrl = `https://assets.frydge2.com/${key}`;
    await env.FRYDGE_DB.prepare("UPDATE organisations SET logo_url = ?, updated_at = ? WHERE id = ?").bind(logoUrl, Date.now(), orgId).run();
    return json({ logoUrl });
  } catch (e) {
    return err("Upload failed: " + e.message);
  }
}
async function handleListMembers(request, env, path) {
  const orgId = path.split("/")[3];
  const allowed = await hasVenueRole(env, request.userId, orgId, ["owner", "admin"]) || await checkSuperAdmin(env, request.userId);
  if (!allowed) return err("Only an owner or admin can view the team list", 403);
  const { results } = await env.FRYDGE_DB.prepare(
    "SELECT m.*, u.name, u.email FROM org_members m JOIN portal_users u ON u.id = m.user_id WHERE m.org_id = ?"
  ).bind(orgId).all();
  return json(results);
}
async function handleGetOwnMembership(request, env, path) {
  const orgId = path.split("/")[3];
  const member = await env.FRYDGE_DB.prepare("SELECT * FROM org_members WHERE org_id = ? AND user_id = ?").bind(orgId, request.userId).first();
  if (!member) return err("Not a member of this organisation", 404);
  return json(member);
}
async function getMemberAccess(env, request, orgId, memberId) {
  const isManager = await hasVenueRole(env, request.userId, orgId, ["owner", "admin"]) || await checkSuperAdmin(env, request.userId);
  const member = await env.FRYDGE_DB.prepare("SELECT * FROM org_members WHERE id = ? AND org_id = ?").bind(memberId, orgId).first();
  const isSelf = !!(member && member.user_id === request.userId);
  return { isManager, isSelf, member };
}
function generateTempPassword() {
  const bytes = crypto.getRandomValues(new Uint8Array(9));
  return btoa(String.fromCharCode(...bytes)).replace(/[+/=]/g, "").slice(0, 12);
}
async function handleCreateMember(request, env, path) {
  const orgId = path.split("/")[3];
  const allowed = await hasVenueRole(env, request.userId, orgId, ["owner", "admin"]) || await checkSuperAdmin(env, request.userId);
  if (!allowed) return err("Only an owner or admin can add team members", 403);
  const { email, name, role, discountCode, discountValue, discountType, hourlyRateCents, timesheetsEnabled } = await request.json();
  if (!email || !name) return err("Email and name required");
  if (!["owner", "admin", "payment_receiver", "viewer"].includes(role)) return err("Invalid role");
  let user = await env.FRYDGE_DB.prepare("SELECT id FROM portal_users WHERE email = ?").bind(email).first();
  let temporaryPassword = null;
  if (!user) {
    const userId = crypto.randomUUID();
    temporaryPassword = generateTempPassword();
    const hash = await hashPassword(temporaryPassword);
    await env.FRYDGE_DB.prepare("INSERT INTO portal_users (id, email, name, password_hash, created_at) VALUES (?, ?, ?, ?, ?)").bind(userId, email, name, hash, Date.now()).run();
    user = { id: userId };
  }
  const memberId = crypto.randomUUID();
  const code = discountCode || "STAFF-" + Math.random().toString(36).slice(2, 7).toUpperCase();
  await env.FRYDGE_DB.prepare(
    "INSERT INTO org_members (id, org_id, user_id, role, discount_code, discount_value, discount_type, hourly_rate_cents, timesheets_enabled, joined_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  ).bind(memberId, orgId, user.id, role, code, discountValue || 0, discountType || "percent", hourlyRateCents ?? null, timesheetsEnabled ? 1 : 0, Date.now()).run();
  const org = await env.FRYDGE_DB.prepare("SELECT name FROM organisations WHERE id = ?").bind(orgId).first();
  const loginUrl = `https://manage.frydge2.com/?org=${encodeURIComponent(orgId)}`;
  const emailResult = await sendEmail(env, {
    to: email,
    subject: `You've been added to ${org?.name || "a store"} on Frydge`,
    html: emailShell(`Hi ${escapeHtmlEmail(name)} \u{1F44B}`, `
      <p>You've been added as <strong>${escapeHtmlEmail(role)}</strong> on <strong>${escapeHtmlEmail(org?.name || "your team")}</strong>'s Frydge account.</p>
      ${credentialsBlockHtml(loginUrl, email, temporaryPassword)}
    `)
  });
  return json({ id: memberId, discountCode: code, temporaryPassword, emailSent: emailResult.sent, emailError: emailResult.sent ? null : emailResult.reason }, 201);
}
async function handleUpdateMember(request, env, path) {
  const orgId = path.split("/")[3];
  const isAllowed = await hasVenueRole(env, request.userId, orgId, ["owner", "admin"]) || await checkSuperAdmin(env, request.userId);
  if (!isAllowed) return err("Only an owner or admin can edit team members", 403);
  const body = await request.json();
  const allowedFields = ["role", "discount_code", "discount_value", "discount_type", "hourly_rate_cents", "timesheets_enabled"];
  const updates = Object.entries(body).filter(([k]) => allowedFields.includes(k));
  if (!updates.length) return err("Nothing to update");
  const set = updates.map(([k]) => `${k} = ?`).join(", ");
  await env.FRYDGE_DB.prepare(`UPDATE org_members SET ${set} WHERE id = ? AND org_id = ?`).bind(...updates.map(([, v]) => v), path.split("/")[5], orgId).run();
  return json({ ok: true });
}
async function handleDeleteMember(request, env, path) {
  const orgId = path.split("/")[3];
  const isAllowed = await hasVenueRole(env, request.userId, orgId, ["owner", "admin"]) || await checkSuperAdmin(env, request.userId);
  if (!isAllowed) return err("Only an owner or admin can remove team members", 403);
  await env.FRYDGE_DB.prepare("DELETE FROM org_members WHERE id = ? AND org_id = ?").bind(path.split("/")[5], orgId).run();
  return json({ ok: true });
}
async function handleGetMemberTimesheet(request, env, path) {
  const orgId = path.split("/")[3];
  const memberId = path.split("/")[5];
  const { isManager, isSelf, member } = await getMemberAccess(env, request, orgId, memberId);
  if (!member) return err("Member not found", 404);
  if (!isManager && !isSelf) return err("Forbidden", 403);
  const { results: entries } = await env.FRYDGE_DB.prepare(
    "SELECT * FROM timesheet_entries WHERE org_member_id = ? ORDER BY clock_in DESC"
  ).bind(memberId).all();
  const now = Date.now();
  const totalMs = entries.reduce((sum, e) => sum + ((e.clock_out ?? now) - e.clock_in), 0);
  const totalHours = totalMs / 36e5;
  const estimatedPayCents = member.hourly_rate_cents != null ? Math.round(totalHours * member.hourly_rate_cents) : null;
  const openEntry = entries.find((e) => e.clock_out == null) || null;
  return json({
    entries,
    totalHours,
    estimatedPayCents,
    hourlyRateCents: member.hourly_rate_cents,
    timesheetsEnabled: !!member.timesheets_enabled,
    openEntryId: openEntry?.id ?? null
  });
}
async function handleTimesheetClockIn(request, env, path) {
  const orgId = path.split("/")[3];
  const memberId = path.split("/")[5];
  const { isManager, isSelf, member } = await getMemberAccess(env, request, orgId, memberId);
  if (!member) return err("Member not found", 404);
  if (!isManager && !(isSelf && member.timesheets_enabled)) return err("Forbidden", 403);
  const open = await env.FRYDGE_DB.prepare("SELECT id FROM timesheet_entries WHERE org_member_id = ? AND clock_out IS NULL").bind(memberId).first();
  if (open) return err("Already clocked in", 400);
  const id = crypto.randomUUID();
  const now = Date.now();
  await env.FRYDGE_DB.prepare("INSERT INTO timesheet_entries (id, org_member_id, org_id, clock_in, created_at) VALUES (?, ?, ?, ?, ?)").bind(id, memberId, orgId, now, now).run();
  return json({ id, clockIn: now }, 201);
}
async function handleTimesheetClockOut(request, env, path) {
  const orgId = path.split("/")[3];
  const memberId = path.split("/")[5];
  const { isManager, isSelf, member } = await getMemberAccess(env, request, orgId, memberId);
  if (!member) return err("Member not found", 404);
  if (!isManager && !(isSelf && member.timesheets_enabled)) return err("Forbidden", 403);
  const open = await env.FRYDGE_DB.prepare(
    "SELECT id FROM timesheet_entries WHERE org_member_id = ? AND clock_out IS NULL ORDER BY clock_in DESC LIMIT 1"
  ).bind(memberId).first();
  if (!open) return err("Not currently clocked in", 400);
  const now = Date.now();
  await env.FRYDGE_DB.prepare("UPDATE timesheet_entries SET clock_out = ?, updated_at = ? WHERE id = ?").bind(now, now, open.id).run();
  return json({ id: open.id, clockOut: now });
}
async function handleUpdateTimesheetEntry(request, env, path) {
  const orgId = path.split("/")[3];
  const memberId = path.split("/")[5];
  const entryId = path.split("/")[7];
  const isManager = await hasVenueRole(env, request.userId, orgId, ["owner", "admin"]) || await checkSuperAdmin(env, request.userId);
  if (!isManager) return err("Only an owner or admin can edit timesheet entries", 403);
  const body = await request.json();
  const allowedFields = ["clock_in", "clock_out", "note"];
  const updates = Object.entries(body).filter(([k]) => allowedFields.includes(k));
  if (!updates.length) return err("Nothing to update");
  const set = updates.map(([k]) => `${k} = ?`).join(", ");
  await env.FRYDGE_DB.prepare(`UPDATE timesheet_entries SET ${set}, updated_at = ? WHERE id = ? AND org_member_id = ?`).bind(...updates.map(([, v]) => v), Date.now(), entryId, memberId).run();
  return json({ ok: true });
}
async function handleDeleteTimesheetEntry(request, env, path) {
  const orgId = path.split("/")[3];
  const memberId = path.split("/")[5];
  const entryId = path.split("/")[7];
  const isManager = await hasVenueRole(env, request.userId, orgId, ["owner", "admin"]) || await checkSuperAdmin(env, request.userId);
  if (!isManager) return err("Only an owner or admin can delete timesheet entries", 403);
  await env.FRYDGE_DB.prepare("DELETE FROM timesheet_entries WHERE id = ? AND org_member_id = ?").bind(entryId, memberId).run();
  return json({ ok: true });
}
async function handleListProducts(request, env, path) {
  const { results } = await env.FRYDGE_DB.prepare("SELECT * FROM products WHERE venue_id = ? ORDER BY sort_order ASC, created_at ASC").bind(path.split("/")[3]).all();
  return json(results.map((p) => ({ ...p, price: p.price_cents / 100 })));
}
async function handleListOrgProducts(request, env, path) {
  const orgId = path.split("/")[3];
  const { results } = await env.FRYDGE_DB.prepare(
    `SELECT p.*, v.id as venueId, v.name as venueName
       FROM products p
       JOIN venues v ON v.id = p.venue_id
      WHERE v.org_id = ?
      ORDER BY v.name ASC, p.sort_order ASC, p.created_at ASC`
  ).bind(orgId).all();
  return json(results.map((p) => ({ ...p, price: p.price_cents / 100 })));
}
async function handleCreateProduct(request, env, path) {
  const venueId = path.split("/")[3];
  const { name, description, price, category, emoji, tags, active } = await request.json();
  if (!name || !price) return err("name and price required");
  const id = crypto.randomUUID();
  await env.FRYDGE_DB.prepare(
    "INSERT INTO products (id, venue_id, name, description, price_cents, category, emoji, tags_json, active, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  ).bind(id, venueId, name, description || "", Math.round(price * 100), category || "", emoji || "\u{1F6CD}\uFE0F", JSON.stringify(tags || []), active !== false ? 1 : 0, Date.now()).run();
  return json({ id }, 201);
}
async function handleUpdateProduct(request, env, path) {
  const productId = path.split("/").pop();
  const body = await request.json();
  if (body.price != null) {
    body.price_cents = Math.round(body.price * 100);
    delete body.price;
  }
  const allowed = ["name", "description", "price_cents", "category", "emoji", "tags_json", "active", "image_url", "sort_order"];
  const updates = Object.entries(body).filter(([k]) => allowed.includes(k));
  if (!updates.length) return err("Nothing to update");
  const set = updates.map(([k]) => `${k} = ?`).join(", ");
  await env.FRYDGE_DB.prepare(`UPDATE products SET ${set}, updated_at = ? WHERE id = ?`).bind(...updates.map(([, v]) => v), Date.now(), productId).run();
  return json({ ok: true });
}
async function handleDeleteProduct(request, env, path) {
  await env.FRYDGE_DB.prepare("DELETE FROM products WHERE id = ?").bind(path.split("/").pop()).run();
  return json({ ok: true });
}
async function handleUploadProductImage(request, env, path) {
  const productId = path.split("/")[3];
  const formData = await request.formData();
  const file = formData.get("image");
  if (!file) return err("No image provided");
  const ext = file.name.split(".").pop() || "jpg";
  const key = `products/${productId}/image.${ext}`;
  await env.FRYDGE_ASSETS.put(key, file.stream(), { httpMetadata: { contentType: file.type } });
  const imageUrl = `https://assets.frydge2.com/${key}`;
  await env.FRYDGE_DB.prepare("UPDATE products SET image_url = ?, updated_at = ? WHERE id = ?").bind(imageUrl, Date.now(), productId).run();
  return json({ imageUrl });
}
async function handleGetRewards(request, env, path) {
  const orgId = path.split("/")[3];
  const rewards = await env.FRYDGE_DB.prepare("SELECT * FROM org_rewards WHERE org_id = ?").bind(orgId).first();
  const { results: promoCodes } = await env.FRYDGE_DB.prepare("SELECT * FROM promo_codes WHERE org_id = ? ORDER BY created_at DESC").bind(orgId).all();
  return json({ ...rewards || {}, promoCodes });
}
async function handleUpdateRewards(request, env, path) {
  const orgId = path.split("/")[3];
  const body = await request.json();
  const existing = await env.FRYDGE_DB.prepare("SELECT id FROM org_rewards WHERE org_id = ?").bind(orgId).first();
  const allowed = ["points_enabled", "points_per_dollar", "points_value", "silver_discount", "silver_type", "gold_discount", "gold_type"];
  if (existing) {
    const updates = Object.entries(body).filter(([k]) => allowed.includes(k));
    if (updates.length) {
      const set = updates.map(([k]) => `${k} = ?`).join(", ");
      await env.FRYDGE_DB.prepare(`UPDATE org_rewards SET ${set} WHERE org_id = ?`).bind(...updates.map(([, v]) => v), orgId).run();
    }
  } else {
    await env.FRYDGE_DB.prepare("INSERT INTO org_rewards (id, org_id, points_enabled, points_per_dollar, points_value, created_at) VALUES (?, ?, ?, ?, ?, ?)").bind(crypto.randomUUID(), orgId, body.points_enabled ? 1 : 0, body.points_per_dollar || 1, body.points_value || 100, Date.now()).run();
  }
  return json({ ok: true });
}
async function handleListPromoCodes(request, env, path) {
  const { results } = await env.FRYDGE_DB.prepare("SELECT * FROM promo_codes WHERE org_id = ? ORDER BY created_at DESC").bind(path.split("/")[3]).all();
  return json(results);
}
async function handleCreatePromoCode(request, env, path) {
  const orgId = path.split("/")[3];
  const { code, value, type, limit, expiry } = await request.json();
  if (!code || !value) return err("Code and value required");
  const id = crypto.randomUUID();
  await env.FRYDGE_DB.prepare(
    "INSERT INTO promo_codes (id, org_id, code, value, type, usage_limit, expiry, used_count, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)"
  ).bind(id, orgId, code.toUpperCase(), value, type || "percent", limit || null, expiry || null, Date.now()).run();
  return json({ id }, 201);
}
async function handleDeletePromoCode(request, env, path) {
  await env.FRYDGE_DB.prepare("DELETE FROM promo_codes WHERE id = ?").bind(path.split("/").pop()).run();
  return json({ ok: true });
}
var APP_FEE_RATE_BPS = 250;
var APP_FEE_MIN_CENTS = 10;
var APP_FEE_CAP_CENTS = 150;
function appPlatformFeeCents(cents) {
  if (!cents || cents <= 0) return 0;
  return Math.min(Math.max(Math.round(cents * APP_FEE_RATE_BPS / 1e4), APP_FEE_MIN_CENTS), APP_FEE_CAP_CENTS);
}
async function handleCreateOrder(request, env) {
  const body = await request.json();
  const { venueSlug, items, customerName, customerPhone, paymentMethod, tip } = body;
  if (!venueSlug || !items?.length || !customerName) return err("Missing required fields");
  if (!["online", "arrival"].includes(paymentMethod)) return err("Invalid payment method");
  const venue = await env.FRYDGE_DB.prepare("SELECT id, org_id, currency FROM venues WHERE slug = ?").bind(venueSlug).first();
  if (!venue) return err("Venue not found", 404);
  const ids = [...new Set(items.map((i) => i.id))];
  const placeholders = ids.map(() => "?").join(",");
  const { results: catalog } = await env.FRYDGE_DB.prepare(
    `SELECT id, name, price_cents FROM products WHERE venue_id = ? AND active = 1 AND id IN (${placeholders})`
  ).bind(venue.id, ...ids).all();
  const priceById = Object.fromEntries(catalog.map((p) => [p.id, p]));
  let subtotalCents = 0;
  const priced = [];
  for (const i of items) {
    const p = priceById[i.id];
    if (!p) return err(`Item unavailable: ${i.id}`, 409);
    const qty = Math.max(1, Math.min(50, parseInt(i.qty, 10) || 1));
    subtotalCents += p.price_cents * qty;
    priced.push({ id: p.id, name: p.name, price: p.price_cents / 100, qty });
  }
  if (subtotalCents < 50) return err("Order total below minimum", 400);
  let tipCents = 0;
  if (tip != null) {
    tipCents = Math.round(Number(tip) * 100);
    if (!Number.isFinite(tipCents) || tipCents < 0) tipCents = 0;
    tipCents = Math.min(tipCents, subtotalCents, 1e5);
  }
  const totalCents = subtotalCents + tipCents;
  const orderId = crypto.randomUUID();
  const orderNum = Math.floor(1e3 + Math.random() * 9e3);
  let clientSecret = null, paymentIntentId = null, stripeAccountId = null;
  if (paymentMethod === "online") {
    const org = await env.FRYDGE_DB.prepare("SELECT stripe_account_id, stripe_onboarded FROM organisations WHERE id = ?").bind(venue.org_id).first();
    if (!org?.stripe_account_id || !org.stripe_onboarded) return err("This venue is not yet set up to accept online payments", 400);
    if (!env.STRIPE_SECRET_KEY) return err("Missing STRIPE_SECRET_KEY", 500);
    stripeAccountId = org.stripe_account_id;
    const feeCents = appPlatformFeeCents(subtotalCents);
    const params = new URLSearchParams({
      amount: String(totalCents),
      currency: (venue.currency || "nzd").toLowerCase(),
      "automatic_payment_methods[enabled]": "true",
      application_fee_amount: String(feeCents),
      "metadata[orderId]": orderId,
      "metadata[venueSlug]": venueSlug,
      "metadata[tipCents]": String(tipCents)
    });
    const res = await fetch("https://api.stripe.com/v1/payment_intents", {
      method: "POST",
      headers: {
        Authorization: "Bearer " + env.STRIPE_SECRET_KEY,
        "Stripe-Account": org.stripe_account_id,
        "Content-Type": "application/x-www-form-urlencoded",
        "Idempotency-Key": `pi_${orderId}`
      },
      body: params
    });
    const pi = await res.json();
    if (!res.ok) return err(`Stripe error: ${pi.error?.message}`, 400);
    clientSecret = pi.client_secret;
    paymentIntentId = pi.id;
  }
  await env.FRYDGE_DB.prepare(`
    INSERT INTO orders (id, order_num, venue_id, customer_name, customer_phone, items_json,
      total_cents, payment_method, status, stripe_payment_intent, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).bind(
    orderId,
    orderNum,
    venue.id,
    customerName,
    customerPhone || null,
    JSON.stringify(priced),
    totalCents,
    paymentMethod,
    "pending_payment",
    paymentIntentId,
    Date.now()
  ).run();
  return json({
    orderId,
    orderNum,
    status: "pending_payment",
    clientSecret,
    total: totalCents / 100,
    publishableKey: env.STRIPE_PUBLISHABLE_KEY || null,
    stripeAccount: stripeAccountId,
    deepLink: `frydge://order/${orderId}`
  }, 201);
}
async function handleGetOrder(request, env, path) {
  const orderId = path.split("/").pop();
  const row = await env.FRYDGE_DB.prepare(`
    SELECT o.id, o.order_num, o.status, o.total_cents, o.stripe_payment_intent,
           org.stripe_account_id
      FROM orders o
      JOIN venues v ON v.id = o.venue_id
      JOIN organisations org ON org.id = v.org_id
     WHERE o.id = ?
  `).bind(orderId).first();
  if (!row) return err("Order not found", 404);
  return json({
    orderId: row.id,
    order_num: row.order_num,
    status: row.status,
    total: row.total_cents / 100,
    stripe_account_id: row.stripe_account_id,
    publishable_key: env.STRIPE_PUBLISHABLE_KEY || null
  });
}
async function handleListOrders(request, env, url) {
  const orgId = url.searchParams.get("orgId");
  const venueId = url.searchParams.get("venueId");
  let query = "SELECT * FROM orders WHERE 1=1";
  const binds = [];
  if (venueId) {
    query += " AND venue_id = ?";
    binds.push(venueId);
  }
  if (orgId) {
    query += " AND venue_id IN (SELECT id FROM venues WHERE org_id = ?)";
    binds.push(orgId);
  }
  query += " ORDER BY created_at DESC LIMIT 100";
  const { results } = await env.FRYDGE_DB.prepare(query).bind(...binds).all();
  return json(results.map((o) => ({ ...o, items: JSON.parse(o.items_json) })));
}
async function handleUpdateOrder(request, env, path) {
  const orderId = path.split("/").pop();
  const { status } = await request.json();
  const valid = ["pending_payment", "paid", "preparing", "ready", "done", "cancelled"];
  if (!valid.includes(status)) return err("Invalid status");
  await env.FRYDGE_DB.prepare("UPDATE orders SET status = ?, updated_at = ? WHERE id = ?").bind(status, Date.now(), orderId).run();
  return json({ ok: true, status });
}
async function handleUpdateGeofence(request, env, path) {
  const { lat, lng, radiusM } = await request.json();
  await env.FRYDGE_DB.prepare("UPDATE venues SET lat = ?, lng = ?, geofence_radius_m = ?, updated_at = ? WHERE id = ?").bind(lat, lng, radiusM || 75, Date.now(), path.split("/")[3]).run();
  return json({ ok: true });
}
async function handleNearbyVenues(request, env, url) {
  const lat = parseFloat(url.searchParams.get("lat"));
  const lng = parseFloat(url.searchParams.get("lng"));
  const radiusKm = parseFloat(url.searchParams.get("radius") || "5");
  if (isNaN(lat) || isNaN(lng)) return err("lat and lng required");
  const latDelta = radiusKm / 111;
  const lngDelta = radiusKm / (111 * Math.cos(lat * Math.PI / 180));
  const { results } = await env.FRYDGE_DB.prepare(
    "SELECT * FROM venues WHERE active = 1 AND lat BETWEEN ? AND ? AND lng BETWEEN ? AND ?"
  ).bind(lat - latDelta, lat + latDelta, lng - lngDelta, lng + lngDelta).all();
  return json(results);
}
async function handleMenu(request, env, url) {
  const slug = url.pathname.split("/").pop();
  const cached = await env.FRYDGE_CACHE.get(`menu:${slug}`, "json");
  if (cached) return json(cached);
  const venue = await env.FRYDGE_DB.prepare("SELECT * FROM venues WHERE slug = ? AND active = 1").bind(slug).first();
  if (!venue) return err("Venue not found", 404);
  const { results: products } = await env.FRYDGE_DB.prepare("SELECT * FROM products WHERE venue_id = ? AND active = 1 ORDER BY sort_order ASC").bind(venue.id).all();
  const menu = { venue, products: products.map((p) => ({ ...p, price: p.price_cents / 100 })) };
  await env.FRYDGE_CACHE.put(`menu:${slug}`, JSON.stringify(menu), { expirationTtl: 60 });
  return json(menu);
}
async function generateToken(env, userId) {
  const header = btoa(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = btoa(JSON.stringify({ sub: userId, iat: Math.floor(Date.now() / 1e3), exp: Math.floor(Date.now() / 1e3) + 2592e3 }));
  const data = `${header}.${payload}`;
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(requireJwtSecret(env)), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(data));
  return `${data}.${btoa(String.fromCharCode(...new Uint8Array(sig)))}`;
}
async function verifyToken(env, token) {
  try {
    const [header, payload, signature] = token.split(".");
    const data = `${header}.${payload}`;
    const enc = new TextEncoder();
    const key = await crypto.subtle.importKey("raw", enc.encode(requireJwtSecret(env)), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
    const sig = Uint8Array.from(atob(signature), (c) => c.charCodeAt(0));
    const valid = await crypto.subtle.verify("HMAC", key, sig, enc.encode(data));
    if (!valid) return null;
    const decoded = JSON.parse(atob(payload));
    if (decoded.exp < Math.floor(Date.now() / 1e3)) return null;
    return decoded.sub;
  } catch {
    return null;
  }
}
function requireJwtSecret(env) {
  if (!env.JWT_SECRET) throw new Error("JWT_SECRET is not configured");
  return env.JWT_SECRET;
}
async function hashPassword(password) {
  const encoder = new TextEncoder();
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const keyMaterial = await crypto.subtle.importKey("raw", encoder.encode(password), { name: "PBKDF2" }, false, ["deriveBits"]);
  const derivedBits = await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations: 1e5, hash: "SHA-256" }, keyMaterial, 256);
  const saltB64 = btoa(String.fromCharCode(...salt));
  const hashB64 = btoa(String.fromCharCode(...new Uint8Array(derivedBits)));
  return `pbkdf2$100000$${saltB64}$${hashB64}`;
}
async function verifyPassword(password, stored) {
  if (stored.startsWith("pbkdf2$")) {
    const [, iterStr, saltB64, hashB64] = stored.split("$");
    const iterations = parseInt(iterStr, 10);
    const salt = Uint8Array.from(atob(saltB64), (c) => c.charCodeAt(0));
    const encoder2 = new TextEncoder();
    const keyMaterial = await crypto.subtle.importKey("raw", encoder2.encode(password), { name: "PBKDF2" }, false, ["deriveBits"]);
    const derivedBits = await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations, hash: "SHA-256" }, keyMaterial, 256);
    const computedHashB64 = btoa(String.fromCharCode(...new Uint8Array(derivedBits)));
    return timingSafeEqual(computedHashB64, hashB64);
  }
  const encoder = new TextEncoder();
  const hash = await crypto.subtle.digest("SHA-256", encoder.encode(password));
  return timingSafeEqual(btoa(String.fromCharCode(...new Uint8Array(hash))), stored);
}
async function handleStripeConnect(request, env, path) {
  const orgId = path.split("/")[3];
  const org = await env.FRYDGE_DB.prepare("SELECT id, name, stripe_account_id FROM organisations WHERE id = ?").bind(orgId).first();
  if (!org) return err("Organisation not found", 404);
  if (!env.STRIPE_SECRET_KEY) return err("Missing STRIPE_SECRET_KEY", 500);
  let accountId = org.stripe_account_id;
  if (!accountId) {
    const accountParams = new URLSearchParams({
      type: "express",
      country: "NZ",
      "capabilities[card_payments][requested]": "true",
      "capabilities[transfers][requested]": "true",
      "business_profile[name]": org.name || "Frydge merchant"
    });
    const accountRes = await fetch("https://api.stripe.com/v1/accounts", {
      method: "POST",
      headers: { Authorization: "Bearer " + env.STRIPE_SECRET_KEY, "Content-Type": "application/x-www-form-urlencoded" },
      body: accountParams
    });
    const account = await accountRes.json();
    if (!accountRes.ok) return err(account.error?.message || "Failed to create Stripe account", 400);
    accountId = account.id;
    await env.FRYDGE_DB.prepare("UPDATE organisations SET stripe_account_id = ?, updated_at = ? WHERE id = ?").bind(accountId, Date.now(), orgId).run();
  }
  const linkParams = new URLSearchParams({
    account: accountId,
    refresh_url: `https://manage.frydge2.com?org=${encodeURIComponent(orgId)}&stripe=refresh`,
    return_url: `https://manage.frydge2.com?org=${encodeURIComponent(orgId)}&stripe=return`,
    type: "account_onboarding"
  });
  const linkRes = await fetch("https://api.stripe.com/v1/account_links", {
    method: "POST",
    headers: { Authorization: "Bearer " + env.STRIPE_SECRET_KEY, "Content-Type": "application/x-www-form-urlencoded" },
    body: linkParams
  });
  const link = await linkRes.json();
  if (!linkRes.ok) return err(link.error?.message || "Failed to create Stripe onboarding link", 400);
  return json({ url: link.url, accountId });
}
async function hasVenueRole(env, userId, orgId, allowedRoles) {
  if (!userId || !orgId) return false;
  const member = await env.FRYDGE_DB.prepare("SELECT role FROM org_members WHERE org_id = ? AND user_id = ?").bind(orgId, userId).first();
  return !!(member && allowedRoles.includes(member.role));
}
async function handleTerminalConnectionToken(request, env) {
  const body = await readJSON(request);
  const venueId = body?.venueId;
  if (!venueId) return err("venueId is required");
  const venue = await env.FRYDGE_DB.prepare("SELECT id, org_id, terminal_location_id FROM venues WHERE id = ?").bind(venueId).first();
  if (!venue) return err("Venue not found", 404);
  const allowed = await hasVenueRole(env, request.userId, venue.org_id, ["owner", "admin", "payment_receiver"]);
  if (!allowed) return err("Not permitted to accept Tap to Pay for this venue", 403);
  if (!venue.terminal_location_id) {
    return err("This venue has no Terminal Location set up yet \u2014 an owner or admin needs to run venue setup first (POST /api/venues/:id/terminal-location)", 409);
  }
  const res = await fetch("https://api.stripe.com/v1/terminal/connection_tokens", {
    method: "POST",
    headers: { Authorization: "Bearer " + env.STRIPE_SECRET_KEY, "Content-Type": "application/x-www-form-urlencoded" }
  });
  const data = await res.json();
  if (!res.ok) return err(data.error?.message || "Stripe error", 400);
  return json({ secret: data.secret, locationId: venue.terminal_location_id });
}
async function handleCreateTerminalLocation(request, env, path) {
  const venueId = path.split("/")[3];
  const venue = await env.FRYDGE_DB.prepare("SELECT id, org_id, name, terminal_location_id FROM venues WHERE id = ?").bind(venueId).first();
  if (!venue) return err("Venue not found", 404);
  const allowed = await hasVenueRole(env, request.userId, venue.org_id, ["owner", "admin"]);
  if (!allowed) return err("Only an owner or admin can set up Tap to Pay for this venue", 403);
  if (venue.terminal_location_id) return json({ locationId: venue.terminal_location_id, alreadyExists: true });
  const body = await readJSON(request);
  if (!body?.line1 || !body?.city || !body?.country) return err("line1, city, and country are required");
  if (!env.STRIPE_SECRET_KEY) return err("Missing STRIPE_SECRET_KEY", 500);
  const params = new URLSearchParams({
    display_name: body.displayName || venue.name,
    "address[line1]": body.line1,
    "address[city]": body.city,
    "address[country]": body.country
  });
  if (body.postalCode) params.append("address[postal_code]", body.postalCode);
  if (body.state) params.append("address[state]", body.state);
  const res = await fetch("https://api.stripe.com/v1/terminal/locations", {
    method: "POST",
    headers: { Authorization: "Bearer " + env.STRIPE_SECRET_KEY, "Content-Type": "application/x-www-form-urlencoded" },
    body: params
  });
  const loc = await res.json();
  if (!res.ok) return err(loc.error?.message || "Stripe error", 400);
  await env.FRYDGE_DB.prepare("UPDATE venues SET terminal_location_id = ?, updated_at = ? WHERE id = ?").bind(loc.id, Date.now(), venueId).run();
  return json({ locationId: loc.id }, 201);
}
async function handleStripeWebhook(request, env) {
  const raw = await request.text();
  const sig = request.headers.get("Stripe-Signature");
  const event = await verifyStripeSignature(raw, sig, env.STRIPE_WEBHOOK_SECRET);
  if (!event) return err("Invalid signature", 400);
  const seen = await env.FRYDGE_CACHE.get(`evt:${event.id}`);
  if (seen) return json({ received: true, duplicate: true });
  await env.FRYDGE_CACHE.put(`evt:${event.id}`, "1", { expirationTtl: 86400 });
  if (event.type === "payment_intent.succeeded") {
    const orderId = event.data.object.metadata?.orderId;
    if (orderId) {
      await env.FRYDGE_DB.prepare("UPDATE orders SET status = 'paid', updated_at = ? WHERE id = ? AND status != 'paid'").bind(Date.now(), orderId).run();
    }
  }
  if (event.type === "payment_intent.payment_failed") {
    const orderId = event.data.object.metadata?.orderId;
    if (orderId) {
      await env.FRYDGE_DB.prepare("UPDATE orders SET status = 'cancelled', updated_at = ? WHERE id = ? AND status = 'pending_payment'").bind(Date.now(), orderId).run();
    }
  }
  if (event.type === "account.updated") {
    const acct = event.data.object;
    await env.FRYDGE_DB.prepare("UPDATE organisations SET stripe_onboarded = ?, updated_at = ? WHERE stripe_account_id = ?").bind(acct.charges_enabled && acct.payouts_enabled ? 1 : 0, Date.now(), acct.id).run();
  }
  return json({ received: true });
}
function marketplaceEnabled(env) {
  return env.MARKETPLACE_ENABLED === "true";
}

// ---------------------------------------------------------------------------
// POST /marketplace/orders/create            (channel = "online")
// POST /marketplace/terminal/orders/create   (channel = "in_person")
//
// Body: { attemptId, buyerUserId, sellerUserId?, venueId?, sellerAccountId?,
//         listingId?, listingTitle?, quantity?, amount (cents), currency,
//         applicationFeeAmount?, metadata? }
// Returns: { orderId, paymentIntentId, clientSecret, status, channel, resumed }
//
// Order of operations matters for money:
//   1. reserve the order row under attemptId (UNIQUE) \u2014 no Stripe call yet
//   2. create the PaymentIntent with an Idempotency-Key derived from the
//      reserved order id, so every retry of this attempt reuses one key
//   3. attach the PaymentIntent to the row (conditional update)
// A retry at any point finds the reserved row and resumes from where it got
// to, so a lost response, an app restart or two concurrent taps cannot create
// a second order or a second charge. A changed payload under the same
// attemptId is rejected (409) rather than silently charged.
// ---------------------------------------------------------------------------
async function createMarketplaceOrder(request, env, channel) {
  if (!marketplaceEnabled(env)) return err("Marketplace is not accepting orders", 503);
  const body = await readJSON(request);
  if (!body) return err("Invalid JSON");
  const {
    buyerUserId,
    sellerUserId,
    venueId,
    listingId,
    listingTitle,
    quantity = 1,
    amount,
    currency,
    applicationFeeAmount,
    metadata = {}
  } = body;
  let { sellerAccountId } = body;
  const attemptId = validAttemptId(body.attemptId);
  if (!attemptId) return err("attemptId is required (8\u2013128 chars, [A-Za-z0-9_-])");
  if (!buyerUserId) return err("buyerUserId is required");
  if (!amount || !Number.isFinite(Number(amount))) return err("amount is required (cents)");
  if (!currency) return err("currency is required");
  const amountCents = Math.round(Number(amount));
  if (amountCents <= 0) return err("amount must be positive");

  // Seller payout account is resolved from trusted server records: a venue's
  // organisation, or the P2P seller mapping created at Connect onboarding.
  // A client-supplied sellerAccountId is only honoured when neither matches.
  let venueOnboarded = null;
  let p2pResolved = false;
  if (venueId) {
    const venue = await env.FRYDGE_DB.prepare("SELECT id, org_id FROM venues WHERE id = ?").bind(venueId).first();
    if (!venue) return err("venueId not found", 404);
    const org = await env.FRYDGE_DB.prepare("SELECT stripe_account_id, stripe_onboarded FROM organisations WHERE id = ?").bind(venue.org_id).first();
    venueOnboarded = !!(org?.stripe_account_id && org.stripe_onboarded);
    sellerAccountId = venueOnboarded ? org.stripe_account_id : null;
  } else if (sellerUserId) {
    const p2p = await env.FRYDGE_DB.prepare("SELECT stripe_account_id FROM p2p_sellers WHERE seller_user_id = ?").bind(sellerUserId).first();
    if (p2p?.stripe_account_id) {
      sellerAccountId = p2p.stripe_account_id;
      p2pResolved = true;
    }
  }
  if (sellerAccountId != null && !/^acct_[A-Za-z0-9]+$/.test(sellerAccountId)) {
    return err("sellerAccountId does not look like a Stripe connected account id (acct_\u2026)");
  }

  // The fee never exceeds the order and is never negative, whatever the client sent.
  const requestedFee = applicationFeeAmount != null ? Math.round(Number(applicationFeeAmount)) : Math.round(amountCents * MARKETPLACE_FEE_BPS / 1e4);
  const fee = Math.min(Math.max(Number.isFinite(requestedFee) ? requestedFee : 0, 0), amountCents);
  const fullMetadata = venueId ? { ...metadata, venueId } : metadata;

  // 1. Reserve (or resume) the order under this attempt.
  const reservation = await reserveMarketplaceOrder(env, attemptId, {
    buyerUserId,
    sellerUserId: sellerUserId ?? null,
    venueId: venueId ?? null,
    sellerAccountId: sellerAccountId ?? null,
    listingId: listingId ?? null,
    listingTitle: listingTitle ?? null,
    quantity: Number(quantity) || 1,
    amountCents,
    currency: String(currency).toLowerCase(),
    fee: sellerAccountId ? fee : 0,
    channel,
    metadata: fullMetadata,
    source: channel === "in_person" ? "terminal" : "app",
    detail: { unsplit: !sellerAccountId, venueId: venueId ?? null, venueOnboarded, p2pResolved }
  });
  if (reservation.error) return reservation.error;
  const row = reservation.row;

  // 2./3. Create or resume the PaymentIntent for the reserved order.
  const outcome = await ensureMarketplacePaymentIntent(env, row, (orderId) => {
    const params = new URLSearchParams({
      amount: String(row.amount),
      currency: row.currency,
      "metadata[frydge_order_id]": orderId,
      "metadata[frydge_attempt_id]": attemptId,
      "metadata[buyer_user_id]": row.buyer_user_id,
      "metadata[channel]": channel
    });
    if (channel === "in_person") {
      params.append("payment_method_types[]", "card_present");
      params.append("capture_method", "automatic");
    } else {
      params.append("payment_method_types[]", "card");
    }
    if (row.seller_user_id) params.append("metadata[seller_user_id]", row.seller_user_id);
    if (row.listing_id) params.append("metadata[listing_id]", row.listing_id);
    for (const [k, v] of Object.entries(fullMetadata)) params.append(`metadata[${k}]`, String(v));
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
    channel,
    resumed: outcome.resumed
  });
}

/**
 * Finds the order already reserved for `attemptId`, or inserts one. Returns
 * `{ row }` or `{ error: Response }`. The insert races safely: if two retries
 * arrive together, the UNIQUE index on attempt_id lets exactly one through and
 * the other reads the winner.
 */
async function reserveMarketplaceOrder(env, attemptId, draft) {
  const fingerprint = attemptFingerprint(draft);
  const resume = (row) => {
    if (fingerprintOfRow(row) !== fingerprint) {
      return { error: err("attemptId was already used with a different order", 409) };
    }
    return { row };
  };

  const existing = await env.MARKETPLACE_DB.prepare(`SELECT * FROM orders WHERE attempt_id = ?`).bind(attemptId).first();
  if (existing) return resume(existing);

  const orderId = `ord_${crypto.randomUUID()}`;
  const now = Math.floor(Date.now() / 1e3);
  try {
    await env.MARKETPLACE_DB.prepare(`
      INSERT INTO orders (
        id, attempt_id, payment_intent_id, listing_id, listing_title, quantity,
        buyer_user_id, seller_user_id, seller_account_id,
        amount, currency, platform_fee, channel,
        status, stripe_status, created_at, updated_at, metadata
      ) VALUES (?,?,NULL,?,?,?,?,?,?,?,?,?,?,'pending_payment',NULL,?,?,?)
    `).bind(
      orderId, attemptId, draft.listingId, draft.listingTitle, draft.quantity,
      draft.buyerUserId, draft.sellerUserId, draft.sellerAccountId,
      draft.amountCents, draft.currency, draft.fee, draft.channel,
      now, now, JSON.stringify(draft.metadata ?? {})
    ).run();
  } catch (e) {
    const winner = await env.MARKETPLACE_DB.prepare(`SELECT * FROM orders WHERE attempt_id = ?`).bind(attemptId).first();
    if (!winner) throw e;
    return resume(winner);
  }

  await logMarketplaceEvent(env, orderId, "created", null, "pending_payment", draft.source, { attemptId, ...draft.detail });
  const row = await env.MARKETPLACE_DB.prepare(`SELECT * FROM orders WHERE id = ?`).bind(orderId).first();
  return { row };
}

/**
 * Creates the PaymentIntent for a reserved order, or fetches the existing one
 * when a previous attempt already got that far. Returns `{ pi, resumed }` or
 * `{ error: Response }`.
 */
async function ensureMarketplacePaymentIntent(env, row, buildParams) {
  if (row.payment_intent_id) {
    const res = await stripeGet(`/v1/payment_intents/${row.payment_intent_id}`, env.STRIPE_SECRET_KEY);
    const pi = await res.json();
    if (!res.ok) return { error: err(pi.error?.message ?? "Stripe error", res.status) };
    return { pi, resumed: true };
  }

  // One idempotency key per reserved order, identical on every retry.
  const res = await stripePost("/v1/payment_intents", buildParams(row.id), env.STRIPE_SECRET_KEY, `pi:${row.id}`);
  const pi = await res.json();
  if (!res.ok) {
    // 409 = another retry with the same key is in flight at Stripe. The client
    // retries with the same attemptId and resumes once the row is attached.
    return { error: err(pi.error?.message ?? "Stripe error", res.status) };
  }

  // Attach. Conditional so a concurrent retry cannot swap in a different intent.
  const now = Math.floor(Date.now() / 1e3);
  await env.MARKETPLACE_DB.prepare(`
    UPDATE orders SET payment_intent_id = ?, stripe_status = ?, updated_at = ?
     WHERE id = ? AND (payment_intent_id IS NULL OR payment_intent_id = ?)
  `).bind(pi.id, pi.status, now, row.id, pi.id).run();
  await logMarketplaceEvent(env, row.id, "payment_intent_attached", "pending_payment", "pending_payment", "app", { paymentIntentId: pi.id });
  return { pi, resumed: false };
}
async function marketplaceTerminalToken(env) {
  const res = await fetch("https://api.stripe.com/v1/terminal/connection_tokens", {
    method: "POST",
    headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}`, "Content-Type": "application/x-www-form-urlencoded" }
  });
  const data = await res.json();
  if (!res.ok) return err(data.error?.message ?? "Stripe error", res.status);
  return json({ secret: data.secret });
}
async function listMarketplaceOrders(request, env) {
  const body = await readJSON(request);
  if (!body) return err("Invalid JSON");
  const { userId, role = "buyer", limit = 50 } = body;
  if (!userId) return err("userId is required");
  if (role !== "buyer" && role !== "seller") return err('role must be "buyer" or "seller"');
  const column = role === "buyer" ? "buyer_user_id" : "seller_user_id";
  const capped = Math.min(Math.max(Number(limit) || 50, 1), 200);
  const { results } = await env.MARKETPLACE_DB.prepare(
    `SELECT * FROM orders WHERE ${column} = ? ORDER BY created_at DESC LIMIT ?`
  ).bind(userId, capped).all();
  return json({ orders: (results ?? []).map(shapeMarketplaceOrder) });
}
async function getMarketplaceOrder(request, env) {
  const body = await readJSON(request);
  if (!body?.orderId) return err("orderId is required");
  const row = await env.MARKETPLACE_DB.prepare(`SELECT * FROM orders WHERE id = ?`).bind(body.orderId).first();
  if (!row) return err("Order not found", 404);
  const { results: events } = await env.MARKETPLACE_DB.prepare(
    `SELECT * FROM order_events WHERE order_id = ? ORDER BY created_at DESC LIMIT 50`
  ).bind(body.orderId).all();
  return json({ order: shapeMarketplaceOrder(row), events: events ?? [] });
}
async function markMarketplaceReady(request, env) {
  const body = await readJSON(request);
  if (!body?.orderId || !body?.sellerUserId) return err("orderId and sellerUserId are required");
  const row = await env.MARKETPLACE_DB.prepare(`SELECT * FROM orders WHERE id = ?`).bind(body.orderId).first();
  if (!row) return err("Order not found", 404);
  if (row.seller_user_id && row.seller_user_id !== body.sellerUserId) return err("Not the seller on this order", 403);
  if (row.status !== "paid") return err(`Cannot mark ready from status "${row.status}"`, 409);
  const now = Math.floor(Date.now() / 1e3);
  // Conditional on the status we read: a webhook (refund/dispute) landing
  // between the read and this write must not be overwritten.
  const result = await env.MARKETPLACE_DB.prepare(
    `UPDATE orders SET status = 'ready', seller_marked_ready_at = ?, updated_at = ? WHERE id = ? AND status = 'paid'`
  ).bind(now, now, body.orderId).run();
  if (!result.meta?.changes) return err("Order changed concurrently; reload and retry", 409);
  await logMarketplaceEvent(env, body.orderId, "seller_ready", row.status, "ready", "app", null);
  return json({ ok: true, orderId: body.orderId, status: "ready" });
}
async function confirmMarketplaceReceived(request, env) {
  const body = await readJSON(request);
  if (!body?.orderId || !body?.buyerUserId) return err("orderId and buyerUserId are required");
  const row = await env.MARKETPLACE_DB.prepare(`SELECT * FROM orders WHERE id = ?`).bind(body.orderId).first();
  if (!row) return err("Order not found", 404);
  if (row.buyer_user_id !== body.buyerUserId) return err("Not the buyer on this order", 403);
  if (row.status !== "ready" && row.status !== "paid") return err(`Cannot confirm from status "${row.status}"`, 409);
  const now = Math.floor(Date.now() / 1e3);
  const result = await env.MARKETPLACE_DB.prepare(
    `UPDATE orders SET status = 'received', buyer_confirmed_at = ?, updated_at = ? WHERE id = ? AND status = ?`
  ).bind(now, now, body.orderId, row.status).run();
  if (!result.meta?.changes) return err("Order changed concurrently; reload and retry", 409);
  await logMarketplaceEvent(env, body.orderId, "buyer_confirmed", row.status, "received", "app", null);
  return json({ ok: true, orderId: body.orderId, status: "received" });
}
async function refundMarketplaceOrder(request, env) {
  const body = await readJSON(request);
  if (!body?.orderId) return err("orderId is required");
  const row = await env.MARKETPLACE_DB.prepare(`SELECT * FROM orders WHERE id = ?`).bind(body.orderId).first();
  if (!row) return err("Order not found", 404);
  if (row.status !== "paid" && row.status !== "ready" && row.status !== "received") {
    return err(`Cannot refund from status "${row.status}"`, 409);
  }
  const refundCents = body.amount ? Math.round(Number(body.amount)) : row.amount;
  if (refundCents > row.amount) return err("Refund exceeds order amount");
  const params = new URLSearchParams({
    payment_intent: row.payment_intent_id,
    amount: String(refundCents),
    "metadata[frydge_order_id]": row.id
  });
  if (row.seller_account_id) params.append("refund_application_fee", "true");
  const res = await stripePost("/v1/refunds", params, env.STRIPE_SECRET_KEY, `refund_${row.id}_${refundCents}`);
  const refund = await res.json();
  if (!res.ok) return err(refund.error?.message ?? "Stripe error", res.status);
  const now = Math.floor(Date.now() / 1e3);
  const newStatus = refundCents >= row.amount ? "refunded" : row.status;
  // The refund has already happened at Stripe; the conditional write only
  // avoids clobbering a terminal status (e.g. a dispute) that landed meanwhile.
  // The charge.refunded webhook will reconcile the row either way.
  await env.MARKETPLACE_DB.prepare(
    `UPDATE orders SET status = ?, updated_at = ? WHERE id = ? AND status NOT IN ('refunded', 'disputed')`
  ).bind(newStatus, now, row.id).run();
  await logMarketplaceEvent(env, row.id, "refunded", row.status, newStatus, "app", { refundId: refund.id, amount: refundCents });
  return json({ ok: true, refundId: refund.id, amount: refundCents / 100 });
}
// ---------------------------------------------------------------------------
// POST /marketplace/webhook
//
// The authoritative source for payment status. Stripe signs every delivery;
// nothing is trusted before the signature verifies. Every verified event is
// recorded by Stripe event id in the SAME batch as the order update, so a
// redelivery is idempotent and an event we cannot match yet is kept for
// reconciliation instead of being acknowledged and lost.
// ---------------------------------------------------------------------------
async function handleMarketplaceWebhook(request, env) {
  if (!env.MARKETPLACE_WEBHOOK_SECRET) return err("Webhook secret not configured", 503);
  const raw = await request.text();
  const sig = request.headers.get("Stripe-Signature");
  const event = await verifyStripeSignature(raw, sig, env.MARKETPLACE_WEBHOOK_SECRET);
  if (!event) return err("Invalid signature");
  if (typeof event.id !== "string" || !event.id) return err("Event has no id");

  const object = event.data?.object ?? {};
  const paymentIntentId = object.payment_intent ?? object.id;
  const incoming = HANDLED_EVENTS[event.type];
  // Always 200 for events we don't handle — Stripe retries non-2xx forever.
  if (!incoming || !paymentIntentId) return json({ received: true, ignored: event.type });

  const seen = await env.MARKETPLACE_DB.prepare(`SELECT outcome FROM stripe_events WHERE event_id = ?`).bind(event.id).first();
  if (seen) return json({ received: true, duplicateEvent: event.id, outcome: seen.outcome });

  const now = Math.floor(Date.now() / 1e3);
  const row = await env.MARKETPLACE_DB.prepare(`SELECT * FROM orders WHERE payment_intent_id = ?`).bind(paymentIntentId).first();
  if (!row) {
    // No order yet for this intent (the create call attaches the intent after
    // Stripe may already have fired). Persist the verified event for later
    // reconciliation rather than dropping it.
    await recordStripeEvent(env, event, paymentIntentId, null, "unmatched", now);
    return json({ received: true, unknownOrder: paymentIntentId, stored: true });
  }

  const decision = decidePaymentTransition(row.status, incoming);
  const statements = [];
  if (decision.next) {
    // Conditional on the status we read, so a concurrent seller/buyer action
    // or another delivery cannot be overwritten blindly.
    statements.push(env.MARKETPLACE_DB.prepare(
      `UPDATE orders SET status = ?, stripe_status = ?, updated_at = ? WHERE id = ? AND status = ?`
    ).bind(decision.next, object.status ?? event.type, now, row.id, row.status));
    statements.push(env.MARKETPLACE_DB.prepare(
      `INSERT INTO order_events (order_id, event_type, from_status, to_status, source, detail, created_at) VALUES (?,?,?,?,?,?,?)`
    ).bind(row.id, "webhook", row.status, decision.next, "stripe_webhook", JSON.stringify({ eventId: event.id, eventType: event.type }), now));
  } else if (decision.refreshStripeStatus) {
    // Fulfilment progress is preserved; only the raw provider status moves.
    statements.push(env.MARKETPLACE_DB.prepare(
      `UPDATE orders SET stripe_status = ?, updated_at = ? WHERE id = ?`
    ).bind(object.status ?? event.type, now, row.id));
  }
  const outcome = decision.next ? `applied:${decision.next}` : decision.reason;
  statements.push(stripeEventInsert(env, event, paymentIntentId, row.id, outcome, now));

  try {
    await env.MARKETPLACE_DB.batch(statements);
  } catch (e) {
    // A concurrent delivery of the same event won the race on the event_id
    // primary key: it has been (or is being) applied. Acknowledge.
    if (String(e?.message ?? e).includes("UNIQUE")) return json({ received: true, duplicateEvent: event.id });
    // Anything else: fail the request so Stripe redelivers.
    return err("Could not persist webhook", 500);
  }

  if (decision.next) return json({ received: true, orderId: row.id, status: decision.next });
  return json({ received: true, orderId: row.id, [decision.reason]: `${row.status} <- ${incoming}` });
}
function stripeEventInsert(env, event, paymentIntentId, orderId, outcome, now) {
  return env.MARKETPLACE_DB.prepare(
    `INSERT INTO stripe_events (event_id, event_type, payment_intent_id, order_id, outcome, received_at) VALUES (?,?,?,?,?,?)`
  ).bind(event.id, event.type, paymentIntentId, orderId, outcome, now);
}
async function recordStripeEvent(env, event, paymentIntentId, orderId, outcome, now) {
  try {
    await stripeEventInsert(env, event, paymentIntentId, orderId, outcome, now).run();
  } catch {
    // Duplicate delivery of an unmatched event; already stored.
  }
}
async function logMarketplaceEvent(env, orderId, type, fromStatus, toStatus, source, detail) {
  try {
    await env.MARKETPLACE_DB.prepare(`
      INSERT INTO order_events (order_id, event_type, from_status, to_status, source, detail, created_at)
      VALUES (?,?,?,?,?,?,?)
    `).bind(orderId, type, fromStatus, toStatus, source, detail ? JSON.stringify(detail) : null, Math.floor(Date.now() / 1e3)).run();
  } catch {
  }
}
function shapeMarketplaceOrder(row) {
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
    channel: row.channel,
    status: row.status,
    stripeStatus: row.stripe_status,
    sellerMarkedReadyAt: row.seller_marked_ready_at,
    buyerConfirmedAt: row.buyer_confirmed_at,
    createdAt: row.created_at,
    updatedAt: row.updated_at
  };
}
function stripePost(path, params, key, idempotencyKey) {
  const headers = { Authorization: `Bearer ${key}`, "Content-Type": "application/x-www-form-urlencoded" };
  if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;
  return fetch(`https://api.stripe.com${path}`, { method: "POST", headers, body: params.toString() });
}
function stripeGet(path, key) {
  return fetch(`https://api.stripe.com${path}`, { method: "GET", headers: { Authorization: `Bearer ${key}` } });
}
async function readJSON(request) {
  try {
    return await request.json();
  } catch {
    return null;
  }
}
async function legacyCreatePaymentIntent(request, env) {
  const body = await readJSON(request);
  if (!body) return err("Invalid JSON body");
  const { amount, currency, metadata = {} } = body;
  if (!amount || !currency) return err("amount and currency are required");
  const params = new URLSearchParams({
    amount: String(Math.round(Number(amount))),
    currency: String(currency).toLowerCase(),
    "payment_method_types[]": "card"
  });
  for (const [k, v] of Object.entries(metadata)) params.append(`metadata[${k}]`, String(v));
  const res = await stripePost("/v1/payment_intents", params, env.STRIPE_SECRET_KEY);
  const pi = await res.json();
  if (!res.ok) return err(pi.error?.message ?? "Stripe error", res.status);
  return json({ clientSecret: pi.client_secret, paymentIntentId: pi.id });
}
async function legacyConfirmApplePay(request, env) {
  const body = await readJSON(request);
  if (!body) return err("Invalid JSON body");
  const { paymentIntentId, paymentData, transactionIdentifier, paymentNetwork, sellerAccountId } = body;
  if (!paymentIntentId || !paymentData || !transactionIdentifier) {
    return err("paymentIntentId, paymentData, and transactionIdentifier are required");
  }
  if (!env.STRIPE_PUBLISHABLE_KEY) return err("Missing STRIPE_PUBLISHABLE_KEY", 500);
  const tokenParams = new URLSearchParams({ pk_token: paymentData, pk_token_transaction_identifier: transactionIdentifier });
  if (paymentNetwork) tokenParams.append("pk_token_payment_network", paymentNetwork);
  const tokenRes = await stripePost("/v1/tokens", tokenParams, env.STRIPE_PUBLISHABLE_KEY);
  const tokenData = await tokenRes.json();
  if (!tokenRes.ok) return err(`Apple Pay token error: ${tokenData.error?.message ?? "unknown"}`, 400);
  const pmParams = new URLSearchParams({ type: "card", "card[token]": tokenData.id });
  const pmRes = await stripePost("/v1/payment_methods", pmParams, env.STRIPE_SECRET_KEY);
  const pm = await pmRes.json();
  if (!pmRes.ok) return err(`PaymentMethod error: ${pm.error?.message ?? "unknown"}`, 400);
  const confirmParams = new URLSearchParams({ payment_method: pm.id, return_url: "frydge://payment-return" });
  if (sellerAccountId) confirmParams.append("transfer_data[destination]", sellerAccountId);
  const confirmRes = await stripePost(`/v1/payment_intents/${paymentIntentId}/confirm`, confirmParams, env.STRIPE_SECRET_KEY);
  const pi = await confirmRes.json();
  if (!confirmRes.ok) return err(`Confirmation error: ${pi.error?.message ?? "unknown"}`, 400);
  if (pi.status !== "succeeded") return err(`Payment status: ${pi.status}. Additional action may be required.`, 402);
  return json({ success: true, paymentIntentId: pi.id, status: pi.status });
}
async function legacyConnectOnboard(request, env) {
  const body = await readJSON(request);
  if (!body) return err("Invalid JSON body");
  const { email, returnUrl, refreshUrl, existingAccountId, sellerUserId } = body;
  if (!returnUrl || !refreshUrl) return err("returnUrl and refreshUrl are required");
  let accountId = existingAccountId?.trim();
  if (!accountId) {
    if (!email) return err("email is required to create a new account");
    const accountParams = new URLSearchParams({
      type: "express",
      email,
      "capabilities[card_payments][requested]": "true",
      "capabilities[transfers][requested]": "true",
      business_type: "individual"
    });
    const accountRes = await stripePost("/v1/accounts", accountParams, env.STRIPE_SECRET_KEY);
    const account = await accountRes.json();
    if (!accountRes.ok) return err(`Account creation error: ${account.error?.message ?? "unknown"}`, 400);
    accountId = account.id;
  }
  if (sellerUserId) {
    const now = Date.now();
    await env.FRYDGE_DB.prepare(
      `INSERT INTO p2p_sellers (seller_user_id, stripe_account_id, created_at, updated_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(seller_user_id) DO UPDATE SET stripe_account_id = excluded.stripe_account_id, updated_at = excluded.updated_at`
    ).bind(sellerUserId, accountId, now, now).run();
  }
  const linkParams = new URLSearchParams({ account: accountId, refresh_url: refreshUrl, return_url: returnUrl, type: "account_onboarding" });
  const linkRes = await stripePost("/v1/account_links", linkParams, env.STRIPE_SECRET_KEY);
  const link = await linkRes.json();
  if (!linkRes.ok) return err(`Account link error: ${link.error?.message ?? "unknown"}`, 400);
  return json({ accountId, onboardingUrl: link.url });
}
async function legacyConnectAccountStatus(request, env) {
  const body = await readJSON(request);
  if (!body?.accountId) return err("accountId is required");
  const res = await fetch(`https://api.stripe.com/v1/accounts/${body.accountId}`, {
    headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` }
  });
  const account = await res.json();
  if (!res.ok) return err(account.error?.message ?? "Stripe error", res.status);
  return json({ chargesEnabled: account.charges_enabled, payoutsEnabled: account.payouts_enabled, detailsSubmitted: account.details_submitted });
}
async function legacyConnectCreateIntent(request, env) {
  const body = await readJSON(request);
  if (!body) return err("Invalid JSON body");
  const { amount, currency, sellerAccountId, applicationFeeAmount, metadata = {} } = body;
  if (!amount || !currency || !sellerAccountId) return err("amount, currency, and sellerAccountId are required");
  const roundedAmount = Math.round(Number(amount));
  const feeAmount = applicationFeeAmount != null ? Math.round(Number(applicationFeeAmount)) : Math.round(roundedAmount * 0.05);
  const params = new URLSearchParams({
    amount: String(roundedAmount),
    currency: String(currency).toLowerCase(),
    "payment_method_types[]": "card",
    "transfer_data[destination]": sellerAccountId,
    application_fee_amount: String(feeAmount)
  });
  for (const [k, v] of Object.entries(metadata)) params.append(`metadata[${k}]`, String(v));
  const res = await stripePost("/v1/payment_intents", params, env.STRIPE_SECRET_KEY);
  const pi = await res.json();
  if (!res.ok) return err(pi.error?.message ?? "Stripe error", res.status);
  return json({ clientSecret: pi.client_secret, paymentIntentId: pi.id });
}
