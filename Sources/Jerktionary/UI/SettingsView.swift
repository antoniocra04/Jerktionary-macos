import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chats: ChatStore
    @State private var devices: [AudioInputDevice] = []
    @State private var checkingBackend = false

    var body: some View {
        Form {
            Section("Сервис ответов") {
                TextField("Адрес сервиса", text: $settings.backendHttpUrl)
                    .onSubmit { checkBackend() }
                Button(checkingBackend ? "Проверяю…" : "Проверить подключение") {
                    checkBackend()
                }
                .disabled(!settings.hasValidBackendUrl || checkingBackend)
                if store.backendStatusLoaded {
                    Label(
                        store.backendReady ? "Сервис готов" : "Нет подключения",
                        systemImage: store.backendReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(store.backendReady ? .green : .orange)
                }
            }

            Section("Аудио") {
                Picker("Источник", selection: Binding(
                    get: { settings.audioSource },
                    set: { settings.audioSource = $0 }
                )) {
                    ForEach(AudioSource.allCases) { source in
                        Text(source.russianLabel).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                if settings.audioSource == .microphone {
                    Picker("Микрофон", selection: $settings.audioInputDeviceUID) {
                        Text("По умолчанию").tag("")
                        ForEach(devices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                }
            }

            Section("Профиль") {
                TextField("Имя окна", text: $settings.displayName)
                    .onSubmit { WindowController.setTitle(settings.displayName) }
                TextField("О себе", text: $settings.aboutMe, axis: .vertical)
                    .lineLimit(3...6)
            }

            Section("Оформление") {
                Picker("Тема", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.russianLabel).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Чат") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Модели, по одной в строке", text: $settings.chatModelsRaw, axis: .vertical)
                        .lineLimit(3...8)
                        .font(.system(.body, design: .monospaced))
                }
                TextField("Системный промпт", text: $settings.chatSystemPrompt, axis: .vertical)
                    .lineLimit(2...6)
                VStack(alignment: .leading, spacing: 4) {
                    TextField(
                        "Вопрос к снимку экрана",
                        text: $settings.chatScreenshotPrompt,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                }
            }

            Section("Справка") {
                DisclosureGroup("Горячие клавиши") {
                    LabeledContent("Ответить сейчас", value: "Ctrl+Shift+Space")
                    LabeledContent("Ответить с полным контекстом", value: "Ctrl+Shift+Enter")
                    LabeledContent("Компактное окно", value: "Ctrl+Shift+O")
                    LabeledContent("Снимок в чат", value: "Ctrl+Shift+S")
                }
                Text("Транскрипция не запускает ответы автоматически — каждый запрос подтверждаете вы.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Диагностика") {
                DisclosureGroup("Технические сведения") {
                    LabeledContent("Адрес", value: settings.normalizedHttpUrl)
                    if !chats.capabilities.label.isEmpty {
                        LabeledContent("Провайдер", value: chats.capabilities.label)
                        LabeledContent(
                            "Модель по умолчанию",
                            value: chats.capabilities.defaultModel.isEmpty ? "—" : chats.capabilities.defaultModel
                        )
                    }
                    if !store.backendComponents.isEmpty {
                        ComponentsListView(components: store.backendComponents)
                    }
                    Button("Открыть веб-диагностику") {
                        if let url = settings.swaggerUrl { NSWorkspace.shared.open(url) }
                    }
                }
            }

            Section {
                Button("Пройти настройку заново") {
                    settings.hasCompletedSetup = false
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 520, idealHeight: 620)
        .padding(12)
        .onAppear { devices = AudioDevices.inputDevices() }
    }

    private func checkBackend() {
        guard settings.hasValidBackendUrl, !checkingBackend else { return }
        checkingBackend = true
        Task {
            await store.refreshBackendStatus()
            checkingBackend = false
        }
    }
}

/// First run: profile → audio → permissions → service → readiness.
struct SetupWizardView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: AppStore
    @State private var step = 0
    @State private var devices: [AudioInputDevice] = []
    @State private var checkingService = false
    @State private var permissionRefresh = 0
    @State private var testedServiceUrl: String?

    private let stepCount = 5

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("Настройка Jerktionary")
                    .font(.largeTitle.weight(.semibold))
                Text("Шаг \(step + 1) из \(stepCount)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Group {
                switch step {
                case 0:
                    wizardCard(
                        title: "Профиль",
                        subtitle: "Имя окна маскирует назначение приложения, а профиль помогает формулировать ответы."
                    ) {
                        TextField("Название окна", text: $settings.displayName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Например: senior frontend, React/TS, 7 лет опыта", text: $settings.aboutMe, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...6)
                    }
                case 1:
                    wizardCard(
                        title: "Что слушаем?",
                        subtitle: "Микрофон слышит вас. Системный звук — собеседника из приложения для звонков."
                    ) {
                        Picker("Источник звука", selection: Binding(
                            get: { settings.audioSource },
                            set: { settings.audioSource = $0 }
                        )) {
                            ForEach(AudioSource.allCases) { source in
                                Text(source.russianLabel).tag(source)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if settings.audioSource == .microphone {
                            Picker("Микрофон", selection: $settings.audioInputDeviceUID) {
                                Text("По умолчанию").tag("")
                                ForEach(devices) { device in
                                    Text(device.name).tag(device.uid)
                                }
                            }
                        }
                    }
                case 2:
                    wizardCard(
                        title: "Разрешения",
                        subtitle: "macOS требует отдельное разрешение для выбранного источника."
                    ) {
                        permissionRow
                    }
                    .id(permissionRefresh)
                case 3:
                    wizardCard(
                        title: "Сервис ответов",
                        subtitle: "Проверьте соединение до начала звонка."
                    ) {
                        TextField("http://127.0.0.1:8000", text: $settings.backendHttpUrl)
                            .textFieldStyle(.roundedBorder)
                        if !settings.hasValidBackendUrl {
                            Label("Введите корректный адрес HTTP или HTTPS", systemImage: "exclamationmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                        Button(checkingService ? "Проверяю…" : "Проверить подключение") {
                            checkingService = true
                            let urlUnderTest = settings.normalizedHttpUrl
                            Task {
                                await store.refreshBackendStatus()
                                testedServiceUrl = store.backendReady
                                    && settings.normalizedHttpUrl == urlUnderTest
                                    ? urlUnderTest
                                    : nil
                                checkingService = false
                            }
                        }
                        .disabled(!settings.hasValidBackendUrl || checkingService)

                        if store.backendStatusLoaded {
                            Label(
                                serviceIsVerified
                                    ? "Сервис готов"
                                    : (store.backendReady
                                       ? "Проверьте этот адрес"
                                       : "Подключение не установлено"),
                                systemImage: serviceIsVerified
                                    ? "checkmark.circle.fill"
                                    : "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(serviceIsVerified ? .green : .orange)
                        }
                    }
                default:
                    wizardCard(
                        title: "Готово к звонку",
                        subtitle: "Jerktionary слушает постоянно, но готовит ответы только по вашей команде."
                    ) {
                        readinessRow("Источник выбран", ready: true)
                        readinessRow("Разрешение получено", ready: requiredPermissionGranted)
                        readinessRow("Сервис ответов готов", ready: serviceIsVerified)
                        Text("Ctrl+Shift+Space — ответить сейчас")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 480)

            HStack {
                if step > 0 {
                    Button("Назад") { step -= 1 }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
                Spacer()
                if step < stepCount - 1 {
                    Button("Далее") { step += 1 }
                        .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(!canContinue)
                } else {
                    Button("Готово") {
                        settings.hasCompletedSetup = true
                        WindowController.setTitle(settings.displayName)
                        Task { await store.refreshBackendStatus() }
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(!requiredPermissionGranted || !serviceIsVerified)
                }
            }
            .frame(maxWidth: 480)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .onAppear { devices = AudioDevices.inputDevices() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionRefresh += 1
        }
    }

    @ViewBuilder
    private var permissionRow: some View {
        if settings.audioSource == .microphone {
            readinessRow("Доступ к микрофону", ready: microphoneGranted)
            if !microphoneGranted {
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    Button("Разрешить микрофон") {
                        Task {
                            _ = await AVCaptureDevice.requestAccess(for: .audio)
                            permissionRefresh += 1
                        }
                    }
                } else {
                    Button("Открыть настройки macOS") {
                        openPrivacySettings("Privacy_Microphone")
                    }
                }
            }
        } else {
            readinessRow("Запись системного звука", ready: screenCaptureGranted)
            if !screenCaptureGranted {
                HStack {
                    Button("Запросить доступ") {
                        CGRequestScreenCaptureAccess()
                        permissionRefresh += 1
                    }
                    Button("Открыть настройки macOS") {
                        openPrivacySettings("Privacy_ScreenCapture")
                    }
                }
            }
        }
    }

    private func readinessRow(_ title: String, ready: Bool) -> some View {
        Label(title, systemImage: ready ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(ready ? .green : .secondary)
    }

    private var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private var screenCaptureGranted: Bool { CGPreflightScreenCaptureAccess() }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private var requiredPermissionGranted: Bool {
        settings.audioSource == .microphone ? microphoneGranted : screenCaptureGranted
    }

    private var serviceIsVerified: Bool {
        store.backendReady && testedServiceUrl == settings.normalizedHttpUrl
    }

    private var canContinue: Bool {
        switch step {
        case 0: !settings.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case 1: true
        case 2: requiredPermissionGranted
        case 3: settings.hasValidBackendUrl && serviceIsVerified
        default: true
        }
    }

    private func wizardCard(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .journalCard(padding: 26)
    }
}
