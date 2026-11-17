#!/usr/bin/env python3
import argparse
import html
import json
import re
import sys
import time
from pathlib import Path
from urllib.parse import urlencode
from urllib.error import HTTPError
from urllib.request import Request, urlopen


API_URL = "https://commons.wikimedia.org/w/api.php"
USER_AGENT = "FrydgeRecipes image metadata filler/1.0"

ACCEPTED = {
    "cc0": "CC0",
    "public domain": "Public domain",
    "pd": "Public domain",
    "cc by": "CC BY",
    "cc-by": "CC BY",
    "cc by-sa": "CC BY-SA",
    "cc-by-sa": "CC BY-SA",
}


def clean_text(value):
    if not value:
        return None
    value = html.unescape(str(value))
    value = re.sub(r"<[^>]+>", "", value)
    value = re.sub(r"\s+", " ", value).strip()
    return value or None


def metadata_value(extmetadata, key):
    value = extmetadata.get(key, {})
    return clean_text(value.get("value"))


def accepted_license(short_name):
    if not short_name:
        return None
    normalized = short_name.lower().replace("_", " ").strip()
    for key, label in ACCEPTED.items():
        if normalized == key or normalized.startswith(key + " "):
            return short_name if short_name else label
    return None


def commons_query(params, retries=4):
    query = urlencode({**params, "format": "json", "formatversion": "2"})
    request = Request(f"{API_URL}?{query}", headers={"User-Agent": USER_AGENT})
    for attempt in range(retries):
        try:
            with urlopen(request, timeout=20) as response:
                return json.loads(response.read().decode("utf-8"))
        except HTTPError as error:
            if error.code != 429 or attempt == retries - 1:
                raise
            retry_after = error.headers.get("Retry-After")
            delay = float(retry_after) if retry_after and retry_after.isdigit() else 8.0 * (attempt + 1)
            print(f"Commons rate limited the request; waiting {delay:.0f}s before retrying.", file=sys.stderr)
            time.sleep(delay)


def search_recipe(recipe_name, limit):
    search_terms = [
        f'{recipe_name} food',
        f'{recipe_name} dish',
        recipe_name,
    ]

    for term in search_terms:
        result = commons_query({
            "action": "query",
            "generator": "search",
            "gsrsearch": term,
            "gsrnamespace": "6",
            "gsrlimit": str(limit),
            "prop": "imageinfo",
            "iiprop": "url|mime|extmetadata",
        })

        pages = result.get("query", {}).get("pages", [])
        for page in pages:
            infos = page.get("imageinfo") or []
            if not infos:
                continue

            info = infos[0]
            mime = info.get("mime") or ""
            if not mime.startswith("image/"):
                continue

            ext = info.get("extmetadata") or {}
            license_name = accepted_license(metadata_value(ext, "LicenseShortName"))
            if not license_name:
                continue

            image_url = info.get("url")
            if not image_url:
                continue

            source_page_url = info.get("descriptionurl") or metadata_value(ext, "ImageDescription")
            author = metadata_value(ext, "Artist") or metadata_value(ext, "Credit")

            return {
                "imageSourceURL": image_url,
                "imageCredit": {
                    "imageURL": image_url,
                    "sourcePageURL": source_page_url,
                    "license": license_name,
                    "licenseURL": metadata_value(ext, "LicenseUrl"),
                    "author": author,
                },
            }

        time.sleep(0.1)

    return None


def main():
    parser = argparse.ArgumentParser(description="Fill DefaultRecipes.json imageSourceURL and imageCredit from Wikimedia Commons.")
    parser.add_argument("json_path", help="Path to DefaultRecipes.json")
    parser.add_argument("--overwrite", action="store_true", help="Refresh recipes that already have imageSourceURL")
    parser.add_argument("--limit", type=int, default=8, help="Commons search results to inspect per search")
    parser.add_argument("--delay", type=float, default=1.25, help="Delay between recipe lookups to avoid Commons rate limits")
    args = parser.parse_args()

    path = Path(args.json_path)
    recipes = json.loads(path.read_text(encoding="utf-8"))

    filled = 0
    skipped = 0
    missed = 0

    for index, recipe in enumerate(recipes, start=1):
        name = recipe.get("name", "").strip()
        if not name:
            missed += 1
            continue

        if recipe.get("imageSourceURL") and not args.overwrite:
            skipped += 1
            continue

        try:
            match = search_recipe(name, args.limit)
        except Exception as error:
            print(f"[{index}/{len(recipes)}] {name}: error: {error}", file=sys.stderr)
            missed += 1
            continue

        if match:
            recipe["imageSourceURL"] = match["imageSourceURL"]
            recipe["imageCredit"] = match["imageCredit"]
            filled += 1
            print(f"[{index}/{len(recipes)}] {name}: image found")
        else:
            recipe.setdefault("imageSourceURL", None)
            recipe.setdefault("imageCredit", None)
            missed += 1
            print(f"[{index}/{len(recipes)}] {name}: no acceptable image")

        path.write_text(json.dumps(recipes, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        time.sleep(args.delay)

    path.write_text(json.dumps(recipes, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Done. filled={filled} skipped={skipped} missed={missed}")


if __name__ == "__main__":
    main()
