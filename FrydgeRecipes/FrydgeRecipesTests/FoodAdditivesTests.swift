//
//  FoodAdditivesTests.swift
//  FrydgeRecipes Tests
//
//  Additive recognition in ingredient lists (FoodAdditives.swift) and the
//  environmental rating model / typical-impact estimate
//  (EnvironmentalImpact.swift).
//

import Testing
import Foundation
@testable import FrydgeRecipes

@Suite("Additive recognition")
struct FoodAdditivesTests {

    @Test("NZ/AU bare code numbers in brackets are recognised")
    func bareCodes() {
        let text = "Water, sugar, thickener (1442), vegetable gum (412), colour (150d), acidity regulator (330)"
        let codes = FoodAdditives.detect(in: text).map(\.code)
        #expect(codes == ["1442", "412", "150d", "330"])
    }

    @Test("E-numbers and INS numbers resolve to the same rows")
    func prefixedCodes() {
        let eu = FoodAdditives.detect(in: "Emulsifier: E322, E471; preservative E-250").map(\.code)
        let ins = FoodAdditives.detect(in: "emulsifiers (INS 322, INS 471), preservative (ins 250)").map(\.code)
        #expect(eu == ["322", "471", "250"])
        #expect(ins == eu)
    }

    @Test("Comma-separated codes in one bracket are all found")
    func listedCodes() {
        let codes = FoodAdditives.detect(in: "Emulsifiers (322, 471, 472e), raising agents (500, 450)").map(\.code)
        #expect(codes == ["322", "471", "472e", "500", "450"])
    }

    @Test("Quantities and percentages are never mistaken for codes")
    func quantitiesIgnored() {
        let text = "Net 500g. 100% natural. 12 x 330ml. Contains 250 mg caffeine per 100 g. Best before 2027."
        #expect(FoodAdditives.detect(in: text).isEmpty)
    }

    @Test("Unknown bare numbers are dropped; unknown E-numbers are surfaced")
    func unknownCodes() {
        #expect(FoodAdditives.detect(in: "batch 8734, line 1999").isEmpty)
        let flagged = FoodAdditives.detect(in: "colour (E199)")
        #expect(flagged.count == 1)
        #expect(flagged.first?.code == "199")
        #expect(flagged.first?.name.contains("199") == true)
    }

    @Test("Written names are recognised and not double-counted with their code")
    func writtenNames() {
        let text = "Guar gum, xanthan gum (415), sodium nitrite, monosodium glutamate, soy lecithin"
        let codes = FoodAdditives.detect(in: text).map(\.code)
        #expect(codes == ["412", "415", "250", "621", "322"])
    }

    @Test("A long alias does not also fire its shorter components")
    func aliasMasking() {
        let codes = FoodAdditives.detect(in: "citric acid esters of mono- and diglycerides").map(\.code)
        #expect(codes == ["472c"])
        let codes2 = FoodAdditives.detect(in: "sodium aluminium phosphate").map(\.code)
        #expect(codes2 == ["541"])
    }

    @Test("Names embedded in other words do not match")
    func wordBoundaries() {
        // "hydrogenated" contains "hydrogen" (941); "methylcellulose" contains "cellulose" (460).
        let codes = FoodAdditives.detect(in: "hydrogenated vegetable oil, methylcellulose").map(\.code)
        #expect(codes == ["461"])
    }

    @Test("Open Food Facts tags merge with text detections without duplicates")
    func tagsMerge() {
        let merged = FoodAdditives.merged(text: "thickener (412)", tags: ["en:e412", "en:e150d", "en:e450i"])
        #expect(merged.map(\.code) == ["412", "150d", "450"])
    }

    @Test("Catalogue rows carry a concern level and a note")
    func catalogueContent() {
        let nitrite = FoodAdditives.additive(for: "250")
        #expect(nitrite?.name == "Sodium nitrite")
        #expect(nitrite?.concern == .high)
        #expect(nitrite?.note.isEmpty == false)

        let guar = FoodAdditives.additive(named: "Guar gum")
        #expect(guar?.code == "412")
        #expect(guar?.concern == FoodAdditive.Concern.none)

        let tin = FoodAdditives.additive(for: "512")
        #expect(tin?.name == "Stannous chloride")
    }

