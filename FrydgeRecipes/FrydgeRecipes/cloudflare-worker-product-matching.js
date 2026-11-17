/**
 * Cloudflare Worker - Product Matching Enhancement
 * 
 * Add these functions to your existing worker to mirror the Swift implementation.
 * This enables server-side filtering and ranking before sending results to clients.
 */

/**
 * Scores a product against a query and size hint.
 * @param {string} productTitle - The product title from the retailer
 * @param {string} query - The cleaned search query
 * @param {string|null} sizeHint - Optional size hint (e.g., "2l", "500g")
 * @returns {{score: number, hasExactSizeMatch: boolean}}
 */
function scoreProduct(productTitle, query, sizeHint) {
  const normalizedTitle = productTitle.toLowerCase();
  const normalizedQuery = query.toLowerCase();
  
  // 1. Token overlap (65% weight)
  const tokenScore = calculateTokenOverlap(normalizedTitle, normalizedQuery);
  
  // 2. Size match (35% weight)
  const { score: sizeScore, exactMatch } = calculateSizeMatch(normalizedTitle, sizeHint);
  
  // 3. Weighted combination
  let finalScore = (tokenScore * 0.65) + (sizeScore * 0.35);
  
  // 4. Store-brand penalty (×0.9 for budget brands)
  if (isStoreBrand(productTitle)) {
    finalScore *= 0.9;
  }
  
  return {
    score: Math.max(0, Math.min(1, finalScore)),
    hasExactSizeMatch: exactMatch
  };
}

/**
 * Filters and ranks stores based on product matching scores.
 * @param {Array} stores - Array of store objects with product information
 * @param {string} query - The cleaned search query
 * @param {string|null} sizeHint - Optional size hint
 * @returns {Array} Filtered and ranked stores (top 5)
 */
function filterAndRankStores(stores, query, sizeHint) {
  const threshold = 0.45;
  
  // Score all stores
  const scoredStores = stores
    .map(store => {
      const title = store.productTitle || store.name || '';
      if (!title.trim()) return null;
      
      const scoreData = scoreProduct(title, query, sizeHint);
      return {
        ...store,
        _score: scoreData.score,
        _hasExactSize: scoreData.hasExactSizeMatch
      };
    })
    .filter(store => store && store._score >= threshold);
  
  // Sort by exact size match, then score, then price
  scoredStores.sort((a, b) => {
    // Exact size matches first
    if (a._hasExactSize !== b._hasExactSize) {
      return b._hasExactSize - a._hasExactSize;
    }
    
    // Then by score
    if (Math.abs(a._score - b._score) > 0.01) {
      return b._score - a._score;
    }
    
    // Then by price
    const priceA = a.price || a.salePrice || a.regularPrice || Infinity;
    const priceB = b.price || b.salePrice || b.regularPrice || Infinity;
    return priceA - priceB;
  });
  
  // Return top 5, removing internal _score fields
  return scoredStores.slice(0, 5).map(store => {
    const { _score, _hasExactSize, ...cleanStore } = store;
    return cleanStore;
  });
}

// Helper functions

function calculateTokenOverlap(title, query) {
  const titleTokens = new Set(tokenize(title));
  const queryTokens = tokenize(query);
  
  if (queryTokens.length === 0) return 0;
  
  const matches = queryTokens.filter(token => titleTokens.has(token));
  return matches.length / queryTokens.length;
}

function tokenize(text) {
  return text.toLowerCase()
    .split(/\s+/)
    .map(t => t.replace(/[^\w]/g, ''))
    .filter(t => t.length > 0);
}

