//
//  CookAction.swift
//  FrydgeRecipes
//
//  The structured verb vocabulary. This is the key that unlocks animation,
//  reliable import, and chip-based authoring.
//

import SwiftUI

// MARK: - Animation primitive

/// ~12 reusable motions cover ~40 cooking verbs.
/// Add a verb -> map it to an existing primitive -> it animates for free.
enum AnimationPrimitive: String, Codable, Sendable {
    case knife, stir, whisk, pour, heat, bubble, oven, wait, sprinkle, flip, blend, plate
}

// MARK: - Vessel

enum Vessel: String, Codable, CaseIterable, Identifiable, Sendable {
    case board, bowl, pan, pot, tray, oven, blender, fridge, freezer, plate, grill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .board:   return "Chopping board"
        case .bowl:    return "Bowl"
        case .pan:     return "Pan"
        case .pot:     return "Pot"
        case .tray:    return "Baking tray"
        case .oven:    return "Oven"
        case .blender: return "Blender"
        case .fridge:  return "Fridge"
        case .freezer: return "Freezer"
        case .plate:   return "Plate"
        case .grill:   return "Grill"
        }
    }

    var symbol: String {
        switch self {
        case .board:   return "square.split.bottomrightquarter"
        case .bowl:    return "circle.bottomhalf.filled"
        case .pan:     return "frying.pan"
        case .pot:     return "cup.and.saucer"
        case .tray:    return "rectangle.portrait"
        case .oven:    return "oven"
        case .blender: return "tornado"
        case .fridge:  return "refrigerator"
        case .freezer: return "snowflake"
        case .plate:   return "circle"
        case .grill:   return "flame"
        }
    }
}

// MARK: - Heat

enum HeatLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case low, medium, high

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var tint: Color {
        switch self {
        case .low:    return .orange.opacity(0.55)
        case .medium: return .orange
        case .high:   return .red
        }
    }

    /// Drives animation speed for heat-based primitives.
    var intensity: Double {
        switch self {
        case .low:    return 0.55
        case .medium: return 1.0
        case .high:   return 1.7
        }
    }
}

// MARK: - Cook action

enum CookAction: String, Codable, CaseIterable, Identifiable, Sendable {

    // Prep
    case chop, slice, dice, mince, grate, peel, crush, trim

    // Combine
    case mix, stir, whisk, fold, toss, knead, blend, coat

    // Heat
    case saute, fry, sear, boil, simmer, steam, bake, roast, grill, reduce, flip, warm

    // Cold / wait
    case chill, freeze, marinate, rest, proof, thaw

    // Finish
    case season, garnish, drain, pour, add, plate, serve

    var id: String { rawValue }

    // MARK: Grouping (for the editor's chip picker)

