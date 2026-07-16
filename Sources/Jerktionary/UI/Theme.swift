import SwiftUI

/// Journal-style design tokens: a soft neutral canvas, floating white cards
/// with diffuse shadows instead of borders, one lavender-indigo tint, and
/// spacing (not hairlines) as the separator. Semantic NSColors keep both
/// appearances correct automatically.
enum Theme {
    /// Soft light canvas behind everything (Journal's grouped background).
    /// windowBackgroundColor: light warm gray in light mode, proper dark in dark —
    /// NOT underPageBackgroundColor, which on macOS is a mid-gray void.
    static let canvas = Color(nsColor: .windowBackgroundColor)
    /// Elevated card surface: white in light, raised gray in dark.
    static let card = Color(nsColor: .controlBackgroundColor)
    /// The single interactive tint — Journal's lavender-indigo.
    static let tint = Color.indigo

    static let cardRadius: CGFloat = 16
    static let fieldRadius: CGFloat = 10

    /// Diffuse resting shadow for cards (never paired with a border).
    static let shadowColor = Color.black.opacity(0.05)

    /// Journal's lavender gradient for the highlight card (Insights-style).
    static let lavenderGradient = LinearGradient(
        colors: [
            Color(red: 0.66, green: 0.60, blue: 0.95),
            Color(red: 0.55, green: 0.47, blue: 0.93)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// The faint pink-lavender wash Journal paints over the content area.
    /// Practically invisible in dark mode by design (low opacity over dark).
    static let contentWash = LinearGradient(
        colors: [Theme.tint.opacity(0.0), Theme.tint.opacity(0.05)],
        startPoint: .top,
        endPoint: .bottom
    )
}

/// Round white toolbar button, like Journal's "+" circle.
struct CircleToolbarButton: View {
    let systemImage: String
    var active = false
    var help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Theme.tint : Color.primary.opacity(0.75))
                .frame(width: 30, height: 30)
                .background(Theme.card, in: Circle())
                .shadow(color: Theme.shadowColor, radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension View {
    /// Journal entry card: generous padding, continuous corners, soft shadow, no border.
    func journalCard(padding: CGFloat = 18) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Theme.card,
                in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            )
            .shadow(color: Theme.shadowColor, radius: 6, y: 1)
    }

    /// Tinted prompt card (Journal's "reflection" pastel): a white card with a
    /// light indigo wash on top, so the pastel stays clean in both appearances.
    func journalPromptCard(padding: CGFloat = 18) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .fill(Theme.tint.opacity(0.07))
                    )
            )
            .shadow(color: Theme.shadowColor, radius: 6, y: 1)
    }
}

/// Quiet toolbar icon button: plain SF Symbol, tint only when active.
struct ToolbarIconButton: View {
    let systemImage: String
    var active = false
    var help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? Theme.tint : Color.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
