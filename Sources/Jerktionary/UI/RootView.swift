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
                if store.sidebarVisible, store.mainTab == .session {
                    SidebarView()
                        .frame(width: 240)
                        .padding(.leading, 10)
                        .padding(.vertical, 10)
                        .transition(reduceMotion ? .opacity : .move(edge: .leading))
                }
                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.2),
                value: store.sidebarVisible && store.mainTab == .session
            )

            if let notice = store.transientNotice {
                TransientNoticeView(message: notice)
                    .padding(.bottom, 18)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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
        if shouldBlockSessionForBackend {
            BackendUnavailableView()
        } else if store.currentText.isEmpty && !store.isListening && store.answerRequests.isEmpty {
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
                if let error = sessionError {
                    ErrorBanner(message: error)
                }
                MeetingContextField(compact: store.isListening)
                AnswerRequestBar()
                HStack(alignment: .top, spacing: 18) {
                    ScrollView {
                        LiveAnswersView()
                            .padding(.bottom, 28)
                    }
                    .scrollContentBackground(.hidden)
                    .frame(minWidth: 380, maxWidth: .infinity, alignment: .topLeading)
                    .layoutPriority(2)

                    // No outer ScrollView: the transcript scrolls inside its own
                    // text view, which is what keeps its layout cost bounded.
                    TranscriptView()
                        .padding(.bottom, 28)
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 380, alignment: .topLeading)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)
        }
    }

    private var backendIsUnavailable: Bool {
        store.backendStatusLoaded && (store.backendUnavailable || !store.backendReady)
    }

    /// A health-check failure may happen mid-call. Existing transcript and
    /// answers remain useful, so only replace the whole surface before a
    /// session has begun; otherwise keep the work visible with an inline error.
    private var shouldBlockSessionForBackend: Bool {
        backendIsUnavailable
            && !store.isListening
            && store.currentText.isEmpty
            && store.answerRequests.isEmpty
    }

    private var sessionError: String? {
        if let error = store.microphoneError ?? store.websocketError { return error }
        if backendIsUnavailable {
            return "Связь с сервисом ответов потеряна. Уже полученные данные доступны; новые ответы временно недоступны."
        }
        return nil
    }
}

/// Native toolbar: macOS owns compression and overflow, while every action also
/// appears in the menu bar through JerktionaryApp's Commands.
struct MainToolbar: ToolbarContent {
    @EnvironmentObject private var store: AppStore

    var body: some ToolbarContent {
        if store.mainTab == .session {
            ToolbarItem(placement: .navigation) {
                Button {
                    store.sidebarVisible.toggle()
                } label: {
                    Label(
                        store.sidebarVisible ? "Скрыть историю встреч" : "Показать историю встреч",
                        systemImage: "sidebar.left"
                    )
                }
                .help(store.sidebarVisible ? "Скрыть историю встреч" : "Показать историю встреч")
            }
        }

        ToolbarItem(placement: .principal) {
            Picker("Раздел", selection: $store.mainTab) {
                Text(sessionTitle).tag(MainTab.session)
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
                        ? "Показывать при захвате экрана"
                        : "Скрыть при захвате экрана",
                    systemImage: store.contentProtectionEnabled ? "eye.slash" : "eye"
                )
            }
            .help(store.contentProtectionEnabled
                  ? "Сейчас окно скрыто от захвата. Нажмите, чтобы показывать"
                  : "Сейчас окно видно при захвате. Нажмите, чтобы скрыть")

            ListenButton()
        }
    }

    private var sessionTitle: String {
        if store.answerStreamingCount > 0 { return "Сессия ◌" }
        if store.sessionHasUnreadAnswer { return "Сессия •" }
        return "Сессия"
    }
}

/// Journal's "No Entries": a centered quiet empty state for a fresh session.
struct EmptySessionView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.lavenderGradient)
            Text("Готов к разговору")
                .font(.title2.weight(.bold))
            Text("Начните прослушивание, когда звонок будет готов.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }
}

struct TransientNoticeView: View {
    @EnvironmentObject private var store: AppStore
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Theme.tint)
            Text(message)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Button {
                store.transientNotice = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Закрыть")
            .accessibilityLabel("Закрыть уведомление")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .shadow(color: Theme.shadowColor, radius: 8, y: 3)
        .task(id: message) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if store.transientNotice == message { store.transientNotice = nil }
        }
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

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.lavenderGradient)
            Text(store.backendUnavailable
                 ? "Нет связи с сервисом ответов"
                 : "Сервис ответов ещё не готов")
                .font(.title2.weight(.bold))
            Text("Проверьте подключение в настройках.")
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
                SettingsLink {
                    Text("Открыть настройки")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }
}
