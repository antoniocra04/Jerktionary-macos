// SwiftPM's `platforms:` only sets a minimum macOS version — Xcode still offers
// iOS/watchOS destinations for any package and often defaults to an iPhone,
// which has no AppKit/Carbon/ScreenCaptureKit. Fail fast with a clear message.
#if !os(macOS)
#error("Jerktionary is a macOS-only app. In Xcode pick the “My Mac” destination (the control next to the scheme selector).")
#endif

// Building with an older SDK silently changes SwiftUI's linked-on-or-after
// appearance and omits macOS 26 components such as Liquid Glass. GitHub uses
// the macOS 26 toolchain, so reject visually incompatible local builds instead
// of presenting them as a valid preview of the app.
#if !compiler(>=6.2)
#error("Jerktionary requires Swift 6.2+ and the macOS 26 SDK so a local build looks like the GitHub build. Update Command Line Tools for Xcode.")
#endif
