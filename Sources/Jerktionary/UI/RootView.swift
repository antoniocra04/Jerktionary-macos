import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            if !settings.hasCompletedSetup {
                SetupWizardView()
            } else if store.overlayMode {
                OverlayView()
            } else {
                MainView()
            }
        }
        .tint(Theme.tint)
        .background(Theme.canvas)
    }
}

/// Journal-style shell: translucent sidebar on the LEFT (under the traffic
/// lights), content area on the right with a left-aligned large title and
/// round toolbar buttons, over a faint lavender wash.
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
            .animation(.easeOut(duration: 0.2), value: store.sidebarVisible)

            if let meeting = store.selectedMeeting {
                MeetingModal(meeting: meeting)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.selectedMeeting != nil)
        .background(Theme.canvas)
    }

    @ViewBuilder
    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            MainTopBar()

            // Both areas stay mounted; switching only toggles visibility, so the
            // open note and scroll positions survive a round-trip to the session.
            // The listening pipeline runs in the store regardless of the tab.
            ZStack {
                sessionArea
                    .opacity(store.mainTab == .session ? 1 : 0)
                    .allowsHitTesting(store.mainTab == .session)

                NotesView()
                    .opacity(store.mainTab == .notes ? 1 : 0)
                    .allowsHitTesting(store.mainTab == .notes)
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

                    ScrollView {
                        TranscriptView()
                            .padding(.bottom, 28)
                    }
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)
        }
    }
}

/// Large left-aligned title + round action buttons, like Journal's top row.
struct MainTopBar: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: AppSettings
    @State private var showSettings = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            CircleToolbarButton(
                systemImage: "sidebar.left",
                help: store.sidebarVisible ? "Скрыть боковую панель" : "Показать боковую панель"
            ) {
                store.sidebarVisible.toggle()
            }
            .padding(.trailing, 4)

            Text(settings.displayName)
                .font(.system(size: 26, weight: .bold))

            Picker("", selection: $store.mainTab) {
                Text("Сессия").tag(MainTab.session)
                Text("Заметки").tag(MainTab.notes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.leading, 12)

            Spacer()

            if store.isListening {
                LevelMeterView(level: store.microphoneLevel)
                    .padding(.trailing, 6)
            }

            CircleToolbarButton(
                systemImage: "gearshape",
                help: "Настройки"
            ) {
                showSettings = true
            }
            .popover(isPresented: $showSettings) {
                SettingsView()
            }

            CircleToolbarButton(
                systemImage: settings.theme == .dark ? "sun.max" : "moon",
                help: settings.theme == .dark ? "Светлая тема" : "Тёмная тема"
            ) {
                settings.theme = settings.theme == .dark ? .light : .dark
            }

            CircleToolbarButton(
                systemImage: store.contentProtectionEnabled ? "eye.slash" : "eye",
                active: store.contentProtectionEnabled,
                help: store.contentProtectionEnabled ? "Скрыто от захвата экрана" : "Видно при захвате экрана"
            ) {
                store.contentProtectionEnabled.toggle()
                WindowController.setContentProtection(store.contentProtectionEnabled)
            }

            ListenButton()
                .padding(.leading, 6)
        }
        .padding(.horizontal, 28)
        // Constant padding in both states: the row never jumps, it only slides
        // horizontally together with the content when the sidebar collapses.
        // 36 keeps it clear of the traffic lights when the sidebar is hidden.
        .padding(.top, 36)
        .padding(.bottom, 16)
        // Move the whole row as one unit during the sidebar slide; without
        // this the button and the title animate out of sync and overlap.
        .geometryGroup()
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
