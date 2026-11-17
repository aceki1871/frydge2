//
//  RecipeStep.swift
//  FrydgeRecipes
//
//  Updated: structured steps.
//  All new fields are optional and decoded with `decodeIfPresent`, so every
//  existing `stepsJSON` payload in CloudKit still decodes cleanly.
//

import Foundation

struct RecipeStep: Identifiable, Codable, Hashable {

    // MARK: - Existing

    var id: UUID
    var text: String
    var timerSeconds: Int?
    var temperatureValue: Int?
    var temperatureUnit: String?
    var mediaURLString: String?

    // MARK: - New: structure

    /// What the cook physically does. Drives the animation.
    var action: CookAction?

    /// Ingredient names this step touches. Matched loosely against
    /// `CloudRecipe.ingredients` so reordering / rewording won't break it.
    var ingredientRefs: [String]

    /// What it happens in / on.
    var vessel: Vessel?

    /// Hob heat (only meaningful when `action?.usesHeat == true`).
    var heat: HeatLevel?

    /// Free-text qualifier appended to generated text, e.g. "until golden".
    var note: String?

    // MARK: - Init

    init(
        id: UUID = UUID(),
        text: String = "",
        timerSeconds: Int? = nil,
        mediaURLString: String? = nil,
        temperatureValue: Int? = nil,
        temperatureUnit: String? = nil,
        action: CookAction? = nil,
        ingredientRefs: [String] = [],
        vessel: Vessel? = nil,
        heat: HeatLevel? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.text = text
        self.timerSeconds = timerSeconds
        self.mediaURLString = mediaURLString
        self.temperatureValue = temperatureValue
        self.temperatureUnit = temperatureUnit
        self.action = action
        self.ingredientRefs = ingredientRefs
        self.vessel = vessel
        self.heat = heat
        self.note = note
    }

    // MARK: - Codable (tolerant of legacy payloads)

    enum CodingKeys: String, CodingKey {
        case id, text, timerSeconds, temperatureValue, temperatureUnit, mediaURLString
        case action, ingredientRefs, vessel, heat, note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text              = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.timerSeconds      = try c.decodeIfPresent(Int.self, forKey: .timerSeconds)
        self.temperatureValue  = try c.decodeIfPresent(Int.self, forKey: .temperatureValue)
        self.temperatureUnit   = try c.decodeIfPresent(String.self, forKey: .temperatureUnit)
        self.mediaURLString    = try c.decodeIfPresent(String.self, forKey: .mediaURLString)
        self.action            = try c.decodeIfPresent(CookAction.self, forKey: .action)
        self.ingredientRefs    = try c.decodeIfPresent([String].self, forKey: .ingredientRefs) ?? []
        self.vessel            = try c.decodeIfPresent(Vessel.self, forKey: .vessel)
        self.heat              = try c.decodeIfPresent(HeatLevel.self, forKey: .heat)
        self.note              = try c.decodeIfPresent(String.self, forKey: .note)
    }

    // MARK: - Derived

    var hasTimer: Bool { (timerSeconds ?? 0) > 0 }

    var hasTemperature: Bool {
        guard let v = temperatureValue, v > 0 else { return false }
        return !(temperatureUnit ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True once the step carries enough structure to animate.
    var isStructured: Bool { action != nil }

    var timerDisplay: String? {
        guard let s = timerSeconds, s > 0 else { return nil }
        return Self.formatDuration(s)
    }

    var temperatureDisplay: String? {
        guard hasTemperature, let v = temperatureValue else { return nil }
        let u = (temperatureUnit ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(v)\(u)"
    }

    static func formatDuration(_ totalSeconds: Int) -> String {
        let s = max(0, totalSeconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return sec > 0 ? "\(m)m \(sec)s" : "\(m)m" }
        return "\(sec)s"
    }

    // MARK: - Text generation
    //
    // The whole point: authors pick chips, we write the sentence.
    // `text` remains an author override — if they typed something, we respect it.

    var generatedText: String {
        guard let action else { return text }

        var parts: [String] = [action.verb]

        if !ingredientRefs.isEmpty {
            parts.append(Self.humanList(ingredientRefs))
        }

        if let vessel, vesselDeservesMention {
            switch vessel {
            case .oven, .fridge, .freezer, .grill:
                parts.append("in the \(vessel.title.lowercased())")
            case .board:
                parts.append("on a board")
            case .plate:
                parts.append("onto a plate")
            default:
                parts.append("in a \(vessel.title.lowercased())")
            }
        }

        if let heat, action.usesHeat {
            parts.append("over \(heat.title.lowercased()) heat")
        }

        if let t = temperatureDisplay, action.usesTemperature {
            parts.append("at \(t)")
        }

        if let s = timerSeconds, s > 0 {
            parts.append("for \(Self.formatDuration(s))")
        }

        if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(note.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return parts.joined(separator: " ") + "."
    }

    /// What the UI should actually show.
    var displayText: String {
        let manual = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return manual }
        return generatedText
    }

    /// Short label for cook mode / timers.
    var shortTitle: String {
        if let action {
            if ingredientRefs.isEmpty { return action.title }
            return "\(action.title) \(ingredientRefs[0])"
        }
        let firstSentence = text.split(separator: ".").first.map(String.init) ?? text
        return String(firstSentence.prefix(40))
    }

    private var vesselDeservesMention: Bool {
        guard let vessel, let action else { return false }
        return vessel != action.defaultVessel || action.group == .heat
    }

    private static func humanList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
