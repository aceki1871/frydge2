var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// cloudflare-worker-recipe-sharing.js
var APPLE_MERCHANT_DOMAIN_ASSOCIATION = "MIIQXgYJKoZIhvcNAQcCoIIQTzCCEEsCAQExCzAJBgUrDgMCGgUAMG0GCSqGSIb3DQEHAaBgBF57\nInRlYW1JZCI6IkEySDNZUTVVNzkiLCJkb21haW4iOiJmcnlkZ2UyLmNvbSIsImRhdGVDcmVhdGVk\nIjoiMjAyNi0wNS0yNSwwNzozNjowNiIsInZlcnNpb24iOjF9oIINPzCCBDQwggMcoAMCAQICCEYg\nLbwDT4-2MA0GCSqGSIb3DQEBCwUAMHMxLTArBgNVBAMMJEFwcGxlIGlQaG9uZSBDZXJ0aWZpY2F0\naW9uIEF1dGhvcml0eTEgMB4GA1UECwwXQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxEzARBgNVBAoM\nCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTMB4XDTI2MDEyODE5NTU1MloXDTMwMTIzMTAwMDAwMFow\nWTE1MDMGA1UEAwwsQXBwbGUgaVBob25lIE9TIFByb3Zpc2lvbmluZyBQcm9maWxlIFNpZ25pbmcx\nEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A\nMIIBCgKCAQEAuAHGAqf6LSCrzkatFVhzLum8NWXlrHLZBlgdGZc6A6KQHeeqQX3r-eQDXmsJ4qh0\njw-zQjPFR53T04WsiypiLm0sTY6JesoMU-ndpB5upQJp_HboBGw4PS3yqjN1gSPLhwne5tv_epkS\nn5xSg3ExVfl-rTsldVJT4DKzYGFOGat7BEW8q1drCA-UzpUyRAJbiq1yIMCqZzsyzzeHVUWjk6Li\nHnD_pG-CBYTBmT5p1mp3EwpZQTRaEQ2kLhDZscZrP2FVIANCo05Bivk8Rd_VlwS_TShNfBC5fm0s\nPrAjet1olpNpJ1qOp7l0EYHnwSDb_J2bZMoPLcwNmVQzAxe-fQIDAQABo4HlMIHiMAwGA1UdEwEB\n_wQCMAAwHwYDVR0jBBgwFoAUb_GVGGJc4Mjxxe1sGMng02RSmCAwQAYIKwYBBQUHAQEENDAyMDAG\nCCsGAQUFBzABhiRodHRwOi8vb2NzcC5hcHBsZS5jb20vb2NzcDAzLWFpcGNhMDcwLwYDVR0fBCgw\nJjAkoCKgIIYeaHR0cDovL2NybC5hcHBsZS5jb20vYWlwY2EuY3JsMB0GA1UdDgQWBBQ7FGgQTyYt\njtoLSVAXba5kPv-WETAOBgNVHQ8BAf8EBAMCB4AwDwYJKoZIhvdjZAY6BAIFADANBgkqhkiG9w0B\nAQsFAAOCAQEAOkB4qcVsCxyO4PH-Em0zTr5uD9JWzi--CTbitmmRSbEKo3xoEkNYevljx-Oe6wd-\nREaW8HWnpHx6Hv49_N9C9rxzjLNAylE50ULz4feKfdbIZ2o-8yTA9U3CHCf3OuuFXubvO2MbfEgG\nsjCIw7cAWWj1QO2Fz5ga4dbSYi1MlZvSLkvkLeodwYFEnmozgS4WS_JXUI0Ozgk2mBcgPf4E4LL8\nnNM6Y6Ui_tOAMOMiYw-dd0AOo2ziyOYat1mNNSHY8p43nTxFTdoxhlOrHpLxSWIAJbBODwxiETDr\nYnRw_OgE2YZXoV4o0-Ll2ooYeRbkcMF5mLlDjM_HBd_eKnGnvzCCBEQwggMsoAMCAQICCFxjyuRK\nN1PJMA0GCSqGSIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRMwEQYDVQQKEwpBcHBsZSBJbmMuMSYw\nJAYDVQQLEx1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTEWMBQGA1UEAxMNQXBwbGUgUm9v\ndCBDQTAeFw0xNzA1MTAyMTI3MzBaFw0zMDEyMzEwMDAwMDBaMHMxLTArBgNVBAMMJEFwcGxlIGlQ\naG9uZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTEgMB4GA1UECwwXQ2VydGlmaWNhdGlvbiBBdXRo\nb3JpdHkxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTMIIBIjANBgkqhkiG9w0BAQEF\nAAOCAQ8AMIIBCgKCAQEAyUVqAQ8-gwSGx_y_3F7wHoHuFzBzYyYu3j16JM2TPk85R7p1vvPA0vFZ\noqsf_gqGPNktmgfyDmu5KZEaXyIKi_FyWAWuTEtExXmngDywiOCMDCeEXRnlhxk2y-PFdrew9EFy\nUfQFXINLom2mUbjxJt97Xq1lDMaymFGMu30bTMFOyAjH0u1kC7TdG41PQH0bj0iWklvz0Jh-2byk\nGQ6ZYbtBXQHMW3d6fSTQ3NNT_8PcxZQstlpNjhgjOb3ZxlI-0fL0JYqhKof92AxGKVH_7RdsiSVr\nh7-KaRSfd5_DFbdos4hFvYTmBgJBZA-tKii4FcngrKeKunIENLJ4jPiyhQIDAQABo4HsMIHpMA8G\nA1UdEwEB_wQFMAMBAf8wHwYDVR0jBBgwFoAUK9BpR5R2Cf70a40uQKb3R01_CF4wRAYIKwYBBQUH\nAQEEODA2MDQGCCsGAQUFBzABhihodHRwOi8vb2NzcC5hcHBsZS5jb20vb2NzcDAzLWFwcGxlcm9v\ndGNhMC4GA1UdHwQnMCUwI6AhoB-GHWh0dHA6Ly9jcmwuYXBwbGUuY29tL3Jvb3QuY3JsMB0GA1Ud\nDgQWBBRv8ZUYYlzgyPHF7WwYyeDTZFKYIDAOBgNVHQ8BAf8EBAMCAQYwEAYKKoZIhvdjZAYCEgQC\nBQAwDQYJKoZIhvcNAQELBQADggEBADrPrJiNvpIgIQmtlfOxXCH6Ni1XIER0c2SSCLOWrPdtl_pb\nNDgnzxJG0zwR8AfJmZCx0egRCaXjpWtsYwg_niX61ZmcTOblzo6yTWjsi6ujok-KERU-3BQrHMZE\ntm9nxVtPlSkth1w_3IMed0_t2lSnLecTgcFjxFQLG0sKaigiCNQ3knx_Zyhfrz0_t6xZHTg0ZFru\nM0oZQkQpxMoYa-HBUy0t9E3CFfYzMhh48SZvik3rlEyj6P8PswOLZdrrLthlUJ_cn4rfMaiEVNxS\nUkHSshMdMUZHiF8-7sPyjCMEleusij6CbAafLuOLQ5piWzQN9JnPLO66coYZI6X8jrUwggS7MIID\no6ADAgECAgECMA0GCSqGSIb3DQEBBQUAMGIxCzAJBgNVBAYTAlVTMRMwEQYDVQQKEwpBcHBsZSBJ\nbmMuMSYwJAYDVQQLEx1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTEWMBQGA1UEAxMNQXBw\nbGUgUm9vdCBDQTAeFw0wNjA0MjUyMTQwMzZaFw0zNTAyMDkyMTQwMzZaMGIxCzAJBgNVBAYTAlVT\nMRMwEQYDVQQKEwpBcHBsZSBJbmMuMSYwJAYDVQQLEx1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhv\ncml0eTEWMBQGA1UEAxMNQXBwbGUgUm9vdCBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoC\nggEBAOSRqQkfkdseR1DrBe1eeYQt6zaiV0xV7IsZid75S2z1B6siMALoGD74UAnTf0GomPnRymac\nJGsR0KO75Bsqwx-VnnoMpEeLW9QWNzPLxA9NzhRp0ckZcvVdDtV_X5vyJQO6VY9NXQ3xZDUjFUsV\nWR2zlPf2nJ7PULrBWFBnjwi0IPfLrCwgb3C2PwEwjLdDzw-dPfMrSSgayP7OtbkO2V4c1ss9tTqt\n9A8OAJILsSEWLnTVPA3bYharo3GSR1NVwa8vQbP4--NwzeajTEV-H0xrUJZBicR0YgsQg0GHM4qB\nsTBY7FoEMoxos48d3mVz_2deZbxJ2HafMxRloXeUyS0CAwEAAaOCAXowggF2MA4GA1UdDwEB_wQE\nAwIBBjAPBgNVHRMBAf8EBTADAQH_MB0GA1UdDgQWBBQr0GlHlHYJ_vRrjS5ApvdHTX8IXjAfBgNV\nHSMEGDAWgBQr0GlHlHYJ_vRrjS5ApvdHTX8IXjCCAREGA1UdIASCAQgwggEEMIIBAAYJKoZIhvdj\nZAUBMIHyMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5hcHBsZS5jb20vYXBwbGVjYS8wgcMGCCsG\nAQUFBwICMIG2GoGzUmVsaWFuY2Ugb24gdGhpcyBjZXJ0aWZpY2F0ZSBieSBhbnkgcGFydHkgYXNz\ndW1lcyBhY2NlcHRhbmNlIG9mIHRoZSB0aGVuIGFwcGxpY2FibGUgc3RhbmRhcmQgdGVybXMgYW5k\nIGNvbmRpdGlvbnMgb2YgdXNlLCBjZXJ0aWZpY2F0ZSBwb2xpY3kgYW5kIGNlcnRpZmljYXRpb24g\ncHJhY3RpY2Ugc3RhdGVtZW50cy4wDQYJKoZIhvcNAQEFBQADggEBAFw2mUwteLftjJvc83eb8nbS\ndzBPwR-Fg4UbmT1HN_Kpm0COLNSxkBLYvvRzm-7SZA_LeU802KI--Xj_a8gH7H05g4tTINM4xLG_\nmk8Ka_8r_FmnBQl8F0BWER5007eLIztHo9VvJOLr0bdw3w9F4SfK8W147ee1Fxeo3H4iNcol1dkP\n1mvUoiQjEfehrI9zgWDGG1sJL5Ky-ERI8GA4nhX1PSZnIIozavcNgs_e66Mv-VNqW2TAYzN39zoH\nLFbr2g8hDtq6cxlPtdk2f8GHVdmnmbkyQvvY1XGefqFStxu9k0IkEirHDx22TZxeY8hLgBdQqorV\n2uT80AkHN7B1dSExggKFMIICgQIBATB_MHMxLTArBgNVBAMMJEFwcGxlIGlQaG9uZSBDZXJ0aWZp\nY2F0aW9uIEF1dGhvcml0eTEgMB4GA1UECwwXQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxEzARBgNV\nBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTAghGIC28A0-PtjAJBgUrDgMCGgUAoIHcMBgGCSqG\nSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2MDUyNTA3MzYwNlowIwYJKoZI\nhvcNAQkEMRYEFG0oJ2gzXUoVeLSiTrABn5rpfq4CMCkGCSqGSIb3DQEJNDEcMBowCQYFKw4DAhoF\nAKENBgkqhkiG9w0BAQEFADBSBgkqhkiG9w0BCQ8xRTBDMAoGCCqGSIb3DQMHMA4GCCqGSIb3DQMC\nAgIAgDANBggqhkiG9w0DAgIBQDAHBgUrDgMCBzANBggqhkiG9w0DAgIBKDANBgkqhkiG9w0BAQEF\nAASCAQA6_L_WbwjuGlYtt862yWjlQ_V8jbrG-WJcWCpUQkHZtxKuN8FhPP_pSmbaOVzFHb9ppIuk\n1dA31t5A5ViiwKYY3S_QssDLr-GN4aJ7ZFM1Uo16AiIkkhEJyQwtVi0phKhx_EbwE38O3yRV4tu4\n18DkWym1dwgHqc1pOx9i0h8euRc8DVdsjaPU_UoT76rhWXVRDzTTezrVfB9TXEBEWwkdnp-Q5W0n\nxPxa_nX5jsi2dImpZj8scr0_fBrXCsOo83X4ymihnvYCzmw2hhSozdx93kMBbSzv6apZsh1ufztX\n_V8XGFNFB_3poLdxHpGMmg-ieVQn1lVXN6kWSYfyeSlT\n";
var TEAM_ID = "A2H3YQ5U79";
var BUNDLE_ID = "Clark-Online.Recipes";
var DOMAIN = "https://frydge2.com";
var UPLOAD_KEY = "frydge2webrecipes";
var DEFAULT_IMAGE_URL = `${DOMAIN}/images/default-recipe.svg`;
var PREVIEW_USER_AGENT_PATTERN = /(bot|crawler|spider|preview|facebookexternalhit|facebot|twitterbot|slackbot|discordbot|whatsapp|telegram|linkedinbot|pinterest|applebot|messages|google|bingbot)/i;
var cloudflare_worker_recipe_sharing_default = {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/.well-known/apple-developer-merchantid-domain-association.txt") {
      return new Response(APPLE_MERCHANT_DOMAIN_ASSOCIATION, {
        status: 200,
        headers: {
          "Content-Type": "text/plain; charset=utf-8",
          "Cache-Control": "public, max-age=3600",
          "Access-Control-Allow-Origin": "*"
        }
      });
    }
    if (request.method === "OPTIONS") {
      return corsResponse(null, 204);
    }
    if (url.pathname === "/.well-known/apple-app-site-association") {
      return jsonResponse(appleAppSiteAssociation());
    }
    if (url.pathname === "/api/share-recipe" && request.method === "POST") {
      return saveRecipeShare(request, env);
    }
    if (url.pathname === "/images/default-recipe.svg") {
      return defaultRecipeImageResponse();
    }
    const imageMatch = url.pathname.match(/^\/images\/([^/]+)\.jpg$/);
    if (imageMatch) {
      return recipeImageResponse(imageMatch[1], env);
    }
    const recipeMatch = url.pathname.match(/^\/recipe\/([^/]+)$/);
    if (recipeMatch) {
      return recipePreviewResponse(request, recipeMatch[1], env);
    }
    return new Response("Not found", { status: 404 });
  }
};
async function saveRecipeShare(request, env) {
  if (!env.RECIPE_SHARES || !env.RECIPE_IMAGES) {
    return jsonResponse({ error: "Missing RECIPE_SHARES or RECIPE_IMAGES binding" }, 500);
  }
  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }
  const id = cleanId(body.id);
  const title = typeof body.title === "string" ? body.title.trim() : "";
  const description = typeof body.description === "string" ? body.description : "Open in Frydge";
  const time = typeof body.time === "string" ? body.time : null;
  const imageBase64 = typeof body.imageBase64 === "string" ? body.imageBase64 : "";
  const imageContentType = body.imageContentType === "image/jpeg" ? "image/jpeg" : null;
  const headerUploadKey = request.headers.get("X-Frydge-Upload-Key") || "";
  const bodyUploadKey = typeof body.uploadKey === "string" ? body.uploadKey : "";
  const uploadKey = headerUploadKey || bodyUploadKey;
  if (uploadKey !== UPLOAD_KEY) {
    return jsonResponse({ error: "Invalid upload key" }, 401);
  }
  if (!id || !title || !imageContentType) {
    return jsonResponse({ error: "Missing id, title, or imageContentType" }, 400);
  }
  const imageURL = imageBase64 ? `${DOMAIN}/images/${encodeURIComponent(id)}.jpg` : DEFAULT_IMAGE_URL;
  const shareURL = `${DOMAIN}/recipe/${encodeURIComponent(id)}`;
  if (imageBase64) {
    await env.RECIPE_IMAGES.put(id, imageBase64, {
      metadata: { contentType: imageContentType }
    });
  }
  const metadata = {
    title,
    time,
    description,
    imageURL,
    updatedAt: (/* @__PURE__ */ new Date()).toISOString()
  };
  await env.RECIPE_SHARES.put(id, JSON.stringify(metadata));
  return jsonResponse({ ok: true, id, recipeId: id, shareURL, imageURL });
}
__name(saveRecipeShare, "saveRecipeShare");
function appleAppSiteAssociation() {
  return {
    applinks: {
      apps: [],
      details: [
        {
          appIDs: [`${TEAM_ID}.${BUNDLE_ID}`],
          components: [
            {
              "/": "/recipe/*",
              comment: "Recipe universal links"
            }
          ]
        }
      ]
    }
  };
}
__name(appleAppSiteAssociation, "appleAppSiteAssociation");
async function recipePreviewResponse(request, recipeId, env) {
  const recipe = await loadRecipeShare(recipeId, env);
  const title = recipe?.title || "Frydge Recipe";
  const description = recipe?.description || [recipe?.time, "Open in Frydge"].filter(Boolean).join(" \xB7 ") || "Open in Frydge";
  const pageURL = `${DOMAIN}/recipe/${encodeURIComponent(recipeId)}`;
  const imageURL = recipe?.imageURL || DEFAULT_IMAGE_URL;
  const appURL = `frydge://recipe/${encodeURIComponent(recipeId)}`;
  if (!shouldServeRichPreview(request)) {
    return appRedirectResponse({ title, description, pageURL, imageURL, appURL });
  }
  const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHTML(title)}</title>
  <meta name="description" content="${escapeHTML(description)}">
  <meta property="og:type" content="article">
  <meta property="og:title" content="${escapeHTML(title)}">
  <meta property="og:description" content="${escapeHTML(description)}">
  <meta property="og:url" content="${escapeHTML(pageURL)}">
  <meta property="og:image" content="${escapeHTML(imageURL)}">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="${escapeHTML(title)}">
  <meta name="twitter:description" content="${escapeHTML(description)}">
  <meta name="twitter:image" content="${escapeHTML(imageURL)}">
