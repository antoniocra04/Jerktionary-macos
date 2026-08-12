import AppKit
import SwiftUI

/// The card that floats over a live call.
///
/// Hosted in a floating panel with no title bar and a cleared background (see
/// OverlayPanel), so this view draws the whole card: the material, the rounded
/// edge, and the drag surface that replaces the title bar.
///
/// Everything here answers to one scene: the user is speaking while reading.
/// That rules out anything that moves the text under their eye, anything that
/// needs a steady hover, and anything that requires noticing an absence.
struct OverlayView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var chats: ChatStore
    @EnvironmentObject private var answers: AnswerStreamManager

    /// The question on screen. Held so a newly detected question cannot replace
    /// the answer being read aloud mid-sentence.
    @State private var pinned: String?
    /// Newest question already seen on the answer pane, so the tab can show that
    /// something arrived while another pane was open.
    @State private var seen: String?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var questions: [String] { store.answeredQuestions }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().opacity(0.5)
            if let fault = store.overlayFault {
                faultStrip(fault)
            }
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                // Carries the card's edge against a light desktop too, where a
                // white hairline measured 1.02:1 and left no boundary at all.
                .strokeBorder(.primary.opacity(0.14), lineWidth: 1)
        )
        .ignoresSafeArea()
        .onChange(of: questions.first) { previous, current in
            followOrPin(previous: previous, current: current)
        }
        .onChange(of: settings.overlayPane) {
            if settings.overlayPane == .answer { seen = questions.first }
        }
        .onAppear { seen = questions.first }
    }

    /// Transparency lives in the background, never in the text. Fading the whole
    /// panel took the answer itself to ~1.5:1 at the low end of this same slider.
    @ViewBuilder
    private var cardBackground: some View {
        if reduceTransparency {
            Theme.canvas
        } else {
            Rectangle().fill(.ultraThinMaterial).opacity(settings.overlayOpacity)
        }
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(spacing: 6) {
            StatusLight(state: store.overlayStatus)

            PaneTabs(selection: paneBinding, badged: badgedPane)
                .layoutPriority(1)

            Spacer(minLength: 2)

            OpacityControl(opacity: $settings.overlayOpacity)

            OverlayIconButton(
                systemImage: store.contentProtectionEnabled ? "eye.slash" : "eye",
                label: store.contentProtectionEnabled
                    ? "Скрыто от захвата экрана"
                    : "Видно при захвате экрана — нажмите, чтобы скрыть",
                tint: store.contentProtectionEnabled ? .secondary : .orange
            ) {
                store.contentProtectionEnabled.toggle()
                WindowController.setContentProtection(store.contentProtectionEnabled)
            }

            OverlayIconButton(
                systemImage: "arrow.up.left.and.arrow.down.right",
                label: "Развернуть в обычное окно"
            ) {
                store.toggleOverlay()
            }

            OverlayIconButton(
                systemImage: "xmark",
                label: "Спрятать карточку. Вернуть — Ctrl+Shift+O"
            ) {
                store.hideOverlay()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // The panel is movable by its background; this keeps the gaps between
        // controls behaving like the title bar they replace.
        .contentShape(Rectangle())
    }

    /// Which tab should show that something arrived behind the user's back.
    private var badgedPane: OverlayPane? {
        guard settings.overlayPane != .answer,
              let newest = questions.first, newest != seen
        else { return nil }
        return .answer
    }

    private func faultStrip(_ fault: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(fault)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.16))
        .accessibilityElement(children: .combine)
    }

    // MARK: Panes

    @ViewBuilder
    private var pane: some View {
        switch settings.overlayPane {
        case .answer:
            answerPane
        case .chat:
            chatPane
        case .transcript:
            transcriptPane
        }
    }

    // MARK: Answer

    /// The question actually on screen, falling back to the newest once a pinned
    /// one ages out of the eight the store keeps.
    private var shown: String? {
        if let pinned, questions.contains(pinned) { return pinned }
        return questions.first
    }

    private var shownIndex: Int {
        shown.flatMap { questions.firstIndex(of: $0) } ?? 0
    }

    @ViewBuilder
    private var answerPane: some View {
        if let shown {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    AnswerCardView(question: shown, compact: true)
                        // Without this the card keeps its @State across a change
                        // of question: "Подробнее" left on hid the next answer
                        // behind a spinner even though it was already cached.
                        .id(shown)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .scrollContentBackground(.hidden)

                if questions.count > 1 {
                    answerPager
                }
            }
        } else {
            hint(
                store.isListening
                    ? "Слушаю. Ответ появится, когда прозвучит вопрос"
                    : "Ctrl+Shift+Space — ответить сейчас, Ctrl+Shift+O — свернуть",
                icon: "sparkles"
            )
        }
    }

    private var answerPager: some View {
        HStack(spacing: 8) {
            if shownIndex > 0 {
                // The point of the whole pinning dance: a newer answer announces
                // itself instead of replacing the sentence being spoken.
                Button {
                    pinned = nil
                    seen = questions.first
                } label: {
                    Label("Новый ответ", systemImage: "arrow.up.circle.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tint)
            } else {
                Text("последний вопрос")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text("\(questions.count - shownIndex) из \(questions.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            OverlayIconButton(systemImage: "chevron.left", label: "Более старый вопрос") {
                move(+1)
            }
            .disabled(shownIndex >= questions.count - 1)
            .keyboardShortcut(.leftArrow, modifiers: [])

            OverlayIconButton(systemImage: "chevron.right", label: "Более новый вопрос") {
                move(-1)
            }
            .disabled(shownIndex <= 0)
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.primary.opacity(0.04))
    }

    private func move(_ delta: Int) {
        guard !questions.isEmpty else { return }
        let target = min(max(shownIndex + delta, 0), questions.count - 1)
        pinned = target == 0 ? nil : questions[target]
        if target == 0 { seen = questions.first }
    }

    /// A question arriving must not take the screen away from an answer being
    /// read. A card with nothing on it yet has nothing to protect, so that one
    /// still follows live.
    private func followOrPin(previous: String?, current: String?) {
        guard let previous, previous != current else { return }
        if pinned == nil, answers.state(question: previous, deep: false).answer != nil {
            pinned = previous
        }
        if settings.overlayPane == .answer, pinned == nil {
            seen = current
        }
    }

    // MARK: Chat and transcript

    @ViewBuilder
    private var chatPane: some View {
        if let id = chats.selectedID, chats.conversation(id: id) != nil {
            ChatThreadView(conversationID: id, compact: true)
                .id(id)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        } else {
            VStack(spacing: 10) {
                hint("Здесь можно спросить что угодно текстом", icon: "bubble.left.and.bubble.right")
                Button("Начать чат") { chats.create() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    private var transcriptPane: some View {
        if store.currentText.isEmpty {
            hint(
                store.isListening
                    ? "Слушаю. Расшифровка появится здесь"
                    : "Распознавание выключено",
                icon: "waveform"
            )
        } else {
            TranscriptTextView(
                text: store.currentText,
                terms: store.terms,
                onTermTap: { _ in }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func hint(_ text: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var paneBinding: Binding<OverlayPane> {
        Binding(
            get: { settings.overlayPane },
            set: { settings.overlayPane = $0 }
        )
    }
}

// MARK: - Pieces

/// Three text tabs rather than a segmented Picker: a Picker cannot carry the
/// badge that says an answer landed on a pane the user can't see, and it refuses
/// to compress below 227pt — 63% of the card at its minimum width.
private struct PaneTabs: View {
    @Binding var selection: OverlayPane
    let badged: OverlayPane?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(OverlayPane.allCases) { pane in
                Button {
                    selection = pane
                } label: {
                    HStack(spacing: 4) {
                        Text(pane.russianLabel)
                            .font(.caption.weight(selection == pane ? .semibold : .regular))
                            .lineLimit(1)
                        if badged == pane {
                            Circle()
                                .fill(Theme.tint)
                                .frame(width: 5, height: 5)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        selection == pane
                            ? AnyShapeStyle(.primary.opacity(0.1))
                            : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == pane ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .accessibilityLabel(
                    badged == pane ? "\(pane.russianLabel), есть новый ответ" : pane.russianLabel
                )
                .accessibilityAddTraits(selection == pane ? [.isSelected, .isButton] : .isButton)
            }
        }
    }
}

/// Icon control with a real hit area. The bare `Image` buttons this replaces
/// measured about 13pt square — half the comfortable minimum.
private struct OverlayIconButton: View {
    let systemImage: String
    let label: String
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Listening state that can tell "nothing was asked yet" apart from "the mic
/// died" — both used to be the same grey dot.
private struct StatusLight: View {
    let state: OverlayStatus

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle().strokeBorder(.primary.opacity(0.3), lineWidth: state == .idle ? 1 : 0)
            )
            .padding(.horizontal, 2)
            .help(state.label)
            .accessibilityLabel(state.label)
    }
}

/// Opacity slider that unfolds on hover. A permanent slider would take a third
/// of the bar; the value is still readable and adjustable without hovering.
private struct OpacityControl: View {
    @Binding var opacity: Double
    @State private var expanded = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(.secondary)
            if expanded {
                Slider(value: $opacity, in: AppSettings.overlayOpacityRange)
                    .controlSize(.mini)
                    .frame(width: 64)
                Text("\(Int(opacity * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
        .onHover { expanded = $0 }
        .help("Прозрачность фона: \(Int(opacity * 100))%")
        .accessibilityLabel("Прозрачность фона")
        .accessibilityValue("\(Int(opacity * 100)) процентов")
        .accessibilityAdjustableAction { direction in
            let range = AppSettings.overlayOpacityRange
            switch direction {
            case .increment: opacity = min(range.upperBound, opacity + 0.05)
            case .decrement: opacity = max(range.lowerBound, opacity - 0.05)
            @unknown default: break
            }
        }
    }
}
