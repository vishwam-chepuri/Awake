import Foundation
import UserNotifications

/// Thin wrapper over UNUserNotificationCenter.
///
/// Guarded on a bundle identifier: `UNUserNotificationCenter.current()` traps in an
/// unbundled process, which is exactly how the check runner executes. Everything
/// here is best-effort — a session must never fail because a banner didn't post.
public enum Notifier {
    public static var isSupported: Bool { Bundle.main.bundleIdentifier != nil }

    public static func requestAuthorization() {
        guard isSupported else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public static func post(title: String, body: String) {
        guard isSupported else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
