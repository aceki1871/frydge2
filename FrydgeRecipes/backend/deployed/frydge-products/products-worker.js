var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// src/products-worker.js
var ATTRIBUTION = "Product data from Open Food Facts, licensed under ODbL v1.0 \u2014 https://opendatacommons.org/licenses/odbl/1-0/";
var products_worker_default = {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") return cors(new Response(null, { status: 204 }));
    if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
    try {
      if (url.pathname.startsWith("/v1/product/")) {
        const raw = decodeURIComponent(url.pathname.slice("/v1/product/".length));
        return await handleProduct(raw, env, ctx, request);
      }
      if (url.pathname === "/v1/search") {
        return await handleSearch(url, env);
      }
      if (url.pathname === "/v1/products") {
        return await handleBatch(url, env);
      }
      if (url.pathname === "/v1/health") {
        return await handleHealth(env);
      }
      return json({ error: "not_found" }, 404);
    } catch (err) {
      console.error("worker error", err);
      return json({ error: "internal", detail: String(err) }, 500);
    }
  }
};
function toGTIN14(input) {
  const digits = String(input ?? "").replace(/\D/g, "");
  if (!digits) return null;
  if (digits.length > 14) return digits.slice(-14);
  return digits.padStart(14, "0");
}
__name(toGTIN14, "toGTIN14");
async function handleProduct(rawCode, env, ctx, request) {
  const gtin = toGTIN14(rawCode);
  if (!gtin) return json({ error: "invalid_barcode" }, 400);
  const cache = caches.default;
  const cacheKey = new Request(new URL(`/v1/product/${gtin}`, request.url), request);
  const cached = await cache.match(cacheKey);
  if (cached) return cached;
  const row = await env.PRODUCTS_DB.prepare("SELECT * FROM products WHERE gtin = ?1").bind(gtin).first();
  if (row) {
    const res2 = json({ source: row.source, product: shape(row) }, 200, env);
    ctx.waitUntil(cache.put(cacheKey, res2.clone()));
    return res2;
  }
  if (env.OFF_FALLBACK !== "1") {
    return json({ error: "not_found", gtin }, 404, env);
  }
  const live = await fetchFromOFF(rawCode, env);
  if (!live) return json({ error: "not_found", gtin }, 404, env);
  ctx.waitUntil(upsert(env, live));
  const res = json({ source: "live", product: shape(live) }, 200, env);
  ctx.waitUntil(cache.put(cacheKey, res.clone()));
  return res;
}
__name(handleProduct, "handleProduct");
async function handleSearch(url, env) {
  const q = (url.searchParams.get("q") || "").trim();
  const limit = Math.min(parseInt(url.searchParams.get("limit") || "20", 10) || 20, 50);
  const full = url.searchParams.get("full") === "1";
  if (q.length < 2) return json({ error: "query_too_short" }, 400);
  const terms = q.replace(/["*^:(){}\[\]-]/g, " ").split(/\s+/).filter((t) => t.length > 1).slice(0, 5).map((t) => `"${t}"*`).join(" AND ");
  if (!terms) return json({ query: q, count: 0, results: [] }, 200, env);
  const extra = full ? ", p.ingredients_text, p.categories" : "";
  const { results } = await env.PRODUCTS_DB.prepare(
    `SELECT p.gtin, p.code, p.name, p.brand, p.quantity, p.qty_value, p.qty_unit,
              p.image_url, p.image_small_url,
              p.nutriscore, p.nova, p.ecoscore,
              p.is_vegan, p.is_vegetarian, p.is_gluten_free, p.is_dairy_free,
              p.energy_kcal_100g, p.fat_100g, p.satfat_100g, p.carbs_100g,
              p.sugars_100g, p.fibre_100g, p.protein_100g, p.salt_100g,
              p.updated_at${extra}
         FROM products_fts
         JOIN products p ON p.rowid = products_fts.rowid
        WHERE products_fts MATCH ?1
        ORDER BY bm25(products_fts, 1.0, 0.5)
        LIMIT ?2`
  ).bind(terms, limit).all();
  return json({ query: q, count: results.length, results: results.map(shape) }, 200, env);
}
__name(handleSearch, "handleSearch");
async function handleBatch(url, env) {
  const raw = (url.searchParams.get("codes") || "").split(",").filter(Boolean);
  if (raw.length === 0) return json({ error: "no_codes" }, 400);
  const gtins = [...new Set(raw.map(toGTIN14).filter(Boolean))].slice(0, 100);
  if (gtins.length === 0) return json({ error: "no_valid_codes" }, 400);
  const placeholders = gtins.map((_, i) => `?${i + 1}`).join(",");
  const { results } = await env.PRODUCTS_DB.prepare(`SELECT * FROM products WHERE gtin IN (${placeholders})`).bind(...gtins).all();
  const found = results.map(shape);
  const foundSet = new Set(found.map((p) => p.gtin));
  return json({
    count: found.length,
    requested: gtins.length,
    missing: gtins.filter((g) => !foundSet.has(g)),
    results: found
  }, 200, env);
}
__name(handleBatch, "handleBatch");
async function handleHealth(env) {
  const count = await env.PRODUCTS_DB.prepare("SELECT COUNT(*) AS n FROM products").first();
  const { results: meta } = await env.PRODUCTS_DB.prepare("SELECT key, value FROM meta").all();
  return json({
    ok: true,
    products: count?.n ?? 0,
    meta: Object.fromEntries(meta.map((m) => [m.key, m.value]))
  });
}
__name(handleHealth, "handleHealth");
async function fetchFromOFF(code, env) {
  const fields = [
    "code",
    "product_name",
    "brands",
    "quantity",
    "categories",
    "labels_tags",
    "allergens_tags",
    "traces_tags",
    "image_url",
    "image_small_url",
    "nutriscore_grade",
    "nova_group",
    "ecoscore_grade",
    "nutriments",
    "ingredients_text",
    "countries"
  ].join(",");
  const url = `https://world.openfoodfacts.org/api/v2/product/${encodeURIComponent(
    code
  )}.json?fields=${fields}`;
  const res = await fetch(url, {
    headers: {
      // REQUIRED by OFF's terms. Without it you risk an IP ban.
      "User-Agent": env.OFF_USER_AGENT || "Frydge/1.0",
      Accept: "application/json"
    },
    // OFF returns 200 for misses, so we can safely cache the response briefly.
    cf: { cacheTtl: 300, cacheEverything: true }
  });
  if (!res.ok) return null;
  const body = await res.json().catch(() => null);
  if (!body || body.status !== 1 || !body.product) return null;
  return mapOFFProduct(body.product);
}
__name(fetchFromOFF, "fetchFromOFF");
function mapOFFProduct(p) {
  const n = p.nutriments || {};
  const labels = arr(p.labels_tags);
  const allergens = arr(p.allergens_tags);
  const traces = arr(p.traces_tags);
  const { value, unit } = parseQuantity(p.quantity);
  return {
    gtin: toGTIN14(p.code),
    code: String(p.code ?? ""),
    name: clean(p.product_name),
    brand: clean(p.brands),
    quantity: clean(p.quantity),
    qty_value: value,
    qty_unit: unit,
    categories: clean(p.categories),
    labels: labels.join(","),
    allergens: allergens.join(","),
    traces: traces.join(","),
    image_url: p.image_url || null,
    image_small_url: p.image_small_url || null,
    ...dietaryFlags(labels, allergens, p.ingredients_text),
    nutriscore: p.nutriscore_grade || null,
    nova: p.nova_group ?? null,
    ecoscore: p.ecoscore_grade || null,
    energy_kcal_100g: num(n["energy-kcal_100g"]),
    fat_100g: num(n.fat_100g),
    satfat_100g: num(n["saturated-fat_100g"]),
    carbs_100g: num(n.carbohydrates_100g),
    sugars_100g: num(n.sugars_100g),
    fibre_100g: num(n.fiber_100g),
    protein_100g: num(n.proteins_100g),
    salt_100g: num(n.salt_100g),
    ingredients_text: clean(p.ingredients_text, 4e3),
    countries: clean(p.countries),
    source: "live",
    updated_at: Math.floor(Date.now() / 1e3)
  };
}
__name(mapOFFProduct, "mapOFFProduct");
function dietaryFlags(labels, allergens, ingredientsText) {
  const L = labels.map((s) => s.toLowerCase());
  const A = allergens.map((s) => s.toLowerCase());
  const hasText = !!(ingredientsText && ingredientsText.length > 5);
  const labelled = /* @__PURE__ */ __name((...keys) => keys.some((k) => L.some((l) => l.includes(k))), "labelled");
  const allergen = /* @__PURE__ */ __name((...keys) => keys.some((k) => A.some((a) => a.includes(k))), "allergen");
  let is_vegan = labelled("vegan") ? 1 : null;
  let is_vegetarian = labelled("vegetarian") || is_vegan === 1 ? 1 : null;
  let is_gluten_free = labelled("gluten-free", "no-gluten") ? 1 : null;
  let is_dairy_free = labelled("dairy-free", "lactose-free") || is_vegan === 1 ? 1 : null;
  if (allergen("gluten")) is_gluten_free = 0;
  if (allergen("milk")) {
    is_dairy_free = 0;
    is_vegan = 0;
  }
  if (allergen("eggs")) is_vegan = 0;
  if (allergen("fish", "crustaceans", "molluscs")) {
    is_vegan = 0;
    is_vegetarian = 0;
  }
  if (is_gluten_free === null && hasText && !allergen("gluten")) is_gluten_free = null;
  return { is_vegan, is_vegetarian, is_gluten_free, is_dairy_free };
}
__name(dietaryFlags, "dietaryFlags");
async function upsert(env, p) {
  await env.PRODUCTS_DB.prepare(
    `INSERT OR REPLACE INTO products
        (gtin, code, name, brand, quantity, qty_value, qty_unit, categories, labels,
         allergens, traces, image_url, image_small_url, is_vegan, is_vegetarian,
         is_gluten_free, is_dairy_free, nutriscore, nova, ecoscore,
         energy_kcal_100g, fat_100g, satfat_100g, carbs_100g, sugars_100g,
         fibre_100g, protein_100g, salt_100g, ingredients_text, countries,
         source, updated_at)
       VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,
               ?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32)`
  ).bind(
    p.gtin,
    p.code,
    p.name,
    p.brand,
    p.quantity,
    p.qty_value,
    p.qty_unit,
    p.categories,
    p.labels,
    p.allergens,
    p.traces,
    p.image_url,
    p.image_small_url,
    p.is_vegan,
    p.is_vegetarian,
    p.is_gluten_free,
    p.is_dairy_free,
    p.nutriscore,
    p.nova,
    p.ecoscore,
    p.energy_kcal_100g,
    p.fat_100g,
    p.satfat_100g,
    p.carbs_100g,
    p.sugars_100g,
    p.fibre_100g,
    p.protein_100g,
    p.salt_100g,
    p.ingredients_text,
    p.countries,
    p.source,
    p.updated_at
  ).run();
}
__name(upsert, "upsert");
function parseQuantity(raw) {
  if (!raw) return { value: null, unit: null };
  const m = String(raw).match(/(\d+(?:[.,]\d+)?)\s*(kg|g|mg|l|ml|cl|oz|lb)\b/i);
  if (!m) return { value: null, unit: null };
  return { value: parseFloat(m[1].replace(",", ".")), unit: m[2].toLowerCase() };
}
__name(parseQuantity, "parseQuantity");
function arr(v) {
  return Array.isArray(v) ? v.filter(Boolean).map(String) : [];
}
__name(arr, "arr");
function num(v) {
  const n = typeof v === "number" ? v : parseFloat(v);
  return Number.isFinite(n) ? n : null;
}
__name(num, "num");
function clean(s, max = 300) {
  if (s == null) return null;
  const t = String(s).replace(/[\u0000-\u001F\u007F]/g, " ").replace(/\s+/g, " ").trim();
  return t ? t.slice(0, max) : null;
}
__name(clean, "clean");
function shape(r) {
  return {
    gtin: r.gtin,
    code: r.code,
    name: r.name,
    brand: r.brand,
    quantity: r.quantity,
    quantityValue: r.qty_value,
    quantityUnit: r.qty_unit,
    categories: r.categories,
    imageURL: r.image_url,
    imageSmallURL: r.image_small_url,
    dietary: {
      vegan: r.is_vegan,
      vegetarian: r.is_vegetarian,
      glutenFree: r.is_gluten_free,
      dairyFree: r.is_dairy_free
    },
    nutriscore: r.nutriscore,
    nova: r.nova,
    ecoscore: r.ecoscore,
    nutrition: {
      energyKcal100g: r.energy_kcal_100g,
      fat100g: r.fat_100g,
      satFat100g: r.satfat_100g,
      carbs100g: r.carbs_100g,
      sugars100g: r.sugars_100g,
      fibre100g: r.fibre_100g,
      protein100g: r.protein_100g,
      salt100g: r.salt_100g
    },
    ingredientsText: r.ingredients_text,
    updatedAt: r.updated_at
  };
}
__name(shape, "shape");
function json(body, status = 200, env = {}) {
  const headers = {
    "Content-Type": "application/json; charset=utf-8",
    "X-Data-Attribution": ATTRIBUTION
  };
  if (status === 200 && env.EDGE_TTL) {
    headers["Cache-Control"] = `public, max-age=${env.EDGE_TTL}`;
  }
  return cors(new Response(JSON.stringify(body), { status, headers }));
}
__name(json, "json");
function cors(res) {
  res.headers.set("Access-Control-Allow-Origin", "*");
  res.headers.set("Access-Control-Allow-Methods", "GET, OPTIONS");
  res.headers.set("Access-Control-Allow-Headers", "Content-Type");
  return res;
}
__name(cors, "cors");
export {
  products_worker_default as default,
  dietaryFlags,
  parseQuantity,
  toGTIN14
};
//# sourceMappingURL=products-worker.js.map
