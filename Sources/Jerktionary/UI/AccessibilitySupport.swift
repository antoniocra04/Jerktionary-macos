import Accessibility

@MainActor
enum AccessibilityAnnouncer {
    static func announce(_ message: String) {
        guard !message.isEmpty else { return }
        AccessibilityNotification.Announcement(message).post()
    }
}
