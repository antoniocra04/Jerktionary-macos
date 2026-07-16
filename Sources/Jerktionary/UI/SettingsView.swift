import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: AppStore
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        Form {
            Section("Backend") {
                TextField("Адрес backend", text: $settings.backendHttpUrl)
                    .onSubmit { Task { await store.refreshBackendStatus() } }
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

            Section {
                Button("Пройти настройку заново") {
                    settings.hasCompletedSetup = false
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(8)
        .onAppear { devices = AudioDevices.inputDevices() }
    }
}

/// First-run wizard: name → about → audio source → backend URL.
struct SetupWizardView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: AppStore
    @State private var step = 0
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        VStack(spacing: 24) {
            Text("Настройка Jerktionary")
                .font(.largeTitle.weight(.semibold))

            Group {
                switch step {
                case 0:
                    wizardCard(
                        title: "Как назвать окно?",
                        subtitle: "Это имя видно в заголовке окна и скрывает настоящее назначение приложения."
                    ) {
                        TextField("Название окна", text: $settings.displayName)
                            .textFieldStyle(.roundedBorder)
                    }
                case 1:
                    wizardCard(
                        title: "Расскажите о себе",
                        subtitle: "Роль, стек, опыт — ответы будут говорить от вашего лица."
                    ) {
                        TextField("Например: senior frontend, React/TS, 7 лет опыта", text: $settings.aboutMe, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...6)
                    }
                case 2:
                    wizardCard(
                        title: "Что слушаем?",
                        subtitle: "Микрофон — вашу речь. Система — звук собеседника из Zoom/Meet, нативно, без BlackHole."
                    ) {
                        Picker("", selection: Binding(
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
                default:
                    wizardCard(
                        title: "Backend",
                        subtitle: "Адрес сервиса транскрипции и ответов."
                    ) {
                        TextField("http://127.0.0.1:8000", text: $settings.backendHttpUrl)
                            .textFieldStyle(.roundedBorder)
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
                if step < 3 {
                    Button("Далее") { step += 1 }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                } else {
                    Button("Готово") {
                        settings.hasCompletedSetup = true
                        Task { await store.refreshBackendStatus() }
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                }
            }
            .frame(maxWidth: 480)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .onAppear { devices = AudioDevices.inputDevices() }
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
