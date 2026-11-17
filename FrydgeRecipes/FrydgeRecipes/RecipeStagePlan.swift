//
//  RecipeStagePlan.swift
//  FrydgeRecipes
//
//  Which ingredient goes in at which step ("stage") of a recipe.
//
//  Each ingredient line on the recipe (with its saved quantity, e.g.
//  "Butter 250g") is assigned to the first step that references it, either
//  through the step's explicit `ingredientRefs` (set by the step builder) or,
//  for the many imported/default recipes without tags, by matching the
//  ingredient's core noun against the step's wording. Lines no step mentions
//  land in `unassigned` ("Also needed") so nothing silently disappears.
//
//  Consumers: the recipe detail page (stage badges on the overall list and
//  per-step ingredient chips), Cook Mode and Cook-Along (what to add on each
//  page, next to that page's timer).
//

import Foundation

struct RecipeStagePlan: Equatable {

    struct Stage: Identifiable, Equatable {
        /// Same as the step's id, so views keyed on steps can look stages up.
        let id: UUID
        /// 1-based position shown to the cook.
        let number: Int
        let step: RecipeStep
        /// Ingredient lines, as saved on the recipe, that are first added here.
        let ingredientLines: [String]
    }

    let stages: [Stage]
    /// Ingredient lines that no step references.
    let unassigned: [String]
    private let stageNumberByLine: [String: Int]

    static let empty = RecipeStagePlan(stages: [], unassigned: [], stageNumberByLine: [:])

    /// Stage number the line is first added at, or nil for "Also needed".
    func stageNumber(for line: String) -> Int? {
        stageNumberByLine[line.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func stage(forStepID id: UUID) -> Stage? {
        stages.first { $0.id == id }
    }

    func ingredientLines(forStepID id: UUID) -> [String] {
        stage(forStepID: id)?.ingredientLines ?? []
    }

    var hasAnyAssignments: Bool {
        stages.contains { !$0.ingredientLines.isEmpty }
    }

    // MARK: - Building

    static func build(ingredients: [String], steps: [RecipeStep]) -> RecipeStagePlan {
        let lines = ingredients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty, !steps.isEmpty else {
            return RecipeStagePlan(stages: steps.enumerated().map {
                Stage(id: $1.id, number: $0 + 1, step: $1, ingredientLines: [])
            }, unassigned: lines, stageNumberByLine: [:])
        }

        let infos = lines.map(LineInfo.init)
        var assigned = Set<Int>()
        var byLine: [String: Int] = [:]
        var stages: [Stage] = []
        stages.reserveCapacity(steps.count)

        for (index, step) in steps.enumerated() {
            let lower = step.displayText.lowercased()
            var hits: [Int] = []
            // A recipe can list the same ingredient twice ("Sugar 100g" for
            // the base, "Sugar 50g" for the top). One mention in a step
            // claims one line, so the second line stays free for a later step.
            var coresClaimedThisStep = Set<String>()
            for (i, info) in infos.enumerated() where !assigned.contains(i) {
                guard !coresClaimedThisStep.contains(info.core) else { continue }
                if references(step: step, lowercasedText: lower, info: info) {
                    hits.append(i)
                    coresClaimedThisStep.insert(info.core)
                }
            }
            for i in hits {
                assigned.insert(i)
                if byLine[infos[i].line] == nil { byLine[infos[i].line] = index + 1 }
            }
            stages.append(Stage(id: step.id, number: index + 1, step: step, ingredientLines: hits.map { infos[$0].line }))
        }

        let unassigned = infos.indices.filter { !assigned.contains($0) }.map { infos[$0].line }
        return RecipeStagePlan(stages: stages, unassigned: unassigned, stageNumberByLine: byLine)
    }

    // MARK: - Matching

    private struct LineInfo {
        let line: String
        /// "200g plain flour, sifted" / "Plain flour 200g" → "plain flour"
        let core: String
        let tokens: Set<String>
        /// Distinct words of the core noun worth matching on their own
        /// ("caster sugar" → ["caster", "sugar"]); short words are dropped
        /// because "oil" or "egg" inside other words would over-match.
        let words: [String]

        init(line: String) {
            self.line = line
            // The line parser handles both "200g flour" and "Flour 200g";
            // coreNoun then strips prep words ("finely chopped", "of").
            let parsedName = RecipeIngredientParser.parse(line).name
            let core = StepInference.coreNoun(of: parsedName.isEmpty ? line : parsedName)
            self.core = core
            self.tokens = IngredientMatcher.recipeLineTokens(line)
            self.words = core.split(separator: " ").map(String.init).filter { $0.count >= 4 }
        }
    }

    /// Words in the step text, lower-cased and with a trailing "s" folded so
    /// "eggs" meets "egg" and "carrot" meets "carrots".
    private static func wordSet(_ lower: String) -> Set<String> {
        var out = Set<String>()
        for raw in lower.split(whereSeparator: { !$0.isLetter }) {
            let w = String(raw)
            out.insert(w)
            if w.hasSuffix("s"), w.count > 3 { out.insert(String(w.dropLast())) }
        }
        return out
    }

    private static func references(step: RecipeStep, lowercasedText lower: String, info: LineInfo) -> Bool {
        // 1. Explicit tags from the step builder win outright.
        for ref in step.ingredientRefs {
            let r = ref.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard r.count >= 2 else { continue }
            if r == info.core { return true }
            if info.core.count >= 3, (r.contains(info.core) || info.core.contains(r)) { return true }
            if IngredientMatcher.tokensMatch(IngredientMatcher.tokens(r), info.tokens) { return true }
        }

        // 2. Otherwise look for the ingredient in the step's wording.
        guard info.core.count >= 3 else { return false }
        if lower.contains(info.core) { return true }
        let alternate = info.core.hasSuffix("s") ? String(info.core.dropLast()) : info.core + "s"
        if lower.contains(alternate) { return true }

        // 3. Any distinctive word of the ingredient appearing as a whole word
        //    ("stir in the sugar" → "caster sugar", "the eggs" → "Eggs 3").
        let textWords = wordSet(lower)
        for word in info.words {
            let folded = word.hasSuffix("s") && word.count > 3 ? String(word.dropLast()) : word
            if textWords.contains(word) || textWords.contains(folded) { return true }
        }
        // Short cores like "egg" / "oil": whole-word only.
        if info.words.isEmpty, textWords.contains(info.core) || textWords.contains(alternate) { return true }
        return false
    }
}
