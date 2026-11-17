import SwiftUI

// MARK: - Notepad theme

/// Palette and building blocks for the shopping list's notepad look: warm
/// flat paper, hairline rules, a clean tick-box column and rounded type.
/// Deliberately restrained: the "paper" is a mood, not a skeuomorph.
enum NotepadTheme {
    /// Width of the leading column that holds the tick boxes.
    static let marginWidth: CGFloat = 48

    static func paper(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.11, green: 0.11, blue: 0.10)
            : Color(red: 0.985, green: 0.975, blue: 0.95)
    }

    static func rule(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.09)
            : Color.black.opacity(0.07)
    }

    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(white: 0.94)
            : Color(red: 0.13, green: 0.12, blue: 0.11)
    }

    static func fadedInk(_ scheme: ColorScheme) -> Color {
        ink(scheme).opacity(0.45)
    }

    /// Accent used for ticks and interactive bits on the page.
    static let accent = Color.blue

    /// Rounded system type gives the friendly notebook feel while staying
    /// crisp and fully Dynamic Type aware.
    static func noteFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .rounded).weight(weight)
    }
}

// MARK: - Paper background

struct NotepadPaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NotepadTheme.paper(scheme)
    }
}

// MARK: - Rows & headings

/// A hairline rule inset to start at the text column, like a modern lined note.
struct NotepadRule: View {
    @Environment(\.colorScheme) private var scheme
    var leadingInset: CGFloat = NotepadTheme.marginWidth

    var body: some View {
        Rectangle()
            .fill(NotepadTheme.rule(scheme))
            .frame(height: 1)
            .padding(.leading, leadingInset)
    }
}

private struct NotepadRowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { NotepadRule() }
    }
}

extension View {
    /// Lays the view on a ruled notepad line (rule drawn along the bottom edge).
    func notepadRow() -> some View {
        modifier(NotepadRowModifier())
    }

    /// Floating glass surface for banners and toasts sitting on the paper.
    func notepadGlass(cornerRadius: CGFloat = 18) -> some View {
        // Deployment target is iOS 27, so Liquid Glass is always available.
        self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

/// Empty ruled lines used to fill the rest of a page.
struct NotepadBlankLines: View {
    var count: Int = 10
    var lineHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                Color.clear
                    .frame(height: lineHeight)
                    .overlay(alignment: .bottom) { NotepadRule() }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Section heading with an optional item count pill.
struct NotepadHeading: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var count: Int? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(NotepadTheme.noteFont(.title2, weight: .bold))
                .foregroundStyle(NotepadTheme.ink(scheme))

            if let count, count > 0 {
                Text("\(count)")
                    .font(NotepadTheme.noteFont(.caption, weight: .semibold))
                    .foregroundStyle(NotepadTheme.fadedInk(scheme))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(NotepadTheme.rule(scheme), in: Capsule())
            }
        }
    }
}

/// Round tick box, Reminders-style, that sits in the leading column.
struct NotepadCheckbox: View {
    @Environment(\.colorScheme) private var scheme
    let isChecked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(
                        isChecked ? NotepadTheme.accent : NotepadTheme.ink(scheme).opacity(0.3),
                        lineWidth: 1.5
                    )

                if isChecked {
                    Circle()
                        .fill(NotepadTheme.accent)
                        .transition(.scale.combined(with: .opacity))
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 24, height: 24)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isChecked)
        .accessibilityLabel(isChecked ? "Checked" : "Not checked")
    }
}
