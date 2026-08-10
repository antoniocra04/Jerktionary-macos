import Foundation

/// The microphone RMS level, deliberately kept out of AppStore.
///
/// Capture emits a level per audio chunk — 4096 source frames, about 12 times a
/// second. As an `@Published` property on AppStore that invalidated every view
/// observing the store (the transcript, the notes editor, the sidebar), so a
/// long transcript was re-laid-out ~12 times a second while nothing about it
/// had changed. Its own observable object keeps that churn inside the meter.
@MainActor
final class AudioLevelModel: ObservableObject {
    @Published var level: Double = 0
}
