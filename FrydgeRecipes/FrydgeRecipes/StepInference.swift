//
//  StepInference.swift
//  FrydgeRecipes
//
//  Turns prose instructions into structured RecipeSteps.
//  Run this on: URL import, OCR import, paste, and lazily on legacy recipes.
//

import Foundation

enum StepInference {

    // MARK: - Public API

    /// Split a blob of instructions into structured steps.
    static func steps(fromInstructions blob: String, ingredients: [String]) -> [RecipeStep] {
        splitIntoStepTexts(blob).map { step(from: $0, ingredients: ingredients) }
    }

    /// Enrich existing steps that have text but no structure. Idempotent.
    static func enrich(_ steps: [RecipeStep], ingredients: [String]) -> [RecipeStep] {
        steps.map { s in
            guard s.action == nil else { return s }
            var inferred = step(from: s.text, ingredients: ingredients)
            // Preserve anything the author already set.
            inferred.id = s.id
            inferred.text = s.text
            inferred.timerSeconds = s.timerSeconds ?? inferred.timerSeconds
            inferred.temperatureValue = s.temperatureValue ?? inferred.temperatureValue
            inferred.temperatureUnit = s.temperatureUnit ?? inferred.temperatureUnit
            inferred.mediaURLString = s.mediaURLString
            return inferred
        }
    }

    /// Single line -> structured step.
    static func step(from rawLine: String, ingredients: [String]) -> RecipeStep {
        let line = clean(rawLine)
        let lower = line.lowercased()

        let action = detectAction(in: lower)
        let refs = detectIngredients(in: lower, from: ingredients)
        let seconds = detectDuration(in: lower)
        let (temp, unit) = detectTemperature(in: line)
        let heat = detectHeat(in: lower)
        let vessel = detectVessel(in: lower) ?? action?.defaultVessel

        return RecipeStep(
            text: line,                       // keep original as the override
            timerSeconds: seconds,
            temperatureValue: temp,
            temperatureUnit: unit,
            action: action,
            ingredientRefs: refs,
            vessel: vessel,
            heat: heat ?? ((action?.usesHeat ?? false) ? .medium : nil)
        )
    }

    // MARK: - Splitting

    static func splitIntoStepTexts(_ blob: String) -> [String] {
        let normalized = blob.replacingOccurrences(of: "\r\n", with: "\n")

        // Prefer explicit line breaks if they look like steps.
        let lines = normalized
            .split(separator: "\n")
            .map { clean(String($0)) }
            .filter { $0.count > 3 }

        if lines.count > 1 { return lines }

        // Otherwise split on sentence boundaries, gluing short fragments back on.
        var out: [String] = []
        var buffer = ""
        for sentence in normalized.split(whereSeparator: { $0 == "." || $0 == ";" }) {
            let s = clean(String(sentence))
            guard !s.isEmpty else { continue }
            if s.count < 25, !buffer.isEmpty {
                buffer += ". " + s
            } else {
                if !buffer.isEmpty { out.append(buffer) }
                buffer = s
            }
        }
        if !buffer.isEmpty { out.append(buffer) }
        return out
    }

