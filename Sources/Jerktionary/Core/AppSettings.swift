import Foundation
import SwiftUI

enum AudioSource: String, CaseIterable, Identifiable {
    case microphone
    case system
    var id: String { rawValue }

    var russianLabel: String {
        switch self {
        case .microphone: "Микрофон"
        case .system: "Система"
        }
    }
}

/// What the compact overlay shows. Kept small on purpose: the card is meant to
/// be glanced at, not worked in.
enum OverlayPane: String, CaseIterable, Identifiable {
    case live
    case chat
    var id: String { rawValue }

    var russianLabel: String {
        switch self {
        case .live: "Эфир"
        case .chat: "Чат"
        }
    }

    var systemImage: String {
        switch self {
        case .live: "waveform.and.mic"
        case .chat: "bubble.left.and.bubble.right"
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var russianLabel: String {
        switch self {
        case .system: "Как в macOS"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }
}

/// Persistent user settings, the SwiftUI counterpart of the web settings store.
@MainActor
final class AppSettings: ObservableObject {
    static let defaultDisplayName = "Jerktionary"
    static let defaultBackendHttpUrl = "http://127.0.0.1:8000"

    @AppStorage("settings.backendHttpUrl") var backendHttpUrl = AppSettings.defaultBackendHttpUrl
    @AppStorage("settings.displayName") var displayName = AppSettings.defaultDisplayName
    /// Persistent "about me": role, stack, experience — personalizes live answers.
    @AppStorage("settings.aboutMe") var aboutMe = ""
    @AppStorage("settings.audioSource") private var audioSourceRaw = AudioSource.microphone.rawValue
    /// CoreAudio device UID of the preferred microphone; empty = system default.
    @AppStorage("settings.audioInputDeviceUID") var audioInputDeviceUID = ""
    @AppStorage("settings.theme") private var themeRaw = AppTheme.system.rawValue
    @AppStorage("settings.hasCompletedSetup") var hasCompletedSetup = false
    /// Background transparency of the compact overlay card. It shades the
    /// material only — never the text, which the old whole-panel alpha took to
    /// roughly 1.5:1 at the bottom of its range. The floor keeps the card
    /// findable on a busy desktop without making the control cosmetic.
    static let overlayOpacityRange = 0.70...1.0
    @AppStorage("settings.overlayOpacity") var overlayOpacity = 0.85
    /// Which pane the compact overlay shows.
    @AppStorage("settings.overlayPane") private var overlayPaneRaw = OverlayPane.live.rawValue

    var overlayPane: OverlayPane {
        get {
            if overlayPaneRaw == "answer" || overlayPaneRaw == "transcript" { return .live }
            return OverlayPane(rawValue: overlayPaneRaw) ?? .live
        }
        set { overlayPaneRaw = newValue.rawValue }
    }

    /// Models offered in the chat tab, one per line. Kept as a hand-written list
    /// on purpose: providers disagree on whether /v1/models exists and what it
    /// returns, so a fetched list would be empty for some and unusable for others.
    /// Empty means "whatever the backend was started with".
    @AppStorage("settings.chatModels") var chatModelsRaw = ""
    /// Optional system prompt prepended to every chat conversation.
    @AppStorage("settings.chatSystemPrompt") var chatSystemPrompt = ""
    /// Asked automatically about a screenshot taken with Ctrl+Shift+S. Empty
    /// leaves the shot in the composer so a question can be typed instead —
    /// sending an image with no question usually wastes the request.
    @AppStorage("settings.chatScreenshotPrompt") var chatScreenshotPrompt = ""

    init() {
        // Earlier releases allowed values that made foreground contrast depend
        // too heavily on whatever happened to be behind the floating panel.
        overlayOpacity = min(
            Self.overlayOpacityRange.upperBound,
            max(Self.overlayOpacityRange.lowerBound, overlayOpacity)
        )
    }

    var chatModels: [String] {
        chatModelsRaw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var audioSource: AudioSource {
        get { AudioSource(rawValue: audioSourceRaw) ?? .microphone }
        set { audioSourceRaw = newValue.rawValue }
    }

    var theme: AppTheme {
        get { AppTheme(rawValue: themeRaw) ?? .light }
        set { themeRaw = newValue.rawValue }
    }

    var normalizedHttpUrl: String {
        var cleaned = backendHttpUrl
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !cleaned.isEmpty else { return Self.defaultBackendHttpUrl }
        // A schemeless "192.168.0.17:8000" produces broken URLs (the host is
        // parsed as the scheme) and the http→ws rewrite never matches.
        let lowercased = cleaned.lowercased()
        if !lowercased.hasPrefix("http://"), !lowercased.hasPrefix("https://") {
            cleaned = "http://" + cleaned
        }
        return cleaned
    }

    var hasValidBackendUrl: Bool {
        let value = backendHttpUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let url = URL(string: normalizedHttpUrl),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return false }
        return true
    }

    var websocketUrl: URL? {
        let ws = normalizedHttpUrl.replacingOccurrences(
            of: "^http", with: "ws", options: [.regularExpression, .caseInsensitive]
        )
        return URL(string: "\(ws)/ws/audio")
    }

    var swaggerUrl: URL? { URL(string: "\(normalizedHttpUrl)/docs") }
}
