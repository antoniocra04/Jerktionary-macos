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
            Section("Answer service") {
                TextField("Service address", text: $settings.backendHttpUrl)
                    .onSubmit { checkBackend() }
                Button(checkingBackend ? "Checking…" : "Check connection") {
                    checkBackend()
                }
                .disabled(!settings.hasValidBackendUrl || checkingBackend)
                if store.backendStatusLoaded {
                    Label(
                        store.backendReady ? "Service ready" : "Not connected",
                        systemImage: store.backendReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(store.backendReady ? .green : .orange)
                }
            }

            Section("Audio") {
                Picker("Source", selection: Binding(
                    get: { settings.audioSource },
                    set: { settings.audioSource = $0 }
                )) {
                    ForEach(AudioSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                if settings.audioSource == .microphone {
                    Picker("Microphone", selection: $settings.audioInputDeviceUID) {
                        Text("Default").tag("")
                        ForEach(devices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                }
            }

            Section("Profile") {
                TextField("Window name", text: $settings.displayName)
                    .onSubmit { WindowController.setTitle(settings.displayName) }
                TextField("About me", text: $settings.aboutMe, axis: .vertical)
                    .lineLimit(3...6)
            }

            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Chat") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Models, one per line", text: $settings.chatModelsRaw, axis: .vertical)
                        .lineLimit(3...8)
                        .font(.system(.body, design: .monospaced))
                }
                TextField("System prompt", text: $settings.chatSystemPrompt, axis: .vertical)
                    .lineLimit(2...6)
                VStack(alignment: .leading, spacing: 4) {
                    TextField(
                        "Question asked about a screenshot",
                        text: $settings.chatScreenshotPrompt,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                }
            }

            Section("Help") {
                DisclosureGroup("Keyboard shortcuts") {
                    LabeledContent("Answer now", value: "Ctrl+Shift+Space")
                    LabeledContent("Answer with full context", value: "Ctrl+Shift+Enter")
                    LabeledContent("Compact card", value: "Ctrl+Shift+O")
                    LabeledContent("Screenshot to chat", value: "Ctrl+Shift+S")
                }
                Text("Transcription never starts an answer on its own — every request is yours to confirm.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                DisclosureGroup("Technical details") {
                    LabeledContent("Address", value: settings.normalizedHttpUrl)
                    if !chats.capabilities.label.isEmpty {
                        LabeledContent("Provider", value: chats.capabilities.label)
                        LabeledContent(
                            "Default model",
                            value: chats.capabilities.defaultModel.isEmpty ? "—" : chats.capabilities.defaultModel
                        )
                    }
                    if !store.backendComponents.isEmpty {
                        ComponentsListView(components: store.backendComponents)
                    }
                    Button("Open web diagnostics") {
                        if let url = settings.swaggerUrl { NSWorkspace.shared.open(url) }
                    }
                }
            }

            Section {
                Button("Run setup again") {
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
                Text("Set up Jerktionary")
                    .font(.largeTitle.weight(.semibold))
                Text("Step \(step + 1) of \(stepCount)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Group {
                switch step {
                case 0:
                    wizardCard(
                        title: "Profile",
                        subtitle: "The window name masks what the app is for, and the profile shapes how answers are phrased."
                    ) {
                        TextField("Window title", text: $settings.displayName)
                            .textFieldStyle(.roundedBorder)
                        TextField("For example: senior frontend, React/TS, 7 years of experience", text: $settings.aboutMe, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...6)
                    }
                case 1:
                    wizardCard(
                        title: "What are we listening to?",
                        subtitle: "The microphone hears you. System audio hears the other side from your calling app."
                    ) {
                        Picker("Audio source", selection: Binding(
                            get: { settings.audioSource },
                            set: { settings.audioSource = $0 }
                        )) {
                            ForEach(AudioSource.allCases) { source in
                                Text(source.label).tag(source)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if settings.audioSource == .microphone {
                            Picker("Microphone", selection: $settings.audioInputDeviceUID) {
                                Text("Default").tag("")
                                ForEach(devices) { device in
                                    Text(device.name).tag(device.uid)
                                }
                            }
                        }
                    }
                case 2:
                    wizardCard(
                        title: "Permissions",
                        subtitle: "macOS requires a separate permission for the source you picked."
                    ) {
                        permissionRow
                    }
                    .id(permissionRefresh)
                case 3:
                    wizardCard(
                        title: "Answer service",
                        subtitle: "Check the connection before the call starts."
                    ) {
                        TextField("http://127.0.0.1:8000", text: $settings.backendHttpUrl)
                            .textFieldStyle(.roundedBorder)
                        if !settings.hasValidBackendUrl {
                            Label("Enter a valid HTTP or HTTPS address", systemImage: "exclamationmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                        Button(checkingService ? "Checking…" : "Check connection") {
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
                                    ? "Service ready"
                                    : (store.backendReady
                                       ? "Check this address"
                                       : "Connection not established"),
                                systemImage: serviceIsVerified
                                    ? "checkmark.circle.fill"
                                    : "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(serviceIsVerified ? .green : .orange)
                        }
                    }
                default:
                    wizardCard(
                        title: "Ready for the call",
                        subtitle: "Jerktionary listens continuously but only prepares an answer when you ask."
                    ) {
                        readinessRow("Source selected", ready: true)
                        readinessRow("Permission granted", ready: requiredPermissionGranted)
                        readinessRow("Answer service ready", ready: serviceIsVerified)
                        Text("Ctrl+Shift+Space — answer now")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 480)

            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
                Spacer()
                if step < stepCount - 1 {
                    Button("Next") { step += 1 }
                        .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(!canContinue)
                } else {
                    Button("Done") {
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
            readinessRow("Microphone access", ready: microphoneGranted)
            if !microphoneGranted {
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    Button("Allow the microphone") {
                        Task {
                            _ = await AVCaptureDevice.requestAccess(for: .audio)
                            permissionRefresh += 1
                        }
                    }
                } else {
                    Button("Open macOS settings") {
                        openPrivacySettings("Privacy_Microphone")
                    }
                }
            }
        } else {
            readinessRow("System audio recording", ready: screenCaptureGranted)
            if !screenCaptureGranted {
                HStack {
                    Button("Request access") {
                        CGRequestScreenCaptureAccess()
                        permissionRefresh += 1
                    }
                    Button("Open macOS settings") {
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