function calculateSizeMatch(title, sizeHint) {
  if (!sizeHint) {
    return { score: 0.5, exactMatch: false }; // Neutral when no hint
  }
  
  const sizePattern = /(\d+(?:\.\d+)?)\s*(kg|g|l|ml|lb|oz|fl\s?oz)\b/i;
  const titleMatch = title.match(sizePattern);
  
  if (!titleMatch) {
    return { score: 0.5, exactMatch: false }; // No size in title
  }
  
  const titleSize = (titleMatch[1] + titleMatch[2]).toLowerCase().replace(/\s/g, '');
  const normalizedHint = sizeHint.toLowerCase().replace(/\s/g, '');
  
  // Exact match
  if (titleSize === normalizedHint) {
    return { score: 1.0, exactMatch: true };
  }
  
  // Parse and compare
  const titleValue = parseFloat(titleMatch[1]);
  const titleUnit = titleMatch[2].toLowerCase().replace(/\s/g, '');
  
  const hintMatch = sizeHint.match(/(\d+(?:\.\d+)?)\s*(kg|g|l|ml|lb|oz)/i);
  if (!hintMatch) {
    return { score: 0.3, exactMatch: false };
  }
  
  const hintValue = parseFloat(hintMatch[1]);
  const hintUnit = hintMatch[2].toLowerCase().replace(/\s/g, '');
  
  // Same unit - calculate ratio
  if (titleUnit === hintUnit) {
    const ratio = Math.min(titleValue, hintValue) / Math.max(titleValue, hintValue);
    return { score: ratio, exactMatch: false };
  }
  
  // Convert and compare if same category
  if (areSameCategory(titleUnit, hintUnit)) {
    const normalizedTitle = normalizeToBase(titleValue, titleUnit);
    const normalizedHint = normalizeToBase(hintValue, hintUnit);
    const ratio = Math.min(normalizedTitle, normalizedHint) / Math.max(normalizedTitle, normalizedHint);
    return { score: ratio, exactMatch: false };
  }
  
  return { score: 0.3, exactMatch: false };
}

function areSameCategory(unit1, unit2) {
  const weightUnits = ['kg', 'g', 'lb', 'oz'];
  const volumeUnits = ['l', 'ml', 'floz'];
  
  return (weightUnits.includes(unit1) && weightUnits.includes(unit2)) ||
         (volumeUnits.includes(unit1) && volumeUnits.includes(unit2));
}

function normalizeToBase(value, unit) {
  const conversions = {
    'kg': 1000,    // to grams
    'g': 1,
    'lb': 453.592,
    'oz': 28.3495,
    'l': 1000,     // to ml
    'ml': 1,
    'floz': 29.5735
  };
  
  return value * (conversions[unit] || 1);
}

function isStoreBrand(productTitle) {
  const storeBrands = [
    'pams', "pam's", 'homebrand', 'home brand',
    'countdown brand', 'countdown', 'value',
    'woolworths essentials', 'woolworths', 'essentials',
    'budget', 'signature range', 'select'
  ];
  
  const lower = productTitle.toLowerCase();
  return storeBrands.some(brand => lower.includes(brand));
}

/**
 * Example integration into your existing worker's search endpoint:
 * 
 * async function handleSearch(request) {
 *   const url = new URL(request.url);
 *   const rawQuery = url.searchParams.get('q') || '';
 *   const lat = url.searchParams.get('lat');
 *   const lon = url.searchParams.get('lon');
 *   
 *   // Your existing search logic...
 *   let stores = await fetchFromRetailers(rawQuery, lat, lon);
 *   
 *   // NEW: Clean query and filter/rank
 *   const { query: cleanQuery, sizeHint } = buildCleanQuery(rawQuery);
 *   stores = filterAndRankStores(stores, cleanQuery, sizeHint);
 *   
 *   return new Response(JSON.stringify({ stores }), {
 *     headers: { 'Content-Type': 'application/json' }
 *   });
 * }
 * 
 * function buildCleanQuery(rawQuery) {
 *   // Simplified version - implement full query cleaning like Swift version
 *   const sizeMatch = rawQuery.match(/(\d+(?:\.\d+)?)\s*(kg|g|l|ml|lb|oz)\b/i);
 *   const sizeHint = sizeMatch ? sizeMatch[0].replace(/\s/g, '').toLowerCase() : null;
 *   
 *   let query = rawQuery;
 *   if (sizeHint) {
 *     query = query.replace(sizeMatch[0], '').trim();
 *   }
 *   
 *   return { query, sizeHint };
 * }
 */

module.exports = {
  scoreProduct,
  filterAndRankStores
};
