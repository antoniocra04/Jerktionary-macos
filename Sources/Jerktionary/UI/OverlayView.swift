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

    /// The request on screen. Held so a newly requested answer cannot replace
    /// the answer being read aloud mid-sentence.
    @State private var pinned: String?
    /// Newest question already seen on the answer pane, so the tab can show that
    /// something arrived while another pane was open.
    @State private var seen: String?
    @State private var transcriptExpanded = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var questions: [String] { store.answerRequests }

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
            if settings.overlayPane == .live { seen = questions.first }
        }
        .onAppear { seen = questions.first }
        .overlay(alignment: .bottom) {
            if let notice = store.transientNotice {
                TransientNoticeView(message: notice)
                    .padding(10)
            }
        }
    }

    /// Transparency lives in the background, never in the text. Fading the whole
    /// panel took the answer itself to ~1.5:1 at the low end of this same slider.
    @ViewBuilder
    private var cardBackground: some View {
        if reduceTransparency {
            Theme.canvas
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(settings.overlayOpacity)
        }
    }

    // MARK: Title bar

    private var titleBar: some View {
        ViewThatFits(in: .horizontal) {
            fullTitleBar
            compactTitleBar
        }
    }

    private var fullTitleBar: some View {
        HStack(spacing: 6) {
            StatusLight(state: store.overlayStatus)

            PaneTabs(selection: paneBinding, badged: badgedPane, compact: false)
                .layoutPriority(1)

            Spacer(minLength: 2)

            OpacityControl(opacity: $settings.overlayOpacity)

            OverlayIconButton(
                systemImage: store.contentProtectionEnabled ? "eye.slash" : "eye",
                label: store.contentProtectionEnabled
                    ? "Hidden from screen capture — click to show"
                    : "Visible in screen capture — click to hide",
                tint: store.contentProtectionEnabled ? .secondary : .orange
            ) {
                store.contentProtectionEnabled.toggle()
                WindowController.setContentProtection(store.contentProtectionEnabled)
            }

            OverlayIconButton(
                systemImage: "arrow.up.left.and.arrow.down.right",
                label: "Expand to the normal window"
            ) {
                store.toggleOverlay()
            }

            OverlayIconButton(
                systemImage: "xmark",
                label: "Hide the card. Bring it back with Ctrl+Shift+O"
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

    private var compactTitleBar: some View {
        HStack(spacing: 5) {
            StatusLight(state: store.overlayStatus)
            PaneTabs(selection: paneBinding, badged: badgedPane, compact: true)
                .layoutPriority(1)
            Spacer(minLength: 0)
            Menu {
                Picker("Background opacity", selection: $settings.overlayOpacity) {
                    Text("70%").tag(0.70)
                    Text("85%").tag(0.85)
                    Text("100%").tag(1.0)
                }
                Divider()
                Button(store.contentProtectionEnabled
                       ? "Show during screen capture"
                       : "Hide during screen capture") {
                    store.contentProtectionEnabled.toggle()
                    WindowController.setContentProtection(store.contentProtectionEnabled)
                }
                Button("Expand to the normal window") {
                    store.toggleOverlay()
                }
            } label: {
                Label("Card options", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Card options")

            OverlayIconButton(
                systemImage: "xmark",
                label: "Hide the card. Bring it back with Ctrl+Shift+O"
            ) {
                store.hideOverlay()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    /// Which tab should show that something arrived behind the user's back.
    private var badgedPane: OverlayPane? {
        guard settings.overlayPane != .live else { return nil }
        if answers.isGenerating { return .live }
        guard let newest = questions.first, newest != seen else { return nil }
        return .live
    }

    private func faultStrip(_ fault: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(fault)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Problem")
        .accessibilityValue(fault)
        .help(fault)
        .onAppear { AccessibilityAnnouncer.announce(fault) }
    }

    // MARK: Panes

    @ViewBuilder
    private var pane: some View {
        switch settings.overlayPane {
        case .live:
            livePane
        case .chat:
            chatPane
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
    private var livePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            AnswerRequestBar(compact: true)
                .padding(.horizontal, 10)
                .padding(.top, 8)

            if let shown {
                ScrollView {
                    AnswerCardView(question: shown, compact: true)
                        // Without this the card keeps its @State across a change
                        // of question: "More detail" left on hid the next answer
                        // behind a spinner even though it was already cached.
                        .id(shown)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: 680)
                        .frame(maxWidth: .infinity)
                }
                .scrollContentBackground(.hidden)

                if questions.count > 1 {
                    answerPager
                }
            } else {
                hint(
                    store.isListening
                        ? "Press “Answer” when you need a hint"
                        : "Start listening to prepare an answer",
                    icon: "sparkles"
                )
            }

            transcriptDisclosure
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
                    Label("New answer", systemImage: "arrow.up.circle.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tint)
            } else {
                Text("Latest answer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text("\(questions.count - shownIndex) of \(questions.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            OverlayIconButton(systemImage: "chevron.left", label: "Older answer") {
                move(+1)
            }
            .disabled(shownIndex >= questions.count - 1)
            .keyboardShortcut(.leftArrow, modifiers: [])

            OverlayIconButton(systemImage: "chevron.right", label: "Newer answer") {
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
        if settings.overlayPane == .live, pinned == nil {
            seen = current
        }
    }

    // MARK: Chat and transcript

    private var chatPane: some View {
        VStack(spacing: 0) {
            overlayChatBar

            Group {
                if let id = chats.selectedID, chats.conversation(id: id) != nil {
                    ChatThreadView(conversationID: id, compact: true)
                        .id(id)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                } else {
                    hint(
                        "Pick an existing chat or create a new one",
                        icon: "bubble.left.and.bubble.right"
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var overlayChatBar: some View {
        HStack(spacing: 6) {
            Menu {
                Button("New chat", systemImage: "square.and.pencil") {
                    chats.create()
                }

                if !chats.conversations.isEmpty {
                    Divider()
                    ForEach(chats.conversations) { conversation in
                        Button {
                            chats.selectedID = conversation.id
                        } label: {
                            Label(
                                "\(conversation.displayTitle) · \(ChatStore.formatDate(conversation.updatedAt))",
                                systemImage: conversation.id == chats.selectedID
                                    ? "checkmark"
                                    : "bubble.left"
                            )
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text(selectedChatTitle)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .help("Switch chat")
            .accessibilityLabel("Current chat: \(selectedChatTitle). Switch chat")

            OverlayIconButton(systemImage: "square.and.pencil", label: "New chat") {
                chats.create()
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(.primary.opacity(0.04))
    }

    private var selectedChatTitle: String {
        guard let id = chats.selectedID,
              let conversation = chats.conversation(id: id)
        else { return "Pick a chat" }
        return conversation.displayTitle
    }

    private var transcriptDisclosure: some View {
        DisclosureGroup("Transcript", isExpanded: $transcriptExpanded) {
            Group {
                if store.currentText.isEmpty {
                    Text(store.isListening ? "The transcript will appear here" : "Listening is off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TranscriptTextView(
                        text: store.currentText,
                        terms: store.terms,
                        onTermTap: { _ in }
                    )
                    .frame(height: 120)
                }
            }
            .padding(.top, 6)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.primary.opacity(0.04))
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

/// Two text tabs rather than a segmented Picker: a Picker cannot carry the
/// badge that says an answer landed on a pane the user can't see, and it refuses
/// to compress below 227pt — 63% of the card at its minimum width.
private struct PaneTabs: View {
    @Binding var selection: OverlayPane
    let badged: OverlayPane?
    let compact: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(OverlayPane.allCases) { pane in
                Button {
                    selection = pane
                } label: {
                    HStack(spacing: 4) {
                        if compact {
                            Image(systemName: pane.systemImage)
                                .font(.system(size: 12, weight: selection == pane ? .semibold : .regular))
                        } else {
                            Text(pane.label)
                                .font(.caption.weight(selection == pane ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        if badged == pane {
                            Circle()
                                .fill(Theme.tint)
                                .frame(width: 5, height: 5)
                        }
                    }
                    .padding(.horizontal, compact ? 7 : 8)
                    .frame(minWidth: compact ? 28 : 0)
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
                    badged == pane ? "\(pane.label), new answer" : pane.label
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
            .accessibilityElement()
            .accessibilityLabel(state.label)
    }
}

/// Stable-width opacity menu. It remains keyboard/VoiceOver accessible and does
/// not make the title bar reflow when the pointer crosses it.
private struct OpacityControl: View {
    @Binding var opacity: Double

    var body: some View {
        Menu {
            Picker("Background opacity", selection: $opacity) {
                Text("70%").tag(0.70)
                Text("85%").tag(0.85)
                Text("100%").tag(1.0)
            }
        } label: {
            Label("Background opacity", systemImage: "circle.lefthalf.filled")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Background opacity: \(Int(opacity * 100))%")
        .accessibilityLabel("Background opacity")
        .accessibilityValue("\(Int(opacity * 100)) percent")
    }
}
