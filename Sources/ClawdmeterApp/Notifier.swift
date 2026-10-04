import ClawdmeterCore
import Foundation
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    // Notifications need an app bundle; without one (e.g. `swift run`) they are skipped.
    private let center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier == nil ? nil : .current()
    private var asked = false

    override init() {
        super.init()
        center?.delegate = self
    }

    func post(_ event: AppEvent, sessionId: String? = nil, sound: Bool) {
        guard let center else { return }
        if !asked {
            asked = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        switch event {
        case .finished(_, let name, let duration):
            content.title = "\(name) is done"
            content.body = "Claude finished after \(elapsed(from: .now.addingTimeInterval(-duration), to: .now, coarse: true))."
        case .needsYou(_, let name):
            content.title = "\(name) needs you"
            content.body = "Claude is waiting for your answer."
        case .limitCrossed(let label, let threshold):
            content.title = "\(label) limit at \(threshold)%"
            content.body = threshold >= 95 ? "You're about to run out." : "Worth pacing yourself."
        case .limitReset(let label):
            content.title = "\(label) limit reset"
            content.body = "You have your full allowance again."
        }
        if let sessionId { content.userInfo = ["sessionId": sessionId] }
        if sound { content.sound = .default }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["sessionId"] as? String else { return }
        await MainActor.run { onOpen?(id) }
    }
}
