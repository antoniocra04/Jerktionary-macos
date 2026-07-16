// SwiftPM's `platforms:` only sets a minimum macOS version — Xcode still offers
// iOS/watchOS destinations for any package and often defaults to an iPhone,
// which has no AppKit/Carbon/ScreenCaptureKit. Fail fast with a clear message.
#if !os(macOS)
#error("Jerktionary — приложение только для macOS. В Xcode выберите destination «My Mac» (панель рядом с выбором схемы).")
#endif