</head>
<body>
  <main style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;max-width:680px;margin:48px auto;padding:0 20px;">
    <img src="${escapeHTML(imageURL)}" alt="" style="width:100%;border-radius:12px;">
    <h1>${escapeHTML(title)}</h1>
    <p>${escapeHTML(description)}</p>
    <p><a href="${escapeHTML(appURL)}">Open in Frydge</a></p>
  </main>
</body>
</html>`;
  return new Response(html, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "public, max-age=300"
    }
  });
}
__name(recipePreviewResponse, "recipePreviewResponse");
function appRedirectResponse({ title, description, pageURL, imageURL, appURL }) {
  const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHTML(title)}</title>
  <meta name="description" content="${escapeHTML(description)}">
  <meta property="og:type" content="article">
  <meta property="og:title" content="${escapeHTML(title)}">
  <meta property="og:description" content="${escapeHTML(description)}">
  <meta property="og:url" content="${escapeHTML(pageURL)}">
  <meta property="og:image" content="${escapeHTML(imageURL)}">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta http-equiv="refresh" content="0;url=${escapeHTML(appURL)}">
  <script>
    window.location.replace(${JSON.stringify(appURL)});
  <\/script>
</head>
<body>
  <main style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;max-width:680px;margin:48px auto;padding:0 20px;">
    <img src="${escapeHTML(imageURL)}" alt="" style="width:100%;border-radius:12px;">
    <h1>${escapeHTML(title)}</h1>
    <p>${escapeHTML(description)}</p>
    <p><a href="${escapeHTML(appURL)}">Open in Frydge</a></p>
  </main>
</body>
</html>`;
  return new Response(html, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "public, max-age=60"
    }
  });
}
__name(appRedirectResponse, "appRedirectResponse");
async function recipeImageResponse(imageKey, env) {
  if (!env.RECIPE_IMAGES) {
    return new Response("Missing RECIPE_IMAGES binding", { status: 500 });
  }
  const cleanKey = cleanId(imageKey);
  if (!cleanKey) {
    return new Response("Invalid image key", { status: 400 });
  }
  const imageBase64 = await env.RECIPE_IMAGES.get(cleanKey);
  if (!imageBase64) {
    return defaultRecipeImageResponse();
  }
  const bytes = Uint8Array.from(atob(imageBase64), (char) => char.charCodeAt(0));
  return new Response(bytes, {
    headers: {
      "content-type": "image/jpeg",
      "cache-control": "public, max-age=31536000, immutable"
    }
  });
}
__name(recipeImageResponse, "recipeImageResponse");
function defaultRecipeImageResponse() {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <defs>
    <linearGradient id="bg" x1="0" x2="1" y1="0" y2="1">
      <stop offset="0" stop-color="#f7faf4"/>
      <stop offset="1" stop-color="#dfeeda"/>
    </linearGradient>
  </defs>
  <rect width="1200" height="630" fill="url(#bg)"/>
  <circle cx="250" cy="182" r="86" fill="#9cc78a"/>
  <circle cx="920" cy="448" r="118" fill="#f6b36f"/>
  <rect x="320" y="190" width="560" height="250" rx="38" fill="#ffffff" opacity="0.86"/>
  <text x="600" y="305" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="70" font-weight="700" fill="#243524">Frydge</text>
  <text x="600" y="374" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="34" fill="#536454">Open this recipe in the app</text>
</svg>`;
  return new Response(svg, {
    headers: {
      "content-type": "image/svg+xml; charset=utf-8",
      "cache-control": "public, max-age=31536000, immutable"
    }
  });
}
__name(defaultRecipeImageResponse, "defaultRecipeImageResponse");
async function loadRecipeShare(recipeId, env) {
  if (!env.RECIPE_SHARES) {
    return null;
  }
  const raw = await env.RECIPE_SHARES.get(recipeId);
  if (!raw) {
    return null;
  }
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}
__name(loadRecipeShare, "loadRecipeShare");
function jsonResponse(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "content-type": "application/json",
      "cache-control": "public, max-age=3600",
      ...corsHeaders()
    }
  });
}
__name(jsonResponse, "jsonResponse");
function corsResponse(value, status = 200) {
  return new Response(value, {
    status,
    headers: corsHeaders()
  });
}
__name(corsResponse, "corsResponse");
function corsHeaders() {
  return {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "content-type,x-frydge-upload-key"
  };
}
__name(corsHeaders, "corsHeaders");
function shouldServeRichPreview(request) {
  const userAgent = request.headers.get("user-agent") || "";
  return PREVIEW_USER_AGENT_PATTERN.test(userAgent);
}
__name(shouldServeRichPreview, "shouldServeRichPreview");
function cleanId(value) {
  if (typeof value !== "string") {
    return "";
  }
  return value.trim().replace(/[^a-zA-Z0-9_-]/g, "").slice(0, 160);
}
__name(cleanId, "cleanId");
function escapeHTML(value) {
  return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}
__name(escapeHTML, "escapeHTML");
export {
  cloudflare_worker_recipe_sharing_default as default
};
//# sourceMappingURL=cloudflare-worker-recipe-sharing.js.map
