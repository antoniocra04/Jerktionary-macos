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
    case answer
    case chat
    case transcript
    var id: String { rawValue }

    var russianLabel: String {
        switch self {
        case .answer: "Ответ"
        case .chat: "Чат"
        case .transcript: "Транскрипт"
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
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
    @AppStorage("settings.theme") private var themeRaw = AppTheme.light.rawValue
    @AppStorage("settings.hasCompletedSetup") var hasCompletedSetup = false
    /// Transparency of the compact overlay card, 0.25...1.
    @AppStorage("settings.overlayOpacity") var overlayOpacity = 0.9
    /// Which pane the compact overlay shows.
    @AppStorage("settings.overlayPane") private var overlayPaneRaw = OverlayPane.answer.rawValue

    var overlayPane: OverlayPane {
        get { OverlayPane(rawValue: overlayPaneRaw) ?? .answer }
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

    var websocketUrl: URL? {
        let ws = normalizedHttpUrl.replacingOccurrences(
            of: "^http", with: "ws", options: [.regularExpression, .caseInsensitive]
        )
        return URL(string: "\(ws)/ws/audio")
    }

    var swaggerUrl: URL? { URL(string: "\(normalizedHttpUrl)/docs") }
}
