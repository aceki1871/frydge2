//
//  FoodAdditives.swift
//  FrydgeRecipes
//
//  Recognises food additives in an ingredients list so a scanned product can
//  be checked at a glance. NZ/AU labels print bare code numbers
//  ("thickener (1442)", "vegetable gum (412)", "colour (150d)"); EU labels
//  use E-numbers ("E412"); Codex uses INS numbers ("INS 412"). All three
//  forms are the same code and resolve to the same catalogue row, as do the
//  common written names ("guar gum", "MSG", "sodium nitrite").
//
//  Concern levels are deliberately coarse and lean on regulator positions
//  (EFSA re-evaluations, FSANZ, IARC classifications) rather than headlines.
//  They are a prompt to read further, not a medical verdict.
//

import Foundation

// MARK: - Model

struct FoodAdditive: Identifiable, Hashable, Sendable {

    /// Coarse "how much should I care" scale used for the colour of the code
    /// pill. Ordered so the worst additive in a list can be found with `max`.
    enum Concern: Int, Comparable, Sendable {
        case none = 0
        case low
        case moderate
        case high

        static func < (lhs: Concern, rhs: Concern) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .none:     return "No known concern"
            case .low:      return "Limited concern"
            case .moderate: return "Moderate concern"
            case .high:     return "Avoid where possible"
            }
        }
    }

    /// Code without prefix, e.g. "412", "150d", "1442".
    let code: String
    let name: String
    /// Technological role: thickener, colour, preservative…
    let function: String
    let concern: Concern
    /// One or two plain-English sentences: what it is, where it comes from,
    /// and why (if at all) it is flagged.
    let note: String

    var id: String { code }

    /// Numeric part only ("150d" → 150) for sorting and class lookup.
    var number: Int { Int(code.prefix { $0.isNumber }) ?? 0 }

    /// "412 · E412" so both NZ/AU and EU readers recognise it.
    var displayCode: String { "\(code) · E\(code)" }
}

// MARK: - Catalogue & detection

enum FoodAdditives {

    // MARK: Detection

    /// Additives found in free-text ingredients, in order of first
    /// appearance, each listed once. Handles bare codes, E-numbers, INS
    /// numbers, letter suffixes (150d, 160a) and the common written names.
    static func detect(in ingredientsText: String?) -> [FoodAdditive] {
        guard let raw = ingredientsText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
        let text = raw.lowercased()
        var hits: [(position: Int, additive: FoodAdditive)] = []
        var seen: Set<String> = []

        func record(_ additive: FoodAdditive, at position: Int) {
            guard !seen.contains(additive.code) else { return }
            seen.insert(additive.code)
            hits.append((position, additive))
        }

        // 1) Numeric codes.
        let ns = text as NSString
        for match in codeRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let prefixed = match.range(at: 1).location != NSNotFound
            let digits = ns.substring(with: match.range(at: 2))
            let suffix = match.range(at: 3).location != NSNotFound ? ns.substring(with: match.range(at: 3)) : ""
            let code = digits + suffix

            if let known = additive(for: code) {
                record(known, at: match.range.location)
            } else if prefixed, let n = Int(digits), (100...1599).contains(n) {
                // Explicit "E" / "INS" prefix on a code we don't catalogue:
                // still clearly an additive, so surface it rather than hide it.
                record(FoodAdditive(code: code,
                                    name: "Additive \(code)",
                                    function: "Food additive",
                                    concern: .low,
                                    note: "Not in the built-in catalogue. Look the code up for details."),
                       at: match.range.location)
            }
        }

        // 2) Written names ("guar gum", "sodium nitrite"). Longest aliases
        // first, and each match is blanked out so a shorter alias inside it
        // can't fire again ("citric acid esters of mono- and diglycerides"
        // must not also report citric acid and diglycerides).
        var masked = text
        for (alias, code) in aliasesByLength {
            guard let additive = additive(for: code) else { continue }
            var searchRange = masked.startIndex..<masked.endIndex
            while let range = masked.range(of: alias, range: searchRange) {
                if isWordBounded(range, in: masked) {
                    record(additive, at: masked.distance(from: masked.startIndex, to: range.lowerBound))
                    masked.replaceSubrange(range, with: String(repeating: " ", count: alias.count))
                    break
                }
                searchRange = range.upperBound..<masked.endIndex
            }
        }