    enum Group: String, CaseIterable, Identifiable {
        case prep = "Prep"
        case combine = "Combine"
        case heat = "Heat"
        case wait = "Wait"
        case finish = "Finish"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .prep:    return "scissors"
            case .combine: return "arrow.trianglehead.2.clockwise"
            case .heat:    return "flame"
            case .wait:    return "clock"
            case .finish:  return "sparkles"
            }
        }
    }

    var group: Group {
        switch self {
        case .chop, .slice, .dice, .mince, .grate, .peel, .crush, .trim:
            return .prep
        case .mix, .stir, .whisk, .fold, .toss, .knead, .blend, .coat:
            return .combine
        case .saute, .fry, .sear, .boil, .simmer, .steam, .bake, .roast, .grill, .reduce, .flip, .warm:
            return .heat
        case .chill, .freeze, .marinate, .rest, .proof, .thaw:
            return .wait
        case .season, .garnish, .drain, .pour, .add, .plate, .serve:
            return .finish
        }
    }

    static func actions(in group: Group) -> [CookAction] {
        allCases.filter { $0.group == group }
    }

    // MARK: Display

    var title: String {
        switch self {
        case .saute: return "Sauté"
        default:     return rawValue.capitalized
        }
    }

    /// Imperative verb used when generating step text.
    var verb: String { title }

    var symbol: String {
        switch self {
        case .chop, .slice, .dice, .mince, .trim: return "scissors"
        case .grate:            return "square.grid.3x3"
        case .peel:             return "leaf"
        case .crush:            return "hammer"
        case .mix, .stir, .fold, .toss, .coat: return "arrow.trianglehead.2.clockwise"
        case .whisk:            return "tornado"
        case .knead:            return "hands.and.sparkles"
        case .blend:            return "tornado"
        case .saute, .fry, .sear, .grill, .warm: return "flame"
        case .boil, .simmer, .reduce: return "bubbles.and.sparkles"
        case .steam:            return "humidity"
        case .bake, .roast:     return "oven"
        case .flip:             return "arrow.2.squarepath"
        case .chill:            return "thermometer.snowflake"
        case .freeze:           return "snowflake"
        case .marinate:         return "drop"
        case .rest, .proof, .thaw: return "clock"
        case .season:           return "sparkles"
        case .garnish:          return "leaf.fill"
        case .drain:            return "drop.triangle"
        case .pour:             return "drop.fill"
        case .add:              return "plus.circle"
        case .plate, .serve:    return "fork.knife"
        }
    }

    // MARK: Animation

    var primitive: AnimationPrimitive {
        switch self {
        case .chop, .slice, .dice, .mince, .trim, .peel, .crush, .grate:
            return .knife
        case .mix, .stir, .fold, .toss, .coat, .knead:
            return .stir
        case .whisk:
            return .whisk
        case .blend:
            return .blend
        case .saute, .fry, .sear, .grill, .warm, .reduce:
            return .heat
        case .boil, .simmer, .steam:
            return .bubble
        case .bake, .roast:
            return .oven
        case .flip:
            return .flip
        case .chill, .freeze, .rest, .proof, .thaw, .marinate:
            return .wait
        case .season, .garnish:
            return .sprinkle
        case .pour, .drain, .add:
            return .pour
        case .plate, .serve:
            return .plate
        }
    }

    // MARK: Defaults (used to pre-fill the editor)

    var defaultVessel: Vessel {
        switch self {
        case .chop, .slice, .dice, .mince, .trim, .peel, .crush, .grate: return .board
        case .mix, .whisk, .fold, .toss, .coat, .knead:                  return .bowl
        case .blend:                                                     return .blender
        case .saute, .fry, .sear, .flip, .warm, .stir:                   return .pan
        case .boil, .simmer, .steam, .reduce, .drain:                    return .pot
        case .bake, .roast:                                              return .oven
        case .grill:                                                     return .grill
        case .chill, .marinate, .proof, .thaw:                           return .fridge
        case .freeze:                                                    return .freezer
        case .season, .garnish, .pour, .add, .rest:                      return .bowl
        case .plate, .serve:                                             return .plate
        }
    }

    var usesHeat: Bool {
        switch self {
        case .saute, .fry, .sear, .boil, .simmer, .steam, .grill, .reduce, .warm, .flip:
            return true
        default:
            return false
        }
    }

    var usesTemperature: Bool {
        switch self {
        case .bake, .roast, .proof: return true
        default: return false
        }
    }

    /// Sensible starting timer (seconds) so authoring is one tap, not typing.
    var suggestedSeconds: Int? {
        switch self {
        case .saute, .fry:      return 5 * 60
        case .sear:             return 2 * 60
        case .boil:             return 10 * 60
        case .simmer, .reduce:  return 20 * 60
        case .steam:            return 8 * 60
        case .bake, .roast:     return 30 * 60
        case .grill:            return 6 * 60
        case .knead:            return 8 * 60
        case .rest:             return 10 * 60
        case .chill:            return 30 * 60
        case .marinate:         return 60 * 60
        case .proof:            return 90 * 60
        default:                return nil
        }
    }
}