    private static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading "1.", "1)", "Step 1:", "-", "•"
        let patterns = [
            #"^\s*step\s*\d+\s*[:.\)-]?\s*"#,
            #"^\s*\d+\s*[:.\)]\s*"#,
            #"^\s*[-•*]\s*"#
        ]
        for p in patterns {
            t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return t
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Action detection

    /// Synonyms -> canonical action. First match in the sentence wins,
    /// so "heat the pan then add the onion" resolves to `.warm`, not `.add`.
    private static let verbMap: [(keys: [String], action: CookAction)] = [
        (["preheat", "heat the oven"],                       .bake),
        (["chop", "roughly chop", "finely chop"],            .chop),
        (["slice", "cut into slices"],                       .slice),
        (["dice", "cube"],                                   .dice),
        (["mince", "finely dice"],                           .mince),
        (["grate", "shred"],                                 .grate),
        (["peel"],                                           .peel),
        (["crush", "smash", "bash"],                         .crush),
        (["trim"],                                           .trim),
        (["whisk", "beat"],                                  .whisk),
        (["fold in", "fold through", "fold"],                .fold),
        (["knead"],                                          .knead),
        (["blend", "blitz", "purée", "puree", "process"],    .blend),
        (["toss"],                                           .toss),
        (["coat", "dredge", "dust with flour"],              .coat),
        (["stir"],                                           .stir),
        (["mix", "combine", "stir together"],                .mix),
        (["sauté", "saute", "sweat", "soften"],              .saute),
        (["sear", "brown"],                                  .sear),
        (["fry", "pan-fry", "shallow fry", "deep fry"],      .fry),
        (["grill", "barbecue", "bbq", "broil", "char"],      .grill),
        (["bring to the boil", "bring to a boil", "boil"],   .boil),
        (["simmer"],                                         .simmer),
        (["steam"],                                          .steam),
        (["reduce", "cook down"],                            .reduce),
        (["bake"],                                           .bake),
        (["roast"],                                          .roast),
        (["flip", "turn over", "turn the"],                  .flip),
        (["warm", "heat"],                                   .warm),
        (["chill", "refrigerate"],                           .chill),
        (["freeze"],                                         .freeze),
        (["marinate", "marinade"],                           .marinate),
        (["rest", "set aside", "leave to stand", "cool"],    .rest),
        (["prove", "proof", "let it rise"],                  .proof),
        (["thaw", "defrost"],                                .thaw),
        (["season", "salt and pepper", "add salt"],          .season),
        (["garnish", "top with", "sprinkle", "scatter"],     .garnish),
        (["drain", "strain"],                                .drain),
        (["pour"],                                           .pour),
        (["serve"],                                          .serve),
        (["plate up", "plate"],                              .plate),
        (["add", "tip in", "stir in", "put in"],             .add)
    ]

    static func detectAction(in lower: String) -> CookAction? {
        var best: (index: Int, action: CookAction)?
        for entry in verbMap {
            for key in entry.keys {
                guard let r = lower.range(of: key) else { continue }
                let idx = lower.distance(from: lower.startIndex, to: r.lowerBound)
                if best == nil || idx < best!.index {
                    best = (idx, entry.action)
                }
            }
        }
        return best?.action
    }

    // MARK: - Ingredient detection

    static func detectIngredients(in lower: String, from ingredients: [String]) -> [String] {
        var found: [String] = []
        for raw in ingredients {
            let core = coreNoun(of: raw)
            guard core.count >= 3 else { continue }
            if lower.contains(core) || lower.contains(singularOrPlural(core)) {
                if !found.contains(core) { found.append(core) }
            }
        }
        return Array(found.prefix(4))
    }

    /// "200g plain flour, sifted" -> "plain flour"
    static func coreNoun(of raw: String) -> String {
        var s = raw.lowercased()

        // Drop anything after a comma ("finely chopped", "to serve")
        if let c = s.firstIndex(of: ",") { s = String(s[s.startIndex..<c]) }

        // Drop leading quantity + unit
        s = s.replacingOccurrences(
            of: #"^\s*[\d¼½¾⅓⅔/.\s-]+\s*(g|kg|ml|l|litre|liter|oz|lb|tsp|tbsp|cup|cups|clove|cloves|pinch|handful|can|cans|tin|tins|slice|slices|piece|pieces|sprig|sprigs|bunch|x)?\b"#,
            with: "",
            options: [.regularExpression]
        )

        // Drop trailing prep words
        let noise = ["freshly", "finely", "roughly", "chopped", "sliced", "diced", "minced",
                     "grated", "peeled", "crushed", "of", "large", "small", "medium", "ripe"]
        var words = s.split(separator: " ").map(String.init)
        words.removeAll { noise.contains($0) }

        return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func singularOrPlural(_ s: String) -> String {
        s.hasSuffix("s") ? String(s.dropLast()) : s + "s"
    }

    // MARK: - Duration

    static func detectDuration(in lower: String) -> Int? {
        // "for 20-25 minutes" -> takes the upper bound. "1 hour 30 mins" -> sums.
        let pattern = #"(\d+)\s*(?:-|–|to)?\s*(\d+)?\s*(hour|hours|hr|hrs|minute|minutes|min|mins|second|seconds|sec|secs)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }

        let ns = lower as NSString
        let matches = re.matches(in: lower, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        var total = 0
        for m in matches {
            let lowVal = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let highVal: Int? = m.range(at: 2).location != NSNotFound
                ? Int(ns.substring(with: m.range(at: 2)))
                : nil
            let value = highVal ?? lowVal
            let unit = ns.substring(with: m.range(at: 3)).lowercased()

            if unit.hasPrefix("h")      { total += value * 3600 }
            else if unit.hasPrefix("m") { total += value * 60 }
            else                        { total += value }
        }
        return total > 0 ? total : nil
    }

    // MARK: - Temperature

    static func detectTemperature(in line: String) -> (Int?, String?) {
        let pattern = #"(\d{2,3})\s*(?:°|deg(?:rees)?\s*)?\s*([CF])\b"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return (nil, nil) }
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return (nil, nil) }
        let value = Int(ns.substring(with: m.range(at: 1)))
        let unit = ns.substring(with: m.range(at: 2)).uppercased()
        return (value, "°\(unit)")
    }

    // MARK: - Heat & vessel

    static func detectHeat(in lower: String) -> HeatLevel? {
        if lower.contains("high heat") || lower.contains("hot pan") { return .high }
        if lower.contains("low heat") || lower.contains("gentle")   { return .low }
        if lower.contains("medium")                                  { return .medium }
        return nil
    }

    static func detectVessel(in lower: String) -> Vessel? {
        let map: [(String, Vessel)] = [
            ("chopping board", .board), ("board", .board),
            ("frying pan", .pan), ("skillet", .pan), ("wok", .pan), ("pan", .pan),
            ("saucepan", .pot), ("pot", .pot), ("casserole", .pot),
            ("baking tray", .tray), ("sheet", .tray), ("tin", .tray), ("dish", .tray),
            ("oven", .oven),
            ("blender", .blender), ("food processor", .blender),
            ("fridge", .fridge), ("refrigerator", .fridge),
            ("freezer", .freezer),
            ("bowl", .bowl),
            ("grill", .grill), ("barbecue", .grill),
            ("plate", .plate), ("serving", .plate)
        ]
        for (key, v) in map where lower.contains(key) { return v }
        return nil
    }
}

extension CloudRecipe {
    /// Structured steps for the detail page and cook mode. Older recipes (and
    /// some imports) only carry prose `instructions` with no saved steps, so
    /// infer steps from that text instead of showing nothing.
    var resolvedSteps: [RecipeStep] {
        if !steps.isEmpty { return steps }
        let prose = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prose.isEmpty else { return [] }
        return StepInference.steps(fromInstructions: prose, ingredients: ingredients)
    }
}
