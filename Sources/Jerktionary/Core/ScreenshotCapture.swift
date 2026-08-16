import AppKit
import CoreGraphics
import Foundation

/// Silent full-screen grab via the system `screencapture` tool.
///
/// Every visible side effect is deliberately off: no `-i`, so there is no
/// crosshair and the pointer never changes; no `-C`, so the cursor stays out of
/// the image; `-x` for no shutter sound; no `-u`, so no thumbnail appears
/// afterwards. Nothing on screen moves, and the app does not come forward.
///
/// `-m` limits the grab to the main display — with several monitors the tool
/// otherwise writes one file per screen, and the extras would be dropped.
///
/// The one thing outside this code's control is macOS itself: taking a screen
/// capture can light the screen-recording indicator, and recent versions remind
/// the user periodically which apps hold the permission.
enum ScreenshotCapture {
    enum Failure: LocalizedError {
        case permissionDenied
        case failed

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "No screen recording access. Allow it in System Settings → Privacy & Security → Screen Recording."
            case .failed:
                "Could not take the screenshot."
            }
        }
    }

    /// Grabs the main display without any on-screen feedback.
    static func captureScreen() async throws -> ChatAttachment {
        guard CGPreflightScreenCaptureAccess() else {
            // Surfaces the system prompt; the answer only takes effect for the
            // next attempt, so this call is reported as denied either way.
            CGRequestScreenCaptureAccess()
            throw Failure.permissionDenied
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jerktionary-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try await run(arguments: ["-x", "-m", "-t", "png", url.path])

        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let image = NSImage(data: data),
              let attachment = ChatImageLoader.attachment(from: image, name: "Screen")
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
