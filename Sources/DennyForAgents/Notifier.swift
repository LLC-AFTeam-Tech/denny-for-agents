import AgentCore
import Foundation
import UserNotifications

/// macOS notifications plus the user's alert settings, kept in UserDefaults.
final class Notifier {
    private static let settingsKey = "alertSettings"
    private static let sentKey = "alertsSent"

    private let defaults = UserDefaults.standard
    private var askedForPermission = false

    var settings: AlertSettings {
        get {
            defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(AlertSettings.self, from: $0) }
                ?? AlertSettings()
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.settingsKey)
        }
    }

    var tracker: AlertTracker {
        get { AlertTracker(sent: defaults.stringArray(forKey: Self.sentKey) ?? []) }
        set { defaults.set(newValue.sent, forKey: Self.sentKey) }
    }

    func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if askedForPermission {
            send()
            return
        }
        askedForPermission = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { send() }
        }
    }
}
