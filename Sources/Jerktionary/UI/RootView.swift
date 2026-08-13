import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            if !settings.hasCompletedSetup {
                SetupWizardView()
            } else {
                // The compact card is a separate floating panel, not a state of
                // this window — see OverlayPanel.
                MainView()
            }
        }
        .tint(Theme.tint)
        .background(Theme.canvas)
        .toolbar {
            if settings.hasCompletedSetup {
                MainToolbar()
            }
        }
    }
}

/// Journal-style shell: translucent sidebar on the left and a focused content
/// area under the native macOS toolbar, over a faint lavender wash.
struct MainView: View {
    @EnvironmentObject private var store: AppStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // The wash spans the whole window so the floating glass sidebar
            // has something to refract.
            Theme.contentWash
                .ignoresSafeArea()

            HStack(spacing: 0) {
                if store.sidebarVisible {
                    SidebarView()
                        .frame(width: 240)
                        .padding(.leading, 10)
                        .padding(.vertical, 10)
                        .transition(reduceMotion ? .opacity : .move(edge: .leading))
                }
                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: store.sidebarVisible)
        }
        .background(Theme.canvas)
        .sheet(item: $store.selectedMeeting) { meeting in
            MeetingDetailView(meeting: meeting)
                .frame(minWidth: 560, minHeight: 420)
        }
        .onChange(of: store.mainTab) {
            // An AppKit text view can remain first responder after its SwiftUI tab
            // is hidden. Clearing it prevents keyboard input from going offscreen.
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onChange(of: store.sessionAnswers.count) { previous, current in
            if current > previous {
                AccessibilityAnnouncer.announce("Ответ готов")
            }
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Both areas stay mounted; switching only toggles visibility, so the
            // open note and scroll positions survive a round-trip to the session.
            // The listening pipeline runs in the store regardless of the tab.
            ZStack {
                sessionArea
                    .opacity(store.mainTab == .session ? 1 : 0)
                    .allowsHitTesting(store.mainTab == .session)
                    .disabled(store.mainTab != .session)
                    .accessibilityHidden(store.mainTab != .session)

                NotesView()
                    .opacity(store.mainTab == .notes ? 1 : 0)
                    .allowsHitTesting(store.mainTab == .notes)
                    .disabled(store.mainTab != .notes)
                    .accessibilityHidden(store.mainTab != .notes)

                ChatView()
                    .opacity(store.mainTab == .chat ? 1 : 0)
                    .allowsHitTesting(store.mainTab == .chat)
                    .disabled(store.mainTab != .chat)
                    .accessibilityHidden(store.mainTab != .chat)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var sessionArea: some View {
        if store.backendStatusLoaded, store.backendUnavailable || !store.backendReady {
            BackendUnavailableView()
        } else if store.currentText.isEmpty && !store.isListening && store.answeredQuestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                MeetingContextField()
                    .padding(.horizontal, 28)
                    .padding(.top, 4)
                EmptySessionView()
            }
        } else {
            // Two-column session layout: answers on the left,
            // the live transcript on the right, scrolled independently.
            VStack(alignment: .leading, spacing: 16) {
                if let error = store.microphoneError ?? store.websocketError {
                    ErrorBanner(message: error)
                }
                MeetingContextField()
                HStack(alignment: .top, spacing: 18) {
                    ScrollView {
                        LiveAnswersView()
                            .padding(.bottom, 28)
                    }
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    // No outer ScrollView: the transcript scrolls inside its own
                    // text view, which is what keeps its layout cost bounded.
                    TranscriptView()
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)
        }
    }
}

/// Native toolbar: macOS owns compression and overflow, while every action also
/// appears in the menu bar through JerktionaryApp's Commands.
struct MainToolbar: ToolbarContent {
    @EnvironmentObject private var store: AppStore

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                store.sidebarVisible.toggle()
            } label: {
                Label(
                    store.sidebarVisible ? "Скрыть боковую панель" : "Показать боковую панель",
                    systemImage: "sidebar.left"
                )
            }
            .help(store.sidebarVisible ? "Скрыть боковую панель" : "Показать боковую панель")
        }

        ToolbarItem(placement: .principal) {
            Picker("Раздел", selection: $store.mainTab) {
                Text("Сессия").tag(MainTab.session)
                Text("Заметки").tag(MainTab.notes)
                Text("Чат").tag(MainTab.chat)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if store.isListening {
                LevelMeterView(model: store.audioLevel)
            }

            Button {
                store.toggleOverlay()
            } label: {
                Label(
                    "Компактный режим поверх всех окон",
                    systemImage: "rectangle.bottomthird.inset.filled"
                )
            }
            .help("Компактный режим поверх всех окон (Ctrl+Shift+O)")

            Button {
                store.contentProtectionEnabled.toggle()
                WindowController.setContentProtection(store.contentProtectionEnabled)
            } label: {
                Label(
                    store.contentProtectionEnabled
                        ? "Скрыто от захвата экрана"
                        : "Видно при захвате экрана",
                    systemImage: store.contentProtectionEnabled ? "eye.slash" : "eye"
                )
            }
            .help(store.contentProtectionEnabled ? "Скрыто от захвата экрана" : "Видно при захвате экрана")

            ListenButton()
        }
    }
}

/// Journal's "No Entries": a centered quiet empty state for a fresh session.
struct EmptySessionView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.lavenderGradient)
            Text("Нет записей")
                .font(.title2.weight(.bold))
            Text("Нажмите «Слушать», чтобы начать транскрипцию встречи.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .red.opacity(0.09),
            in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .onAppear { AccessibilityAnnouncer.announce(message) }
        .onChange(of: message) { AccessibilityAnnouncer.announce(message) }
    }
}

struct BackendUnavailableView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.lavenderGradient)
            Text(store.backendUnavailable
                 ? "Backend недоступен"
                 : "Backend запущен, но компоненты не готовы")
                .font(.title2.weight(.bold))
            Text("Приложение ожидает backend на \(settings.normalizedHttpUrl). Проверьте адрес в настройках и что backend запущен.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button("Повторить") {
                    Task { await store.refreshBackendStatus() }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                Button("Открыть Swagger") {
                    if let url = settings.swaggerUrl {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
            .padding(.top, 4)
            if !store.backendComponents.isEmpty {
                ComponentsListView(components: store.backendComponents)
                    .frame(maxWidth: 220)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }
}
