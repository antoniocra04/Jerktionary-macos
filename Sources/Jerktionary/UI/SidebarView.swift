import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Left translucent sidebar, Journal-style: past meetings on top (like the
/// journals list), then live terms and recent explanations during a session.
struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    /// Observed directly: the list is published here, not on AppStore.
    @EnvironmentObject private var meetings: MeetingsStore
    @State private var searchText = ""
    @State private var selecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var confirmingBulkDelete = false

    private var filteredMeetings: [MeetingRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return meetings.meetings }
        return meetings.meetings.filter { meeting in
            meeting.context.localizedCaseInsensitiveContains(query)
                || meeting.transcript.localizedCaseInsensitiveContains(query)
                || meeting.qa.contains {
                    $0.question.localizedCaseInsensitiveContains(query)
                        || $0.answer.localizedCaseInsensitiveContains(query)
                }
        }
    }

    var body: some View {
        sidebarContent
            .modifier(LiquidGlassPanel())
            .onAppear { meetings.load() }
    }

    private var sidebarContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Встречи")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !meetings.meetings.isEmpty {
                            Button {
                                selecting.toggle()
                                if !selecting { selectedIDs = [] }
                            } label: {
                                Image(systemName: selecting ? "checkmark" : "checklist")
                            }
                            .buttonStyle(.plain)
                            .help(selecting ? "Завершить выбор" : "Выбрать встречи")
                            .accessibilityLabel(selecting ? "Завершить выбор" : "Выбрать встречи")
                        }
                    }
                    .padding(.leading, 2)

                    if !meetings.meetings.isEmpty {
                        TextField("Поиск", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Поиск по встречам")
                    }
                    if meetings.meetings.isEmpty {
                        Text("Прошедшие встречи появятся здесь")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                    } else if filteredMeetings.isEmpty {
                        Text("Ничего не найдено")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                    } else {
                        VStack(spacing: 4) {
                            ForEach(filteredMeetings) { meeting in
                                MeetingRow(
                                    meeting: meeting,
                                    selected: selecting
                                        ? selectedIDs.contains(meeting.id)
                                        : store.selectedMeeting?.id == meeting.id,
                                    selecting: selecting
                                ) {
                                    if selecting {
                                        if selectedIDs.contains(meeting.id) {
                                            selectedIDs.remove(meeting.id)
                                        } else {
                                            selectedIDs.insert(meeting.id)
                                        }
                                    } else {
                                        store.selectedMeeting = meeting
                                    }
                                }
                            }
                        }
                    }

                    if selecting {
                        HStack(spacing: 8) {
                            Text("Выбрано: \(selectedIDs.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(action: exportSelected) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .disabled(selectedIDs.isEmpty)
                            .help("Экспортировать выбранные")
                            .accessibilityLabel("Экспортировать выбранные встречи")
                            Button(role: .destructive) {
                                confirmingBulkDelete = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .disabled(selectedIDs.isEmpty)
                            .help("Удалить выбранные")
                            .accessibilityLabel("Удалить выбранные встречи")
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, 4)
                    }
                }

            }
            .padding(.top, 16)
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .scrollContentBackground(.hidden)
        .alert("Удалить выбранные встречи?", isPresented: $confirmingBulkDelete) {
            Button("Удалить", role: .destructive) {
                for id in selectedIDs { meetings.delete(id) }
                selectedIDs = []
                selecting = false
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Транскрипты и ответы нельзя будет восстановить.")
        }
    }

    private func exportSelected() {
        let selected = meetings.meetings.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "meetings-export.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let markdown = selected
            .map { MeetingsStore.markdown(for: $0) }
            .joined(separator: "\n\n---\n\n")
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Native Liquid Glass on macOS 26+ (Apple's glassEffect), regular material
/// fallback on earlier systems. The panel floats with rounded corners.
private struct LiquidGlassPanel: ViewModifier {
    static let cornerRadius: CGFloat = 18

    // The project intentionally builds with the macOS 26 SDK so local and CI
    // adopt the same SwiftUI appearance. The runtime branch still supports the
    // package's macOS 14 deployment target.
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            )
        } else {
            materialFallback(content)
        }
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
    @EnvironmentObject private var meetings: MeetingsStore
    let meeting: MeetingRecord
    let selected: Bool
    let selecting: Bool
    let open: () -> Void
    @State private var hovering = false
    @State private var confirmingDelete = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(MeetingsStore.formatDate(meeting.startedAt))
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 0)
                    if selecting {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? Theme.tint : .secondary)
                            .accessibilityHidden(true)
                    }
                }
                Text(meeting.context.isEmpty ? "Без контекста" : meeting.context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Theme.tint.opacity(0.14) : (hovering ? Theme.tint.opacity(0.1) : .clear),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Удалить", role: .destructive) {
                confirmingDelete = true
            }
        }
        .alert("Удалить встречу?", isPresented: $confirmingDelete) {
            Button("Удалить", role: .destructive) {
                meetings.delete(meeting.id)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Транскрипт и ответы этой встречи нельзя будет восстановить.")
        }
    }
}

struct ComponentsListView: View {
    let components: [BackendComponent]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(components) { component in
                HStack(spacing: 6) {
                    Image(systemName: component.ready
                          ? "checkmark.circle.fill"
                          : (component.required ? "xmark.circle.fill" : "exclamationmark.triangle.fill"))
                        .foregroundStyle(component.ready ? .green : (component.required ? .red : .orange))
                    Text(component.name)
                        .font(.caption)
                    Spacer()
                }
                .help(component.details)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(component.name)
                .accessibilityValue(component.ready
                                    ? "готов"
                                    : (component.required ? "обязательный компонент не готов" : "необязательный компонент не готов"))
                .accessibilityHint(component.details)
            }
        }
    }
}
