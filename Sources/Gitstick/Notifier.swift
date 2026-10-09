import AppKit
import UserNotifications

/// Tells you what needs you after you walked away: a conflict copy was made, a file was held back,
/// a push was diverted, a drive can't sync. Clicking a notification shows the drive in Finder.
///
/// Notifications need a bundle identifier, so this does nothing under `swift run`; the .app from
/// `Scripts/make-app.sh` has one.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let available = Bundle.main.bundleIdentifier != nil

    /// Called on the main thread with the drive id when a notification is clicked.
    var onOpen: ((String) -> Void)?

    override init() {
        super.init()
        guard Self.available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `key` makes repeats of the same news replace each other instead of piling up.
    func notify(drive id: String, key: String, title: String, body: String) {
        guard Self.available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = id
        content.userInfo = ["drive": id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["drive"] as? String
        DispatchQueue.main.async {
            if let id { self.onOpen?(id) }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
