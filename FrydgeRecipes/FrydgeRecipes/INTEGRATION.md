# Structured Steps — integration

## Files

| File | Action |
|---|---|
| `CookAction.swift` | **New** |
| `RecipeStep.swift` | **Replaces** existing (backwards compatible) |
| `StepInference.swift` | **New** |
| `StepAnimationView.swift` | **New** |
| `CookModeView.swift` | **New** |
| `StepBuilderView.swift` | **New** |

No CloudKit schema change. Steps already persist via `stepsJSON`; the new fields
decode with `decodeIfPresent`, so old payloads still load.

## 1. RecipeDetailView

Add state + a Cook button, and swap the step row text.

```swift
@State private var showCookMode = false
```

Above `stepsView`, replace the plain "Instructions" header block with:

```swift
HStack {
    Text("Instructions").font(.title2).fontWeight(.semibold)
    Spacer()
    Button {
        showCookMode = true
    } label: {
        Label("Cook", systemImage: "play.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(Color.blue))
            .foregroundStyle(.white)
    }
}
Divider().opacity(0.25)
```

Attach to the same view that holds your other sheets:

```swift
.fullScreenCover(isPresented: $showCookMode) {
    CookModeView(recipe: recipe)
}
```

In `stepsView`, add a thumbnail animation and use `displayText`:

```swift
HStack(alignment: .top, spacing: 10) {
    Text("\(idx + 1).").font(.subheadline).foregroundColor(.secondary)

    if step.action != nil {
        StepAnimationView(step: step)
            .frame(width: 56, height: 56)
    }

    Text(step.displayText).foregroundColor(.primary)   // was step.text
    Spacer()
}
```

Also delete the legacy fallback branch and replace with:

```swift
if !recipe.steps.isEmpty {
    stepsView
} else if !recipe.instructions.isEmpty {
    // legacy prose -> structured on the fly
    let inferred = StepInference.steps(fromInstructions: recipe.instructions,
                                       ingredients: recipe.ingredients)
    // render `inferred` with the same row builder
}
```

## 2. Import (the "cleaner recipes" fix)

`RecipeImportManager.makeDraft(...)` currently produces an `instructions` string.
Add structured steps alongside it:

```swift
let instructions = extractInstructions(fromRecipeObject: recipe)
let steps = StepInference.steps(
    fromInstructions: instructions,
    ingredients: ingredients.map { $0.asAppIngredientLine() }
)
```

Same call in `RecipeImportOCRParser.extractInstructions` — feed the joined
result into `StepInference.steps(fromInstructions:ingredients:)` instead of
returning a numbered string.

Then in `RecipeEditorView`, when seeding from `importDraft`, set
`steps = draft.steps` and let the user confirm chips rather than retype prose.

## 3. Editor

Replace the free-text step composer (`stepText` / `addStep()` block) with:

```swift
StepBuilderView(availableIngredients: ingredients) { newStep in
    steps.append(newStep)
}
```

Keep your existing reorder/delete list below it. Rows should render
`step.displayText`.

## 4. Backfill existing recipes

One-off, wherever you load recipes:

```swift
recipe.steps = StepInference.enrich(recipe.steps, ingredients: recipe.ingredients)
```

Idempotent — skips any step that already has an `action`.

## Extending

Adding a verb is three lines:

1. Add the case to `CookAction`
2. Map it in `primitive`, `defaultVessel`, `symbol`
3. Add synonyms to `StepInference.verbMap`

It animates immediately — no new artwork.
