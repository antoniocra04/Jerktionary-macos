import SwiftUI

/// Left translucent sidebar, Journal-style: past meetings on top (like the
/// journals list), then live terms and recent explanations during a session.
struct SidebarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        sidebarContent
            .modifier(LiquidGlassPanel())
            .onAppear { store.meetings.load() }
    }

    private var sidebarContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Встречи") {
                    if store.meetings.meetings.isEmpty {
                        Text("Прошедшие встречи появятся здесь")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                    } else {
                        VStack(spacing: 4) {
                            ForEach(store.meetings.meetings) { meeting in
                                MeetingRow(meeting: meeting) {
                                    store.selectedMeeting = meeting
                                }
                            }
                        }
                    }
                }

                if !store.terms.isEmpty {
                    section("Термины") {
                        FlowTagsView(terms: store.terms)
                    }
                }

                if !store.lastExplanations.isEmpty {
                    section("Объяснения") {
                        ForEach(store.lastExplanations) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.explanation.title.isEmpty ? item.term : item.explanation.title)
                                    .font(.caption.weight(.semibold))
                                Text(item.explanation.short)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            .journalCard(padding: 10)
                        }
                    }
                }
            }
            // Clears the traffic lights under the hidden title bar.
            .padding(.top, 44)
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .scrollContentBackground(.hidden)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Native Liquid Glass on macOS 26+ (Apple's glassEffect), regular material
/// fallback on earlier systems. The panel floats with rounded corners.
private struct LiquidGlassPanel: ViewModifier {
    static let cornerRadius: CGFloat = 18

    // The compiler guard keeps the project buildable with pre-26 SDKs (CI
    // runners on older Xcode); the runtime check covers older systems.
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            )
        } else {
            materialFallback(content)
        }
        #else
        materialFallback(content)
        #endif
    }

    private func materialFallback(_ content: Content) -> some View {
        content
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            )
            .shadow(color: Theme.shadowColor, radius: 8, y: 2)
    }
}

/// One meeting in the sidebar list — a quiet row, Journal's journals-list style.
private struct MeetingRow: View {
    @EnvironmentObject private var store: AppStore
    let meeting: MeetingRecord
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text(MeetingsStore.formatDate(meeting.startedAt))
                    .font(.callout.weight(.medium))
                Text(meeting.context.isEmpty ? "Без контекста" : meeting.context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                hovering ? Theme.tint.opacity(0.1) : .clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Удалить", role: .destructive) {
                store.meetings.delete(meeting.id)
            }
        }
    }
}

struct ComponentsListView: View {
    let components: [BackendComponent]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(components) { component in
                HStack(spacing: 6) {
                    Circle()
                        .fill(component.ready ? .green : (component.required ? .red : .orange))
                        .frame(width: 6, height: 6)
                    Text(component.name)
                        .font(.caption)
                    Spacer()
                }
                .help(component.details)
            }
        }
    }
}

/// Wrapping tag cloud for terms.
struct FlowTagsView: View {
    @EnvironmentObject private var store: AppStore
    let terms: [TranscriptTerm]
    @State private var selected: TranscriptTerm?

    private var uniqueTerms: [TranscriptTerm] {
        var seen = Set<String>()
        return terms.filter { seen.insert($0.normalized).inserted }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(uniqueTerms) { term in
                Button {
                    selected = term
                    store.explanations.fetchStreaming(term: term.normalized, context: store.currentText)
                } label: {
                    Text(term.text)
                        .font(.caption)
                        .foregroundStyle(Theme.tint)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Theme.tint.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .popover(item: $selected) { term in
            TermExplanationPopover(term: term)
        }
    }
}