    @Test("Concern levels order so the worst in a list can be found")
    func concernOrdering() {
        let additives = FoodAdditives.detect(in: "412, 211, 171")
        #expect(additives.map(\.concern).max() == .high)
        #expect(FoodAdditive.Concern.none < .low)
        #expect(FoodAdditive.Concern.moderate < .high)
    }

    @Test("Empty or nil text yields nothing")
    func emptyInput() {
        #expect(FoodAdditives.detect(in: nil).isEmpty)
        #expect(FoodAdditives.detect(in: "   ").isEmpty)
        #expect(FoodAdditives.detect(tags: nil).isEmpty)
    }
}

@Suite("Environmental impact")
struct EnvironmentalImpactTests {

    @Test("Carbon footprint maps to the Eco-Score letter scale")
    func gradeThresholds() {
        #expect(EnvironmentalImpact.grade(forCO2PerKg: 0.4) == "a")
        #expect(EnvironmentalImpact.grade(forCO2PerKg: 1.3) == "b")
        #expect(EnvironmentalImpact.grade(forCO2PerKg: 4.8) == "c")
        #expect(EnvironmentalImpact.grade(forCO2PerKg: 8.5) == "d")
        #expect(EnvironmentalImpact.grade(forCO2PerKg: 33) == "e")
    }

    @Test("Unknown or not-applicable grades produce no rating")
    func invalidGrades() {
        #expect(EnvironmentalImpact(grade: nil, source: .ecoScore) == nil)
        #expect(EnvironmentalImpact(grade: "unknown", source: .ecoScore) == nil)
        #expect(EnvironmentalImpact(grade: "not-applicable", source: .greenScore) == nil)
        #expect(EnvironmentalImpact(grade: "B", source: .ecoScore)?.grade == "b")
    }

    @Test("Everyday foods get a typical estimate, ranked sensibly")
    func typicalEstimates() {
        let beef = GenericEnvironmentalImpact.impact(for: "Beef mince 500g")
        let chicken = GenericEnvironmentalImpact.impact(for: "Chicken breast")
        let lentils = GenericEnvironmentalImpact.impact(for: "Red lentils 1kg")
        #expect(beef?.grade == "e")
        #expect(chicken?.grade == "c")
        #expect(lentils?.grade == "a")
        #expect(beef?.source.isEstimate == true)
        #expect((beef?.co2PerKg ?? 0) > (chicken?.co2PerKg ?? 0))
        #expect((chicken?.co2PerKg ?? 0) > (lentils?.co2PerKg ?? 0))
    }

    @Test("Specific foods fall back to their family")
    func familyFallback() {
        #expect(GenericEnvironmentalImpact.entry(for: "Gouda") != nil)
        #expect(GenericEnvironmentalImpact.entry(for: "Kahawai") != nil)
    }

    @Test("Non-food names return nothing rather than guessing")
    func unknownIsNil() {
        #expect(GenericEnvironmentalImpact.impact(for: "Dishwasher tablets") == nil)
        #expect(GenericEnvironmentalImpact.impact(for: "") == nil)
    }

    @Test("Labels read naturally")
    func labels() {
        let env = EnvironmentalImpact(grade: "d", co2PerKg: 8.5, source: .estimated(basis: "typical butter"))
        #expect(env?.impactLabel == "High impact")
        #expect(env?.co2Label == "8.5 kg CO₂e / kg")
        #expect(env?.source.label == "Estimated")
        let big = EnvironmentalImpact(grade: "e", co2PerKg: 33, source: .greenScore)
        #expect(big?.co2Label == "33 kg CO₂e / kg")
    }

    @Test("Facts built from a Worker product carry its Eco-Score and additives")
    func factsIntegration() {
        var facts = ProductNutritionFacts()
        facts.ingredientsText = "Pork, salt, preservative (250), antioxidant (316)"
        facts.additiveTags = ["en:e250", "en:e301"]
        #expect(facts.additives.map(\.code) == ["250", "316", "301"])
        #expect(facts.hasRatings == false)
        facts.environmental = EnvironmentalImpact(grade: "c", source: .ecoScore)
        #expect(facts.hasRatings == true)
        #expect(facts.hasFoodQuality == false)
    }
}
