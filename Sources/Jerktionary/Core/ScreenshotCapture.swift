import AppKit
import CoreGraphics
import Foundation

/// Interactive region screenshot via the system `screencapture` tool.
///
/// Deliberately not ScreenCaptureKit: the point is the crosshair selection the
/// user already knows from Cmd+Shift+4, and reimplementing that overlay would be
/// a lot of code to arrive at something less familiar. The app window itself is
/// excluded from capture (content protection), so dragging a selection across it
/// records what is behind it — which is what you want when asking about
/// something on screen.
enum ScreenshotCapture {
    enum Failure: LocalizedError {
        case permissionDenied
        case failed

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "Нет доступа к записи экрана. Разрешите в System Settings → Privacy & Security → Screen Recording."
            case .failed:
                "Не удалось сделать снимок экрана."
            }
        }
    }

    /// Runs the region selector. Returns nil when the user cancels with Esc,
    /// which is a normal outcome and not an error.
    static func captureRegion() async throws -> ChatAttachment? {
        guard CGPreflightScreenCaptureAccess() else {
            // Surfaces the system prompt; the answer only takes effect for the
            // next attempt, so this call is reported as denied either way.
            CGRequestScreenCaptureAccess()
            throw Failure.permissionDenied
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jerktionary-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try await run(arguments: ["-i", "-x", url.path])

        // Cancelling leaves no file behind — the one case that isn't a failure.
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        guard let image = NSImage(data: data),
              let attachment = ChatImageLoader.attachment(from: image, name: "Снимок экрана")
        else { throw Failure.failed }
        return attachment
    }

    private static func run(arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = arguments
            process.terminationHandler = { _ in
                // A non-zero status also means "cancelled" on some releases, so
                // the caller decides by whether a file appeared.
                continuation.resume()
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: Failure.failed)
            }
        }
    }
}