        return hits.sorted { $0.position < $1.position }.map(\.additive)
    }

    /// Additives from Open Food Facts style tags ("en:e412", "en:e150d").
    static func detect(tags: [String]?) -> [FoodAdditive] {
        guard let tags, !tags.isEmpty else { return [] }
        var out: [FoodAdditive] = []
        var seen: Set<String> = []
        for tag in tags {
            var code = tag.lowercased()
            if let colon = code.lastIndex(of: ":") { code = String(code[code.index(after: colon)...]) }
            if code.hasPrefix("e") { code.removeFirst() }
            // Tags sometimes carry a roman-numeral subtype ("e450i"); the
            // catalogue is keyed on the parent code.
            let digits = String(code.prefix { $0.isNumber })
            let rest = code.dropFirst(digits.count)
            let suffix: String = rest.first.flatMap { ("a"..."f").contains($0) ? String($0) : nil } ?? ""
            let trimmed = digits + suffix
            guard !seen.contains(trimmed), let known = additive(for: trimmed) ?? additive(for: digits) else { continue }
            seen.insert(known.code)
            out.append(known)
        }
        return out
    }

    /// Merges text and tag detections, preserving text order and appending
    /// anything only the tags knew about.
    static func merged(text: String?, tags: [String]?) -> [FoodAdditive] {
        var out = detect(in: text)
        var seen = Set(out.map(\.code))
        for a in detect(tags: tags) where !seen.contains(a.code) {
            seen.insert(a.code)
            out.append(a)
        }
        return out
    }

    /// Catalogue lookup. "150D" → E150d row; "450" also matches "450".
    static func additive(for code: String) -> FoodAdditive? {
        let key = code.lowercased().trimmingCharacters(in: .whitespaces)
        return catalogue[key]
    }

    /// Catalogue lookup by written name ("Guar gum", "MSG").
    static func additive(named name: String) -> FoodAdditive? {
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = aliases[key] { return additive(for: code) }
        return catalogue.values.first { $0.name.lowercased() == key }
    }

    /// The additive classes by number range (Codex INS layout).
    static func category(forNumber n: Int) -> String {
        switch n {
        case 100..<200:   return "Colour"
        case 200..<300:   return "Preservative"
        case 300..<400:   return "Antioxidant / acidity regulator"
        case 400..<500:   return "Thickener / emulsifier / stabiliser"
        case 500..<600:   return "Acidity regulator / anti-caking agent"
        case 600..<700:   return "Flavour enhancer"
        case 900..<1000:  return "Glazing agent / sweetener / gas"
        case 1000..<1200: return "Enzyme / improving agent"
        case 1200..<1600: return "Modified starch / carrier"
        default:          return "Food additive"
        }
    }

    // MARK: Regex

    /// Group 1: optional "e" / "ins" prefix. Group 2: 3–4 digit code.
    /// Group 3: optional a–f suffix. The lookahead rejects quantities
    /// ("500 g", "330ml", "100%", "12 x") and anything glued to more letters.
    private static let codeRegex: NSRegularExpression = {
        let pattern = #"(?<![a-z0-9.])(?:(e|ins)[\s\-]?)?([1-9][0-9]{2,3})([a-f])?(?![a-z0-9.%])(?!\s*(?:%|(?:g|gm|gms|mg|kg|ml|l|lt|kj|kcal|cal|cals|mcg|µg|iu|x|pk|pack|pcs|serves|servings)\b))"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static func isWordBounded(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before.isLetter { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if after.isLetter { return false }
        }
        return true
    }

    // MARK: Aliases

    /// Written names → code. Lowercase. Keep plurals/variants that labels
    /// actually print.
    static let aliases: [String: String] = [
        // Colours
        "curcumin": "100", "turmeric extract": "100",
        "riboflavin": "101",
        "tartrazine": "102",
        "quinoline yellow": "104",
        "sunset yellow": "110", "sunset yellow fcf": "110",
        "cochineal": "120", "carmine": "120", "carminic acid": "120",
        "carmoisine": "122", "azorubine": "122",
        "amaranth": "123",
        "ponceau 4r": "124",
        "erythrosine": "127",
        "allura red": "129", "allura red ac": "129",
        "patent blue": "131",
        "indigotine": "132", "indigo carmine": "132",
        "brilliant blue": "133", "brilliant blue fcf": "133",
        "chlorophyll": "140", "chlorophyllin": "141",
        "green s": "142",
        "plain caramel": "150a", "caustic sulphite caramel": "150b", "caustic sulfite caramel": "150b",
        "ammonia caramel": "150c", "sulphite ammonia caramel": "150d", "sulfite ammonia caramel": "150d",
        "brilliant black": "151", "black pn": "151",
        "vegetable carbon": "153", "carbon black": "153",
        "brown ht": "155",
        "beta-carotene": "160a", "beta carotene": "160a", "carotene": "160a", "carotenes": "160a",
        "annatto": "160b", "bixin": "160b", "norbixin": "160b",
        "paprika extract": "160c", "paprika oleoresin": "160c", "capsanthin": "160c",
        "lycopene": "160d",
        "lutein": "161b",
        "beet red": "162", "beetroot red": "162", "betanin": "162",
        "anthocyanins": "163", "anthocyanin": "163",
        "calcium carbonate": "170",
        "titanium dioxide": "171",
        "iron oxide": "172", "iron oxides": "172",
        // Preservatives
        "sorbic acid": "200", "potassium sorbate": "202", "calcium sorbate": "203",
        "benzoic acid": "210", "sodium benzoate": "211", "potassium benzoate": "212", "calcium benzoate": "213",
        "sulphur dioxide": "220", "sulfur dioxide": "220",
        "sodium sulphite": "221", "sodium sulfite": "221",
        "sodium bisulphite": "222", "sodium bisulfite": "222",
        "sodium metabisulphite": "223", "sodium metabisulfite": "223",
        "potassium metabisulphite": "224", "potassium metabisulfite": "224",
        "potassium sulphite": "225", "potassium sulfite": "225",
        "calcium sulphite": "226", "calcium sulfite": "226",
        "potassium bisulphite": "228", "potassium bisulfite": "228",
        "nisin": "234", "natamycin": "235", "pimaricin": "235",
        "potassium nitrite": "249", "sodium nitrite": "250", "sodium nitrate": "251", "potassium nitrate": "252", "saltpetre": "252",
        "propionic acid": "280", "sodium propionate": "281", "calcium propionate": "282", "potassium propionate": "283",
        // Antioxidants & acids
        "ascorbic acid": "300", "vitamin c (ascorbic acid)": "300", "sodium ascorbate": "301", "calcium ascorbate": "302", "ascorbyl palmitate": "304",
        "tocopherols": "306", "mixed tocopherols": "306", "tocopherol": "306", "alpha-tocopherol": "307", "vitamin e (tocopherol)": "307",
        "propyl gallate": "310", "octyl gallate": "311", "dodecyl gallate": "312",
        "erythorbic acid": "315", "sodium erythorbate": "316",
        "tbhq": "319", "tertiary butylhydroquinone": "319", "tert-butylhydroquinone": "319",
        "bha": "320", "butylated hydroxyanisole": "320",
        "bht": "321", "butylated hydroxytoluene": "321",
        "lecithin": "322", "lecithins": "322", "soy lecithin": "322", "soya lecithin": "322", "sunflower lecithin": "322", "rapeseed lecithin": "322",
        "sodium lactate": "325", "potassium lactate": "326", "calcium lactate": "327",
        "citric acid": "330", "sodium citrate": "331", "sodium citrates": "331", "trisodium citrate": "331",
        "potassium citrate": "332", "potassium citrates": "332", "calcium citrate": "333", "calcium citrates": "333",
        "tartaric acid": "334", "sodium tartrate": "335", "potassium tartrate": "336", "cream of tartar": "336", "potassium sodium tartrate": "337",
        "phosphoric acid": "338",
        "sodium phosphate": "339", "sodium phosphates": "339", "disodium phosphate": "339", "trisodium phosphate": "339",
        "potassium phosphate": "340", "potassium phosphates": "340", "dipotassium phosphate": "340",
        "calcium phosphate": "341", "calcium phosphates": "341", "tricalcium phosphate": "341", "monocalcium phosphate": "341", "dicalcium phosphate": "341",
        "magnesium phosphate": "343", "magnesium phosphates": "343",
        "malic acid": "296", "sodium malate": "350", "fumaric acid": "297", "acetic acid": "260", "potassium acetate": "261", "sodium acetate": "262", "sodium diacetate": "262", "calcium acetate": "263", "lactic acid": "270",
        "adipic acid": "355", "succinic acid": "363",
        "calcium disodium edta": "385", "edta": "385", "disodium edta": "385",
        "glucono delta-lactone": "575", "glucono-delta-lactone": "575", "gdl": "575",
        // Thickeners, gelling agents, emulsifiers
        "alginic acid": "400", "sodium alginate": "401", "potassium alginate": "402", "calcium alginate": "404", "propylene glycol alginate": "405",
        "agar": "406", "agar-agar": "406", "agar agar": "406",
        "carrageenan": "407", "irish moss": "407", "processed eucheuma seaweed": "407a",
        "locust bean gum": "410", "carob bean gum": "410", "carob gum": "410",
        "guar gum": "412", "guar": "412",
        "tragacanth": "413", "gum tragacanth": "413",
        "gum arabic": "414", "acacia gum": "414", "gum acacia": "414", "arabic gum": "414",
        "xanthan gum": "415", "xanthan": "415",
        "karaya gum": "416", "gum karaya": "416",
        "tara gum": "417",
        "gellan gum": "418", "gellan": "418",
        "sorbitol": "420", "sorbitol syrup": "420",
        "mannitol": "421",
        "glycerol": "422", "glycerin": "422", "glycerine": "422", "vegetable glycerin": "422", "vegetable glycerine": "422",
        "konjac": "425", "konjac gum": "425", "konjac glucomannan": "425", "glucomannan": "425",
        "polysorbate 20": "432", "polysorbate 80": "433", "polysorbate 40": "434", "polysorbate 60": "435", "polysorbate 65": "436",
        "pectin": "440", "pectins": "440", "amidated pectin": "440",
        "gelatine": "441", "gelatin": "441",
        "ammonium phosphatides": "442",
        "sucrose acetate isobutyrate": "444", "saib": "444",
        "glycerol ester of wood rosin": "445", "glycerol esters of wood rosin": "445", "ester gum": "445",
        "diphosphates": "450", "disodium diphosphate": "450", "sodium acid pyrophosphate": "450", "tetrasodium pyrophosphate": "450", "sodium pyrophosphate": "450",
        "triphosphates": "451", "sodium tripolyphosphate": "451", "pentasodium triphosphate": "451",
        "polyphosphates": "452", "sodium polyphosphate": "452", "sodium hexametaphosphate": "452",
        "cellulose": "460", "microcrystalline cellulose": "460", "cellulose powder": "460", "powdered cellulose": "460",
        "methylcellulose": "461", "methyl cellulose": "461",
        "hydroxypropyl cellulose": "463",
        "hydroxypropyl methylcellulose": "464", "hpmc": "464", "hypromellose": "464",
        "carboxymethylcellulose": "466", "carboxymethyl cellulose": "466", "sodium carboxymethylcellulose": "466", "cellulose gum": "466", "cmc": "466",
        "magnesium stearate": "470", "calcium stearate": "470", "sodium stearate": "470",
        "mono- and diglycerides": "471", "mono and diglycerides": "471", "mono-and diglycerides": "471", "monoglycerides": "471", "diglycerides": "471", "mono- and di-glycerides of fatty acids": "471", "glycerol monostearate": "471",
        "acetic acid esters of mono- and diglycerides": "472a",
        "lactic acid esters of mono- and diglycerides": "472b",
        "citric acid esters of mono- and diglycerides": "472c",
        "datem": "472e", "diacetyl tartaric acid esters of mono- and diglycerides": "472e",
        "sucrose esters": "473", "sucrose esters of fatty acids": "473",
        "polyglycerol esters": "475", "polyglycerol esters of fatty acids": "475",
        "pgpr": "476", "polyglycerol polyricinoleate": "476",
        "propylene glycol esters": "477", "propylene glycol esters of fatty acids": "477",
        "sodium stearoyl lactylate": "481", "sodium stearoyl-2-lactylate": "481", "ssl": "481",
        "calcium stearoyl lactylate": "482", "calcium stearoyl-2-lactylate": "482",
        "stearyl tartrate": "483",
        "sorbitan monostearate": "491", "sorbitan tristearate": "492", "sorbitan monolaurate": "493", "sorbitan monooleate": "494", "sorbitan monopalmitate": "495",
        // Acidity regulators, anti-caking, raising agents
        "sodium carbonate": "500", "sodium bicarbonate": "500", "bicarbonate of soda": "500", "baking soda": "500", "sodium hydrogen carbonate": "500", "soda ash": "500",
        "potassium carbonate": "501", "potassium bicarbonate": "501",
        "ammonium carbonate": "503", "ammonium bicarbonate": "503",
        "magnesium carbonate": "504",
        "hydrochloric acid": "507", "potassium chloride": "508", "calcium chloride": "509", "ammonium chloride": "510", "magnesium chloride": "511",
        "stannous chloride": "512", "tin chloride": "512",
        "sulphuric acid": "513", "sulfuric acid": "513", "sodium sulphate": "514", "sodium sulfate": "514", "potassium sulphate": "515", "potassium sulfate": "515", "calcium sulphate": "516", "calcium sulfate": "516", "ammonium sulphate": "517", "ammonium sulfate": "517",
        "sodium hydroxide": "524", "potassium hydroxide": "525", "calcium hydroxide": "526", "ammonium hydroxide": "527", "magnesium hydroxide": "528", "calcium oxide": "529", "magnesium oxide": "530",
        "sodium ferrocyanide": "535", "potassium ferrocyanide": "536", "calcium ferrocyanide": "538",
        "sodium aluminium phosphate": "541", "sodium aluminum phosphate": "541",
        "bone phosphate": "542",
        "silicon dioxide": "551", "silica": "551", "silicon dioxide (silica)": "551",
        "calcium silicate": "552", "magnesium silicate": "553a", "talc": "553b",
        "sodium aluminosilicate": "554", "sodium aluminium silicate": "554",
        "potassium aluminium silicate": "555", "calcium aluminium silicate": "556",
        "bentonite": "558", "kaolin": "559", "aluminium silicate": "559",
        "stearic acid": "570", "fatty acids": "570",
        "gluconic acid": "574", "sodium gluconate": "576", "potassium gluconate": "577", "calcium gluconate": "578",
        "ferrous gluconate": "579", "ferrous lactate": "585",
        // Flavour enhancers
        "glutamic acid": "620",
        "monosodium glutamate": "621", "msg": "621", "sodium glutamate": "621",
        "monopotassium glutamate": "622", "calcium glutamate": "623", "monoammonium glutamate": "624", "magnesium glutamate": "625",
        "guanylic acid": "626", "disodium guanylate": "627", "sodium guanylate": "627",
        "inosinic acid": "630", "disodium inosinate": "631", "sodium inosinate": "631",
        "disodium 5'-ribonucleotides": "635", "disodium ribonucleotides": "635", "ribonucleotides": "635",
        "maltol": "636", "ethyl maltol": "637",
        "glycine": "640", "l-leucine": "641",
        // Glazing agents, gases, sweeteners
        "dimethylpolysiloxane": "900", "dimethyl polysiloxane": "900", "polydimethylsiloxane": "900",
        "beeswax": "901", "candelilla wax": "902", "carnauba wax": "903", "shellac": "904", "microcrystalline wax": "905", "paraffin": "905",
        "l-cysteine": "920", "cysteine": "920",
        "potassium bromate": "924",
        "azodicarbonamide": "927a",
        "benzoyl peroxide": "928",
        "argon": "938", "helium": "939", "nitrogen": "941", "nitrous oxide": "942", "oxygen": "948", "hydrogen": "949",
        "acesulfame k": "950", "acesulfame potassium": "950", "acesulfame-k": "950", "ace-k": "950",
        "aspartame": "951",
        "cyclamate": "952", "sodium cyclamate": "952", "cyclamic acid": "952",
        "isomalt": "953",
        "saccharin": "954", "sodium saccharin": "954",
        "sucralose": "955",
        "alitame": "956",
        "thaumatin": "957",
        "neohesperidine dc": "959", "neohesperidine": "959",
        "steviol glycosides": "960", "stevia": "960", "stevia extract": "960", "rebaudioside a": "960", "reb a": "960",
        "neotame": "961",
        "aspartame-acesulfame salt": "962", "salt of aspartame-acesulfame": "962",
        "maltitol": "965", "maltitol syrup": "965",
        "lactitol": "966",
        "xylitol": "967",
        "erythritol": "968",
        "advantame": "969",
        // Enzymes, improvers, starches, carriers
        "amylase": "1100", "amylases": "1100", "protease": "1101", "glucose oxidase": "1102", "invertase": "1103", "lipase": "1104", "lysozyme": "1105",
        "polydextrose": "1200",
        "polyvinylpyrrolidone": "1201", "pvp": "1201", "polyvinylpolypyrrolidone": "1202",
        "polyvinyl alcohol": "1203",
        "dextrin": "1400", "roasted starch": "1400",
        "acid treated starch": "1401", "acid-treated starch": "1401",
        "alkaline treated starch": "1402", "bleached starch": "1403",
        "oxidised starch": "1404", "oxidized starch": "1404",
        "enzyme treated starch": "1405",
        "monostarch phosphate": "1410",
        "distarch phosphate": "1412",
        "phosphated distarch phosphate": "1413",
        "acetylated distarch phosphate": "1414",
        "starch acetate": "1420", "acetylated starch": "1420",
        "acetylated distarch adipate": "1422",
        "hydroxypropyl starch": "1440",
        "hydroxypropyl distarch phosphate": "1442",
        "starch sodium octenyl succinate": "1450", "octenyl succinic acid modified starch": "1450", "osa starch": "1450",
        "acetylated oxidised starch": "1451", "acetylated oxidized starch": "1451",
        "triethyl citrate": "1505",
        "ethanol": "1510", "ethyl alcohol": "1510",
        "glyceryl triacetate": "1518", "triacetin": "1518",
        "benzyl alcohol": "1519",
        "propylene glycol": "1520", "propane-1,2-diol": "1520",
        "polyethylene glycol": "1521",
    ]

    private static let aliasesByLength: [(String, String)] = aliases
        .sorted { a, b in a.key.count != b.key.count ? a.key.count > b.key.count : a.key < b.key }

    // MARK: Catalogue

    /// Keyed by lowercase code without prefix. Roman-numeral subtypes
    /// (450i, 450ii…) share the parent row.
    static let catalogue: [String: FoodAdditive] = {
        var t: [String: FoodAdditive] = [:]
        func add(_ code: String, _ name: String, _ function: String, _ concern: FoodAdditive.Concern, _ note: String) {
            t[code] = FoodAdditive(code: code, name: name, function: function, concern: concern, note: note)
        }

        // ----- Colours (100–199) -----
        add("100", "Curcumin", "Colour", .none, "Yellow pigment from turmeric root. Plant-derived; widely regarded as safe at food levels.")
        add("101", "Riboflavin", "Colour", .none, "Vitamin B2 used as a yellow colour. No safety concern.")
        add("102", "Tartrazine", "Colour", .moderate, "Synthetic azo yellow. In the EU it carries a mandatory warning that it may affect activity and attention in children; a known trigger for some sensitivities.")
        add("104", "Quinoline Yellow", "Colour", .moderate, "Synthetic yellow. EU warning label for effects on children's attention; banned in the US, Australia and Japan for most uses.")
        add("110", "Sunset Yellow FCF", "Colour", .moderate, "Synthetic azo orange. EU warning label for effects on children's attention; sometimes linked to hives in sensitive people.")
        add("120", "Cochineal / Carmine", "Colour", .low, "Red pigment made from crushed cochineal insects, so not vegetarian or vegan. Rare but documented allergic reactions.")
        add("122", "Carmoisine (Azorubine)", "Colour", .moderate, "Synthetic azo red. EU warning label for effects on children's attention; not permitted in the US.")
        add("123", "Amaranth", "Colour", .moderate, "Synthetic azo red. Banned in the US since 1976 over cancer concerns in rodent studies; still permitted in limited uses elsewhere.")
        add("124", "Ponceau 4R", "Colour", .moderate, "Synthetic azo red. EU warning label for effects on children's attention; banned in the US.")
        add("127", "Erythrosine", "Colour", .moderate, "Synthetic cherry-pink dye. The US FDA revoked its use in food in 2025 after thyroid tumours in rats; still permitted in glacé cherries elsewhere.")
        add("129", "Allura Red AC", "Colour", .moderate, "Synthetic azo red. EU warning label for effects on children's attention; some evidence of gut irritation at high intakes.")
        add("131", "Patent Blue V", "Colour", .low, "Synthetic blue. Rare allergic reactions reported; not approved in the US.")
        add("132", "Indigotine (Indigo Carmine)", "Colour", .low, "Synthetic blue. Considered safe at normal intakes; occasional sensitivity reports.")
        add("133", "Brilliant Blue FCF", "Colour", .low, "Synthetic blue. EFSA considers it safe at food levels; poorly absorbed by the gut.")
        add("140", "Chlorophylls", "Colour", .none, "Green pigment extracted from plants. No safety concern.")
        add("141", "Copper complexes of chlorophyll", "Colour", .none, "Stabilised plant chlorophyll. No safety concern at food levels.")
        add("142", "Green S", "Colour", .low, "Synthetic green. Permitted in the EU and NZ/AU; banned in the US, Canada and Japan.")
        add("150a", "Plain caramel", "Colour", .none, "Caramelised sugar with no added chemicals. The cleanest of the four caramel colours.")
        add("150b", "Caustic sulphite caramel", "Colour", .low, "Caramel made with sulphite compounds. Low concern; may matter for sulphite-sensitive people.")
        add("150c", "Ammonia caramel", "Colour", .low, "Caramel made with ammonia compounds; contains traces of 4-MEI, which regulators monitor. The colour in many dark sauces and beers.")
        add("150d", "Sulphite ammonia caramel", "Colour", .low, "The colour in cola. Contains traces of 4-MEI; EFSA set a limit and considers normal intakes safe.")
        add("151", "Brilliant Black PN", "Colour", .moderate, "Synthetic azo black. Banned in several countries; may trigger sensitivities, especially with aspirin intolerance.")
        add("153", "Vegetable carbon", "Colour", .none, "Charcoal from plant material, used for black colouring. EFSA considers it safe when free of contaminants.")
        add("155", "Brown HT", "Colour", .moderate, "Synthetic azo brown. Banned in several countries; may affect sensitive people, including those with asthma.")
        add("160a", "Carotenes (beta-carotene)", "Colour", .none, "Orange pigment from carrots, palm oil or algae; a vitamin A precursor. No concern at food levels.")
        add("160b", "Annatto (bixin, norbixin)", "Colour", .low, "Natural orange from achiote seeds. Rare but well-documented allergic reactions.")
        add("160c", "Paprika extract", "Colour", .none, "Natural red-orange from paprika. No safety concern.")
        add("160d", "Lycopene", "Colour", .none, "Red pigment from tomatoes. No safety concern.")
        add("160e", "Beta-apo-8'-carotenal", "Colour", .none, "Carotenoid orange colour. No concern at food levels.")
        add("161b", "Lutein", "Colour", .none, "Yellow carotenoid from marigolds. No concern.")
        add("161g", "Canthaxanthin", "Colour", .low, "Orange carotenoid, mainly used in salmon feed. Restricted because high doses can deposit in the eye.")
        add("162", "Beet red (betanin)", "Colour", .none, "Natural red from beetroot. No concern.")
        add("163", "Anthocyanins", "Colour", .none, "Purple-red pigments from grapes, berries or purple carrots. No concern.")
        add("170", "Calcium carbonate", "Colour / anti-caking agent", .none, "Chalk; also a calcium source. No concern.")
        add("171", "Titanium dioxide", "Colour", .high, "Bright white pigment. Banned in EU food since 2022 because genotoxicity of nanoparticles could not be ruled out. Still permitted in NZ, Australia and the US.")
        add("172", "Iron oxides", "Colour", .none, "Mineral red, yellow and black pigments. No concern.")
        add("173", "Aluminium", "Colour", .moderate, "Metallic silver colour on confectionery. Adds to dietary aluminium, which regulators try to keep low.")
        add("174", "Silver", "Colour", .low, "Decorative metallic colour on cake decorations. Minimal intake; low concern.")
        add("175", "Gold", "Colour", .none, "Decorative gold leaf. Inert; no concern.")

        // ----- Preservatives (200–299) -----
        add("200", "Sorbic acid", "Preservative", .none, "Mould inhibitor originally from rowan berries. Metabolised like a fatty acid; no concern.")
        add("202", "Potassium sorbate", "Preservative", .none, "Salt of sorbic acid, the most common mould inhibitor. No concern at normal intakes.")
        add("203", "Calcium sorbate", "Preservative", .none, "Salt of sorbic acid. No concern.")
        add("210", "Benzoic acid", "Preservative", .low, "Occurs naturally in cranberries. Can trigger hives or asthma in sensitive people.")
        add("211", "Sodium benzoate", "Preservative", .moderate, "Common in soft drinks. Can form traces of benzene with vitamin C under heat or light, and was part of the Southampton study on children's attention.")
        add("212", "Potassium benzoate", "Preservative", .low, "Same family as sodium benzoate; same benzene caveat with vitamin C.")
        add("213", "Calcium benzoate", "Preservative", .low, "Same family as sodium benzoate.")
        add("220", "Sulphur dioxide", "Preservative", .moderate, "Used in wine, dried fruit and sausages. A recognised asthma trigger; labels must declare sulphites above 10 mg/kg.")
        add("221", "Sodium sulphite", "Preservative", .moderate, "Sulphite. Asthma trigger for sensitive people; must be declared on labels.")
        add("222", "Sodium bisulphite", "Preservative", .moderate, "Sulphite. Asthma trigger for sensitive people.")
        add("223", "Sodium metabisulphite", "Preservative", .moderate, "Sulphite common in sausages and dried fruit. Asthma trigger for sensitive people.")
        add("224", "Potassium metabisulphite", "Preservative", .moderate, "Sulphite used in wine and cider. Asthma trigger for sensitive people.")
        add("225", "Potassium sulphite", "Preservative", .moderate, "Sulphite. Asthma trigger for sensitive people.")
        add("226", "Calcium sulphite", "Preservative", .moderate, "Sulphite. Asthma trigger for sensitive people.")
        add("227", "Calcium bisulphite", "Preservative", .moderate, "Sulphite. Asthma trigger for sensitive people.")
        add("228", "Potassium bisulphite", "Preservative", .moderate, "Sulphite. Asthma trigger for sensitive people.")
        add("234", "Nisin", "Preservative", .none, "Natural antibacterial peptide from dairy fermentation. No concern.")
        add("235", "Natamycin", "Preservative", .low, "Antifungal used on cheese rinds and cured meat surfaces. Poorly absorbed; low concern.")
        add("239", "Hexamethylene tetramine", "Preservative", .moderate, "Releases formaldehyde; only permitted in one Italian cheese in the EU.")
        add("242", "Dimethyl dicarbonate", "Preservative", .low, "Cold-sterilises drinks and breaks down to CO₂ and methanol traces. Low concern.")
        add("249", "Potassium nitrite", "Preservative", .high, "Curing salt. Nitrites can form nitrosamines, part of why WHO classes processed meat as carcinogenic to humans.")
        add("250", "Sodium nitrite", "Preservative", .high, "The main curing salt in bacon, ham and salami. Can form nitrosamines, part of why WHO classes processed meat as carcinogenic to humans.")
        add("251", "Sodium nitrate", "Preservative", .high, "Curing salt that converts to nitrite in the body. Same nitrosamine concern as sodium nitrite.")
        add("252", "Potassium nitrate", "Preservative", .high, "Saltpetre, a traditional curing salt. Converts to nitrite; same nitrosamine concern.")
        add("260", "Acetic acid", "Acidity regulator / preservative", .none, "Vinegar. No concern.")
        add("261", "Potassium acetate", "Acidity regulator", .none, "Salt of vinegar. No concern.")
        add("262", "Sodium acetate / diacetate", "Acidity regulator", .none, "Salt of vinegar, the tang in salt-and-vinegar chips. No concern.")
        add("263", "Calcium acetate", "Acidity regulator", .none, "Salt of vinegar. No concern.")
        add("270", "Lactic acid", "Acidity regulator", .none, "The acid in yoghurt and sourdough. No concern.")
        add("280", "Propionic acid", "Preservative", .none, "Mould inhibitor found naturally in Swiss cheese. Low concern.")
        add("281", "Sodium propionate", "Preservative", .low, "Bread mould inhibitor. Some reports of irritability in children at high intakes; EFSA considers it safe.")
        add("282", "Calcium propionate", "Preservative", .low, "The standard bread mould inhibitor. Some reports of behavioural effects in children; EFSA considers it safe.")
        add("283", "Potassium propionate", "Preservative", .low, "Bread mould inhibitor, same family as calcium propionate.")
        add("290", "Carbon dioxide", "Packaging gas", .none, "The fizz. No concern.")
        add("296", "Malic acid", "Acidity regulator", .none, "The acid in apples. No concern.")
        add("297", "Fumaric acid", "Acidity regulator", .none, "Naturally occurring acid. No concern.")

        // ----- Antioxidants, acids & minerals (300–399) -----
        add("300", "Ascorbic acid", "Antioxidant", .none, "Vitamin C. No concern.")
        add("301", "Sodium ascorbate", "Antioxidant", .none, "Vitamin C salt, often used in cured meat to speed curing. No concern.")
        add("302", "Calcium ascorbate", "Antioxidant", .none, "Vitamin C salt. No concern.")
        add("304", "Ascorbyl palmitate", "Antioxidant", .none, "Fat-soluble vitamin C. No concern.")
        add("306", "Tocopherols (mixed)", "Antioxidant", .none, "Vitamin E from vegetable oils. No concern.")
        add("307", "Alpha-tocopherol", "Antioxidant", .none, "Vitamin E. No concern.")
        add("308", "Gamma-tocopherol", "Antioxidant", .none, "Vitamin E. No concern.")
        add("309", "Delta-tocopherol", "Antioxidant", .none, "Vitamin E. No concern.")
        add("310", "Propyl gallate", "Antioxidant", .moderate, "Synthetic antioxidant for fats and oils. Suspected endocrine activity in lab studies; restricted in baby food.")
        add("311", "Octyl gallate", "Antioxidant", .moderate, "Synthetic antioxidant. Withdrawn from the EU list in 2018 for lack of safety data.")
        add("312", "Dodecyl gallate", "Antioxidant", .moderate, "Synthetic antioxidant. Withdrawn from the EU list in 2018 for lack of safety data.")
        add("315", "Erythorbic acid", "Antioxidant", .none, "An isomer of vitamin C. No concern.")
        add("316", "Sodium erythorbate", "Antioxidant", .none, "Used in cured meats to speed curing and limit nitrosamines. No concern.")
        add("319", "TBHQ", "Antioxidant", .moderate, "Synthetic antioxidant for frying oils and snack foods. Immune and tumour-promotion effects in animal studies at high doses; strictly dose-limited.")
        add("320", "BHA", "Antioxidant", .high, "Butylated hydroxyanisole. Classified by IARC as possibly carcinogenic to humans; listed as a carcinogen under California Prop 65.")
        add("321", "BHT", "Antioxidant", .moderate, "Butylated hydroxytoluene. Liver and thyroid effects in animal studies; EFSA considers it safe at the current limit.")
        add("322", "Lecithin", "Emulsifier", .none, "Usually from soy or sunflower; occasionally egg. Naturally occurring fat; no concern.")
        add("325", "Sodium lactate", "Humectant / acidity regulator", .none, "Salt of lactic acid. No concern.")
        add("326", "Potassium lactate", "Humectant / acidity regulator", .none, "Salt of lactic acid. No concern.")
        add("327", "Calcium lactate", "Firming agent", .none, "Salt of lactic acid, also a calcium source. No concern.")
        add("330", "Citric acid", "Acidity regulator", .none, "The acid in citrus fruit, usually made by fermentation. No concern.")
        add("331", "Sodium citrates", "Acidity regulator / emulsifying salt", .none, "Salt of citric acid; the melting salt in processed cheese. No concern.")
        add("332", "Potassium citrates", "Acidity regulator", .none, "Salt of citric acid. No concern.")
        add("333", "Calcium citrates", "Acidity regulator / firming agent", .none, "Salt of citric acid. No concern.")
        add("334", "Tartaric acid", "Acidity regulator", .none, "The acid in grapes. No concern.")
        add("335", "Sodium tartrates", "Acidity regulator", .none, "Salt of tartaric acid. No concern.")
        add("336", "Potassium tartrates (cream of tartar)", "Raising agent", .none, "Cream of tartar. No concern.")
        add("337", "Potassium sodium tartrate", "Acidity regulator", .none, "Rochelle salt. No concern.")
        add("338", "Phosphoric acid", "Acidity regulator", .moderate, "The acid in cola. Adds to total phosphate intake, which EFSA flagged in 2019 as possibly exceeding safe levels for heavy consumers of processed food.")
        add("339", "Sodium phosphates", "Emulsifying salt / stabiliser", .moderate, "Added phosphates in processed meat and cheese. EFSA lowered the group safe intake in 2019; high phosphate intake is linked to kidney and heart strain.")
        add("340", "Potassium phosphates", "Emulsifying salt / stabiliser", .moderate, "Added phosphates. Same intake concern as sodium phosphates.")
        add("341", "Calcium phosphates", "Raising agent / anti-caking agent", .low, "The acid in most baking powders and a calcium source. Counts toward total phosphate intake.")
        add("343", "Magnesium phosphates", "Anti-caking agent", .low, "Counts toward total phosphate intake; otherwise a mineral source.")
        add("350", "Sodium malates", "Acidity regulator", .none, "Salt of malic acid. No concern.")
        add("351", "Potassium malate", "Acidity regulator", .none, "Salt of malic acid. No concern.")
        add("352", "Calcium malates", "Acidity regulator", .none, "Salt of malic acid. No concern.")
        add("353", "Metatartaric acid", "Stabiliser", .none, "Prevents tartrate crystals in wine. No concern.")
        add("354", "Calcium tartrate", "Acidity regulator", .none, "No concern.")
        add("355", "Adipic acid", "Acidity regulator", .none, "Tart acid used in jelly crystals. No concern.")
        add("363", "Succinic acid", "Acidity regulator", .none, "Naturally occurring acid. No concern.")
        add("380", "Triammonium citrate", "Acidity regulator", .none, "No concern.")
        add("385", "Calcium disodium EDTA", "Sequestrant", .low, "Binds trace metals to stop rancidity and discolouration in mayonnaise and canned beans. Can reduce mineral absorption at high intakes; strictly limited.")
        add("392", "Rosemary extract", "Antioxidant", .none, "Natural antioxidant from rosemary. No concern.")

        // ----- Thickeners, gelling agents, emulsifiers (400–499) -----
        add("400", "Alginic acid", "Thickener", .none, "Fibre from brown seaweed. No concern.")
        add("401", "Sodium alginate", "Thickener / gelling agent", .none, "Seaweed fibre; used in spherification and ice cream. No concern.")
        add("402", "Potassium alginate", "Thickener", .none, "Seaweed fibre. No concern.")
        add("403", "Ammonium alginate", "Thickener", .none, "Seaweed fibre. No concern.")
        add("404", "Calcium alginate", "Thickener / gelling agent", .none, "Seaweed fibre. No concern.")
        add("405", "Propylene glycol alginate", "Thickener / emulsifier", .low, "Modified seaweed fibre used for beer foam and salad dressings. Low concern.")
        add("406", "Agar", "Gelling agent", .none, "Seaweed gel, a vegan alternative to gelatine. No concern.")
        add("407", "Carrageenan", "Thickener / stabiliser", .moderate, "Red seaweed extract in plant milks, cream and deli meats. Food-grade carrageenan is considered safe by EFSA, but animal and cell studies on gut inflammation keep it under review; the degraded form is not permitted in food.")
        add("407a", "Processed eucheuma seaweed", "Thickener", .moderate, "A less-refined carrageenan. Same gut-inflammation debate as carrageenan.")
        add("410", "Locust bean gum", "Thickener", .none, "Carob seed fibre, used in ice cream and cream cheese. No concern; even used in infant thickeners.")
        add("412", "Guar gum", "Thickener", .none, "Soluble fibre from guar beans. No concern at food levels; large amounts can cause bloating.")
        add("413", "Tragacanth", "Thickener", .none, "Tree gum. Rare allergy reports; otherwise no concern.")
        add("414", "Gum arabic (acacia)", "Thickener / emulsifier", .none, "Acacia tree sap, also a prebiotic fibre. No concern.")
        add("415", "Xanthan gum", "Thickener", .none, "Fermentation-derived fibre used in gluten-free baking and sauces. No concern; large amounts can be laxative.")
        add("416", "Karaya gum", "Thickener", .low, "Tree gum. Rare sensitivities; otherwise low concern.")
        add("417", "Tara gum", "Thickener", .none, "Seed gum similar to locust bean gum. No concern.")
        add("418", "Gellan gum", "Gelling agent", .none, "Fermentation-derived gel used in plant milks. No concern.")
        add("420", "Sorbitol", "Sweetener / humectant", .low, "Sugar alcohol found in stone fruit. Laxative above about 20 g a day; products must carry a warning.")
        add("421", "Mannitol", "Sweetener / humectant", .low, "Sugar alcohol. Laxative in excess; otherwise no concern.")
        add("422", "Glycerol", "Humectant", .none, "Glycerine, from vegetable oils or fermentation. No concern at food levels.")
        add("425", "Konjac", "Thickener / gelling agent", .low, "Glucomannan fibre. Safe as a thickener, but banned in jelly mini-cups in many countries after choking deaths.")
        add("431", "Polyoxyethylene (40) stearate", "Emulsifier", .low, "Synthetic emulsifier. Low concern.")
        add("432", "Polysorbate 20", "Emulsifier", .moderate, "Synthetic emulsifier. Polysorbates alter the gut microbiome and barrier in animal studies; EFSA considers current levels safe.")
        add("433", "Polysorbate 80", "Emulsifier", .moderate, "The most common polysorbate, in ice cream and sauces. Alters the gut microbiome and barrier in animal studies; EFSA considers current levels safe.")
        add("434", "Polysorbate 40", "Emulsifier", .moderate, "Synthetic emulsifier; same gut-microbiome questions as polysorbate 80.")
        add("435", "Polysorbate 60", "Emulsifier", .moderate, "Synthetic emulsifier; same gut-microbiome questions as polysorbate 80.")
        add("436", "Polysorbate 65", "Emulsifier", .moderate, "Synthetic emulsifier; same gut-microbiome questions as polysorbate 80.")
        add("440", "Pectin", "Gelling agent", .none, "Fruit fibre that sets jam. No concern.")
        add("441", "Gelatine", "Gelling agent", .none, "Animal collagen from pork or beef, so not vegetarian, halal or kosher unless specified. No safety concern.")
        add("442", "Ammonium phosphatides", "Emulsifier", .low, "Synthetic emulsifier used in chocolate. Low concern.")
        add("444", "Sucrose acetate isobutyrate", "Stabiliser", .low, "Keeps flavour oils suspended in drinks. Low concern.")
        add("445", "Glycerol esters of wood rosin", "Stabiliser", .low, "Weighting agent in citrus drinks. Low concern.")
        add("450", "Diphosphates", "Raising agent / stabiliser", .moderate, "Added phosphates in baking powder, processed meat and cheese. Counts toward the phosphate intake EFSA flagged in 2019.")
        add("451", "Triphosphates", "Stabiliser / water-retention agent", .moderate, "Added phosphates that hold water in meat and seafood. Counts toward total phosphate intake.")
        add("452", "Polyphosphates", "Stabiliser / water-retention agent", .moderate, "Added phosphates in processed meat and seafood. Counts toward total phosphate intake.")
        add("459", "Beta-cyclodextrin", "Carrier", .none, "Starch-derived flavour carrier. No concern.")
        add("460", "Cellulose (microcrystalline)", "Anti-caking agent / bulking agent", .none, "Plant fibre, often from wood pulp. Not digested; no concern.")
        add("461", "Methylcellulose", "Thickener", .none, "Modified plant fibre that sets when hot; common in plant-based meat. No concern.")
        add("463", "Hydroxypropyl cellulose", "Thickener", .none, "Modified plant fibre. No concern.")
        add("464", "Hydroxypropyl methylcellulose", "Thickener / emulsifier", .none, "Modified plant fibre used in gluten-free bread. No concern.")
        add("465", "Ethyl methylcellulose", "Thickener", .none, "Modified plant fibre. No concern.")
        add("466", "Carboxymethylcellulose (cellulose gum)", "Thickener / stabiliser", .low, "Modified plant fibre in ice cream and gluten-free foods. A 2021 human trial showed changes to gut bacteria at high doses; EFSA considers current use safe.")
        add("468", "Cross-linked sodium carboxymethylcellulose", "Stabiliser", .none, "Modified plant fibre. No concern.")
        add("470", "Fatty acid salts (magnesium / calcium stearate)", "Anti-caking agent / emulsifier", .none, "Salts of vegetable fatty acids. No concern.")
        add("471", "Mono- and diglycerides of fatty acids", "Emulsifier", .none, "The most common emulsifier in bread and ice cream, made from vegetable or animal fats. May not be vegan unless the source is stated. No safety concern.")
        add("472a", "Acetic acid esters of mono- and diglycerides", "Emulsifier", .none, "Fat-based emulsifier. No concern.")
        add("472b", "Lactic acid esters of mono- and diglycerides", "Emulsifier", .none, "Fat-based emulsifier. No concern.")
        add("472c", "Citric acid esters of mono- and diglycerides", "Emulsifier", .none, "Fat-based emulsifier. No concern.")
        add("472e", "DATEM", "Emulsifier", .none, "Dough strengthener in bread. No concern.")
        add("473", "Sucrose esters of fatty acids", "Emulsifier", .none, "Sugar-fat emulsifier. No concern.")
        add("475", "Polyglycerol esters of fatty acids", "Emulsifier", .none, "Fat-based emulsifier. No concern.")
        add("476", "PGPR", "Emulsifier", .low, "Polyglycerol polyricinoleate, from castor oil; lets chocolate makers use less cocoa butter. Low concern.")
        add("477", "Propylene glycol esters of fatty acids", "Emulsifier", .low, "Fat-based emulsifier. Low concern.")
        add("481", "Sodium stearoyl lactylate", "Emulsifier", .none, "Dough conditioner. No concern.")
        add("482", "Calcium stearoyl lactylate", "Emulsifier", .none, "Dough conditioner. No concern.")
        add("483", "Stearyl tartrate", "Emulsifier", .none, "Flour treatment agent. No concern.")
        add("491", "Sorbitan monostearate", "Emulsifier", .low, "Synthetic emulsifier in cake mixes and yeast. Low concern.")
        add("492", "Sorbitan tristearate", "Emulsifier", .low, "Synthetic emulsifier in chocolate. Low concern.")
        add("493", "Sorbitan monolaurate", "Emulsifier", .low, "Synthetic emulsifier. Low concern.")
        add("494", "Sorbitan monooleate", "Emulsifier", .low, "Synthetic emulsifier. Low concern.")
        add("495", "Sorbitan monopalmitate", "Emulsifier", .low, "Synthetic emulsifier. Low concern.")

        // ----- Acidity regulators, anti-caking, raising agents (500–599) -----
        add("500", "Sodium carbonates (bicarbonate of soda)", "Raising agent / acidity regulator", .none, "Baking soda. No concern.")
        add("501", "Potassium carbonates", "Acidity regulator", .none, "Alkaline salt used in ramen noodles. No concern.")
        add("503", "Ammonium carbonates", "Raising agent", .none, "Baker's ammonia, for crisp biscuits. Bakes off completely; no concern.")
        add("504", "Magnesium carbonates", "Anti-caking agent", .none, "Mineral salt. No concern.")
        add("507", "Hydrochloric acid", "Acidity regulator", .none, "Processing acid, neutralised in the final food. No concern.")
        add("508", "Potassium chloride", "Salt substitute / gelling agent", .none, "Reduced-sodium salt. No concern for most people; those on potassium-restricted diets should note it.")
        add("509", "Calcium chloride", "Firming agent", .none, "Keeps canned vegetables firm and sets tofu. No concern.")
        add("510", "Ammonium chloride", "Acidity regulator", .low, "The salty-liquorice flavour. Low concern at food levels.")
        add("511", "Magnesium chloride", "Firming agent", .none, "Nigari, the traditional tofu coagulant. No concern.")
        add("512", "Stannous chloride", "Antioxidant / colour retention", .low, "Tin chloride, used to keep canned asparagus and white fruit from browning. Strictly dose-limited; low concern at permitted levels.")
        add("513", "Sulphuric acid", "Acidity regulator", .none, "Processing acid, neutralised in the final food. No concern.")
        add("514", "Sodium sulphates", "Acidity regulator", .none, "Mineral salt. No concern.")
        add("515", "Potassium sulphates", "Acidity regulator", .none, "Mineral salt. No concern.")
        add("516", "Calcium sulphate", "Firming agent / flour treatment", .none, "Gypsum; a tofu coagulant and calcium source. No concern.")
        add("517", "Ammonium sulphate", "Yeast nutrient", .none, "Yeast food in bread. No concern.")
        add("524", "Sodium hydroxide", "Acidity regulator", .none, "Lye, used for pretzel crusts and olive curing; neutralised in the food. No concern.")
        add("525", "Potassium hydroxide", "Acidity regulator", .none, "Processing alkali, neutralised in the food. No concern.")
        add("526", "Calcium hydroxide", "Acidity regulator / firming agent", .none, "Slaked lime, used to nixtamalise corn. No concern.")
        add("527", "Ammonium hydroxide", "Acidity regulator", .none, "Processing alkali. No concern at food levels.")
        add("528", "Magnesium hydroxide", "Acidity regulator", .none, "Milk of magnesia. No concern.")
        add("529", "Calcium oxide", "Acidity regulator", .none, "Quicklime, used in processing. No concern.")
        add("530", "Magnesium oxide", "Anti-caking agent", .none, "Mineral. No concern.")
        add("535", "Sodium ferrocyanide", "Anti-caking agent", .low, "Keeps table salt free-flowing. Tightly bound cyanide that is not released; low concern.")
        add("536", "Potassium ferrocyanide", "Anti-caking agent", .low, "Keeps salt free-flowing. Tightly bound cyanide; low concern.")
        add("538", "Calcium ferrocyanide", "Anti-caking agent", .low, "Keeps salt free-flowing. Low concern.")
        add("541", "Sodium aluminium phosphate", "Raising agent", .moderate, "Baking-powder acid that adds dietary aluminium. EFSA has pushed to reduce aluminium additives.")
        add("542", "Bone phosphate", "Anti-caking agent", .low, "Made from animal bones, so not vegetarian. Low safety concern.")
        add("551", "Silicon dioxide", "Anti-caking agent", .low, "Silica, keeps powders free-flowing. EFSA is reviewing nanoparticle forms; conventional silica is not absorbed.")
        add("552", "Calcium silicate", "Anti-caking agent", .none, "Mineral anti-caking agent. No concern.")
        add("553a", "Magnesium silicate", "Anti-caking agent", .none, "Mineral anti-caking agent. No concern.")
        add("553b", "Talc", "Anti-caking agent / glazing agent", .low, "Mineral. Food-grade talc must be asbestos-free; low concern.")
        add("554", "Sodium aluminosilicate", "Anti-caking agent", .moderate, "Adds dietary aluminium. EFSA has pushed to reduce aluminium additives.")
        add("555", "Potassium aluminium silicate", "Carrier", .moderate, "Mica, the base for pearlescent colours. Adds aluminium; EFSA restricted its use.")
        add("556", "Calcium aluminium silicate", "Anti-caking agent", .moderate, "Adds dietary aluminium.")
        add("558", "Bentonite", "Anti-caking agent", .none, "Clay used to fine wine. No concern.")
        add("559", "Kaolin (aluminium silicate)", "Anti-caking agent", .low, "Clay mineral. Low concern.")
        add("570", "Stearic acid / fatty acids", "Anti-caking agent", .none, "Vegetable fatty acid. No concern.")
        add("574", "Gluconic acid", "Acidity regulator", .none, "Fermentation acid. No concern.")
        add("575", "Glucono delta-lactone", "Acidity regulator / raising agent", .none, "Slow acid used in tofu and cured meat. No concern.")
        add("576", "Sodium gluconate", "Sequestrant", .none, "No concern.")
        add("577", "Potassium gluconate", "Sequestrant", .none, "No concern.")
        add("578", "Calcium gluconate", "Firming agent", .none, "Also a calcium source. No concern.")
        add("579", "Ferrous gluconate", "Colour retention agent", .none, "Iron salt that blackens olives. No concern.")
        add("585", "Ferrous lactate", "Colour retention agent", .none, "Iron salt that blackens olives. No concern.")

        // ----- Flavour enhancers (600–699) -----
        add("620", "Glutamic acid", "Flavour enhancer", .low, "The amino acid behind umami. Same considerations as MSG.")
        add("621", "Monosodium glutamate (MSG)", "Flavour enhancer", .low, "Sodium salt of glutamate, found naturally in parmesan and tomatoes. Regulators consider it safe; a small group reports headaches at large doses on an empty stomach.")
        add("622", "Monopotassium glutamate", "Flavour enhancer", .low, "Glutamate salt. Same considerations as MSG.")
        add("623", "Calcium glutamate", "Flavour enhancer", .low, "Glutamate salt. Same considerations as MSG.")
        add("624", "Monoammonium glutamate", "Flavour enhancer", .low, "Glutamate salt. Same considerations as MSG.")
        add("625", "Magnesium glutamate", "Flavour enhancer", .low, "Glutamate salt. Same considerations as MSG.")
        add("626", "Guanylic acid", "Flavour enhancer", .low, "Umami nucleotide. People with gout are advised to limit purines.")
        add("627", "Disodium guanylate", "Flavour enhancer", .low, "Umami booster usually paired with MSG; often from yeast but can be from fish. People with gout are advised to limit purines.")
        add("630", "Inosinic acid", "Flavour enhancer", .low, "Umami nucleotide. Purine; gout caution.")
        add("631", "Disodium inosinate", "Flavour enhancer", .low, "Umami booster usually from meat or fish, so often not vegetarian. Purine; gout caution.")
        add("635", "Disodium 5'-ribonucleotides", "Flavour enhancer", .low, "A blend of 627 and 631, in snack seasonings and instant noodles. Some skin-rash reports; purine, so gout caution.")
        add("636", "Maltol", "Flavour enhancer", .none, "Caramel-like flavour. No concern.")
        add("637", "Ethyl maltol", "Flavour enhancer", .none, "Sweet caramel-like flavour. No concern.")
        add("640", "Glycine", "Flavour modifier", .none, "An amino acid. No concern.")
        add("641", "L-leucine", "Flavour modifier", .none, "An amino acid. No concern.")

        // ----- Glazing agents, gases, flour treatments, sweeteners (900–999) -----
        add("900", "Dimethylpolysiloxane", "Anti-foaming agent", .none, "Silicone that stops frying oil foaming. Not absorbed; no concern.")
        add("901", "Beeswax", "Glazing agent", .none, "From bees, so not vegan. No safety concern.")
        add("902", "Candelilla wax", "Glazing agent", .none, "Plant wax. No concern.")
        add("903", "Carnauba wax", "Glazing agent", .none, "Palm-leaf wax that polishes sweets and fruit. No concern.")
        add("904", "Shellac", "Glazing agent", .none, "Resin secreted by the lac insect, so not vegan. No safety concern.")
        add("905", "Microcrystalline wax / paraffin", "Glazing agent", .low, "Petroleum-derived wax on confectionery. Low concern at food levels.")
        add("914", "Oxidised polyethylene wax", "Glazing agent", .low, "Synthetic fruit coating. Low concern.")
        add("920", "L-cysteine", "Flour treatment agent", .none, "Dough relaxer. Historically from feathers or hair, now usually fermentation; may not be vegan unless stated.")
        add("924", "Potassium bromate", "Flour treatment agent", .high, "Banned in the EU, UK, Canada, NZ and Australia as a possible carcinogen; still permitted in some US bread.")
        add("925", "Chlorine", "Flour treatment agent", .low, "Bleaches cake flour. Low concern.")
        add("926", "Chlorine dioxide", "Flour treatment agent", .low, "Bleaches flour. Low concern.")
        add("927a", "Azodicarbonamide", "Flour treatment agent", .high, "Dough conditioner banned in the EU, Australia and NZ; forms semicarbazide on baking. Still permitted in the US.")
        add("928", "Benzoyl peroxide", "Flour treatment agent", .low, "Bleaches flour, breaking down to benzoic acid. Low concern.")
        add("938", "Argon", "Packaging gas", .none, "Inert gas. No concern.")
        add("939", "Helium", "Packaging gas", .none, "Inert gas. No concern.")
        add("941", "Nitrogen", "Packaging gas", .none, "Keeps chip bags puffed and fresh. No concern.")
        add("942", "Nitrous oxide", "Propellant", .none, "Whipped-cream propellant. No concern in food.")
        add("943a", "Butane", "Propellant", .low, "Aerosol propellant. Low concern at food levels.")
        add("948", "Oxygen", "Packaging gas", .none, "No concern.")
        add("949", "Hydrogen", "Packaging gas", .none, "No concern.")
        add("950", "Acesulfame K", "Sweetener", .moderate, "Calorie-free sweetener usually blended with others. EFSA considers it safe; some animal studies suggest gut-microbiome effects, and a 2022 cohort linked it to cardiovascular risk.")
        add("951", "Aspartame", "Sweetener", .moderate, "Calorie-free sweetener. Classified by IARC in 2023 as possibly carcinogenic to humans, while the WHO's additive committee kept the existing safe intake. Must be avoided by people with phenylketonuria.")
        add("952", "Cyclamate", "Sweetener", .moderate, "Calorie-free sweetener banned in the US since 1970; permitted at limited levels in the EU, NZ and Australia.")
        add("953", "Isomalt", "Sweetener / bulking agent", .low, "Sugar alcohol in sugar-free sweets. Laxative in excess.")
        add("954", "Saccharin", "Sweetener", .low, "The oldest artificial sweetener. Earlier bladder-cancer findings in rats were ruled irrelevant to humans; now considered safe at the set limit.")
        add("955", "Sucralose", "Sweetener", .low, "Chlorinated sugar derivative. Considered safe by regulators; some evidence it may alter gut bacteria and break down at very high cooking temperatures.")
        add("956", "Alitame", "Sweetener", .low, "Rarely used intense sweetener. Low concern.")
        add("957", "Thaumatin", "Sweetener", .none, "Protein sweetener from a West African fruit. No concern.")
        add("959", "Neohesperidine DC", "Sweetener", .low, "Made from citrus peel. Low concern.")
        add("960", "Steviol glycosides", "Sweetener", .none, "Purified sweet compounds from the stevia plant. No concern.")
        add("961", "Neotame", "Sweetener", .low, "Very intense aspartame relative. Does not need a phenylketonuria warning; low concern.")
        add("962", "Aspartame-acesulfame salt", "Sweetener", .moderate, "A blend of 951 and 950; carries both sets of considerations and the phenylketonuria warning.")
        add("964", "Polyglycitol syrup", "Sweetener", .low, "Sugar alcohol blend. Laxative in excess.")
        add("965", "Maltitol", "Sweetener", .low, "Sugar alcohol in sugar-free chocolate. Well known for laxative effects; products must carry a warning.")
        add("966", "Lactitol", "Sweetener", .low, "Sugar alcohol made from milk sugar. Laxative in excess.")
        add("967", "Xylitol", "Sweetener", .low, "Sugar alcohol, good for teeth. Laxative in excess; highly toxic to dogs.")
        add("968", "Erythritol", "Sweetener", .low, "Sugar alcohol with almost no calories. Better tolerated than other polyols; a 2023 study associated high blood levels with cardiovascular events, which is under investigation.")
        add("969", "Advantame", "Sweetener", .low, "Very intense sweetener approved in 2014. Low concern.")

        // ----- Enzymes, improvers, starches, carriers (1100–1599) -----
        add("1100", "Amylases", "Flour treatment agent / enzyme", .none, "Enzymes that break down starch. No concern.")
        add("1101", "Proteases", "Enzyme", .none, "Protein-digesting enzymes (papain, bromelain). No concern.")
        add("1102", "Glucose oxidase", "Enzyme", .none, "No concern.")
        add("1103", "Invertase", "Enzyme", .none, "Softens fondant centres. No concern.")
        add("1104", "Lipase", "Enzyme", .none, "No concern.")
        add("1105", "Lysozyme", "Preservative / enzyme", .low, "Enzyme from egg white used in hard cheese and wine. An egg allergen; must be declared.")
        add("1200", "Polydextrose", "Bulking agent", .none, "Synthetic fibre used to cut sugar. Laxative in large amounts; otherwise no concern.")
        add("1201", "Polyvinylpyrrolidone", "Stabiliser", .low, "Synthetic polymer, mainly in supplements and sweeteners. Low concern.")
        add("1202", "Polyvinylpolypyrrolidone", "Stabiliser", .low, "Fines beer and wine; not absorbed. Low concern.")
        add("1203", "Polyvinyl alcohol", "Glazing agent", .low, "Coating on supplements. Low concern.")
        add("1204", "Pullulan", "Glazing agent", .none, "Fermentation-derived polysaccharide. No concern.")
        add("1400", "Dextrin", "Thickener", .none, "Roasted starch. No concern.")
        add("1401", "Acid-treated starch", "Thickener", .none, "Modified starch. No concern.")
        add("1402", "Alkaline-treated starch", "Thickener", .none, "Modified starch. No concern.")
        add("1403", "Bleached starch", "Thickener", .none, "Modified starch. No concern.")
        add("1404", "Oxidised starch", "Thickener", .none, "Modified starch. No concern.")
        add("1405", "Enzyme-treated starch", "Thickener", .none, "Modified starch. No concern.")
        add("1410", "Monostarch phosphate", "Thickener", .none, "Modified starch. No concern.")
        add("1412", "Distarch phosphate", "Thickener", .none, "Modified starch. No concern.")
        add("1413", "Phosphated distarch phosphate", "Thickener", .none, "Modified starch. No concern.")
        add("1414", "Acetylated distarch phosphate", "Thickener", .none, "Modified starch. No concern.")
        add("1420", "Acetylated starch", "Thickener", .none, "Modified starch. No concern.")
        add("1422", "Acetylated distarch adipate", "Thickener", .none, "The modified starch in most instant sauces and yoghurts. No concern.")
        add("1440", "Hydroxypropyl starch", "Thickener", .none, "Modified starch. No concern.")
        add("1442", "Hydroxypropyl distarch phosphate", "Thickener", .none, "Freeze-stable modified starch in ready meals and dairy desserts. No concern.")
        add("1450", "Starch sodium octenyl succinate", "Emulsifier / thickener", .none, "Modified starch that carries flavour oils. No concern.")
        add("1451", "Acetylated oxidised starch", "Thickener", .none, "Modified starch. No concern.")
        add("1452", "Starch aluminium octenyl succinate", "Carrier", .low, "Modified starch that adds a little aluminium; mainly in supplements.")
        add("1505", "Triethyl citrate", "Carrier / foaming agent", .none, "Citric acid ester used in egg-white powder. No concern.")
        add("1510", "Ethanol", "Carrier solvent", .none, "Alcohol used to carry flavours; mostly evaporates. No concern at food levels.")
        add("1517", "Glyceryl diacetate", "Carrier solvent", .none, "Flavour carrier. No concern.")
        add("1518", "Glyceryl triacetate (triacetin)", "Carrier solvent", .none, "Flavour carrier. No concern.")
        add("1519", "Benzyl alcohol", "Carrier solvent", .low, "Flavour carrier. Low concern at food levels.")
        add("1520", "Propylene glycol", "Carrier solvent / humectant", .low, "Carries flavours and keeps food moist. Safe at food levels, though the EU limits it more tightly than the US.")
        add("1521", "Polyethylene glycol", "Carrier", .low, "Coating on supplements and sweeteners. Low concern.")

        return t
    }()
}
