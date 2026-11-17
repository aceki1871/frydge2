import SwiftUI

// MARK: - Cookbook theme

/// Shared look for the recipes section: warm paper, ink-coloured type and
/// system-font headings, so the recipe list and recipe pages read like a printed
/// cookbook rather than a feed of glass cards. Every colour adapts to the
/// system appearance (cream paper by day, warm charcoal paper at night).
enum CookbookTheme {

    // MARK: Colours

    /// Page background behind everything.
    static let paper = dynamic(
        light: Color(red: 0.965, green: 0.935, blue: 0.880),
        dark: Color(red: 0.125, green: 0.108, blue: 0.092)
    )

    /// Slightly deeper paper used for the gradient edge and margins.
    static let paperDeep = dynamic(
        light: Color(red: 0.915, green: 0.875, blue: 0.805),
        dark: Color(red: 0.085, green: 0.075, blue: 0.065)
    )

    /// Surface of an individual recipe page / card.
    static let card = dynamic(
        light: Color(red: 0.995, green: 0.982, blue: 0.955),
        dark: Color(red: 0.175, green: 0.155, blue: 0.135)
    )

    /// Primary text.
    static let ink = dynamic(
        light: Color(red: 0.165, green: 0.125, blue: 0.095),
        dark: Color(red: 0.930, green: 0.895, blue: 0.830)
    )

    /// Secondary text (meta lines, captions).
    static var inkSecondary: Color { ink.opacity(0.64) }

    /// Hairlines and borders.
    static var rule: Color { ink.opacity(0.18) }

    /// Burgundy accent for the few active controls (filters, add buttons).
    static let accent = dynamic(
        light: Color(red: 0.545, green: 0.170, blue: 0.170),
        dark: Color(red: 0.850, green: 0.440, blue: 0.410)
    )

    // MARK: Type

    /// "Recipes" on the book's title page.
    static let bookTitleFont = Font.system(.title).weight(.bold)

    /// Chapter titles ("Chicken", "Seafood") and the Contents heading.
    static let chapterTitleFont = Font.system(.title).weight(.semibold)

    /// Small-caps running heads: "CHAPTER ONE", "FRYDGE".
    static let runningHeadFont = Font.system(.caption).weight(.semibold).smallCaps()

    /// Recipe name on a card.
    static let recipeTitleFont = Font.system(.title3).weight(.semibold)

    /// Recipe name on its own page.
    static let recipePageTitleFont = Font.system(.title).weight(.bold)

    /// Section titles on a recipe page ("Ingredients", "Instructions").
    static let sectionTitleFont = Font.system(.title2).weight(.semibold)

    /// Italic meta lines: "Serves 4 · 35 min".
    static let metaFont = Font.system(.footnote).italic()

    /// Small captions.
    static let captionFont = Font.system(.caption)

    /// Body copy in serif (contents list entries).
    static let bodyFont = Font.system(.body)

    // MARK: Helpers

    /// "One", "Two", … for chapter headings; falls back to digits past twelve.
    static func numeral(_ n: Int) -> String {
        let words = ["One", "Two", "Three", "Four", "Five", "Six",
                     "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve"]
        guard n >= 1, n <= words.count else { return "\(n)" }
        return words[n - 1]
    }

    private static func dynamic(light: Color, dark: Color) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

// MARK: - Background

/// Soft paper gradient with a faint vignette at the edges, like an open book
/// lying flat. Used behind the recipe list and the recipe page.
struct CookbookBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [CookbookTheme.paper, CookbookTheme.paperDeep],
                startPoint: .top,
                endPoint: .bottom
            )
            // Edge vignette: slightly darker margins pull the eye inwards.
            RadialGradient(
                colors: [Color.clear, CookbookTheme.paperDeep.opacity(0.55)],
                center: .center,
                startRadius: 180,
                endRadius: 900
            )
        }
    }
}

// MARK: - Rules and leaders

/// Thin printed rule, optionally tinted to the chapter colour.
struct CookbookRule: View {
    var tint: Color = CookbookTheme.rule
    var thickness: CGFloat = 1

    var body: some View {
        Rectangle()
            .fill(tint)
            .frame(height: thickness)
            .frame(maxWidth: .infinity)
    }
}

/// Dotted leader between a contents entry and its chapter number.
struct CookbookLeader: View {
    var body: some View {
        LeaderLine()
            .stroke(CookbookTheme.rule, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.1, 5]))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
    }

    private struct LeaderLine: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

/// Centred ornament between two rules: ——— ❧ ———
struct CookbookOrnament: View {
    var symbol: String = "❧"

    var body: some View {
        HStack(spacing: 12) {
            CookbookRule()
            Text(symbol)
                .font(.system(.footnote))
                .foregroundStyle(CookbookTheme.inkSecondary)
            CookbookRule()
        }
    }
}

// MARK: - Page card

/// Card drawn as a sheet of paper: pale surface, hairline edge, soft lift.
private struct CookbookPageModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(CookbookTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(CookbookTheme.rule, lineWidth: 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.10), radius: 10, x: 0, y: 5)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.05), radius: 1.5, x: 0, y: 1)
    }
}

extension View {
    /// Styles a view as a page of the cookbook (see `CookbookPageModifier`).
    func cookbookPage(cornerRadius: CGFloat = 12) -> some View {
        modifier(CookbookPageModifier(cornerRadius: cornerRadius))
    }
}

#Preview("Cookbook pieces") {
    ZStack {
        CookbookBackground().ignoresSafeArea()
        VStack(alignment: .leading, spacing: 16) {
            Text("Frydge").font(CookbookTheme.runningHeadFont).tracking(3)
            Text("Recipes").font(CookbookTheme.bookTitleFont)
            CookbookOrnament()
            Text("Chapter One").font(CookbookTheme.runningHeadFont).tracking(2)
            Text("Chicken").font(CookbookTheme.chapterTitleFont)
            HStack {
                Text("Seafood").font(CookbookTheme.bodyFont)
                CookbookLeader()
                Text("Five").font(CookbookTheme.metaFont)
            }
            Text("Serves 4 · 35 min").font(CookbookTheme.metaFont).foregroundStyle(CookbookTheme.inkSecondary)
        }
        .foregroundStyle(CookbookTheme.ink)
        .padding(24)
        .cookbookPage()
        .padding()
    }
}
