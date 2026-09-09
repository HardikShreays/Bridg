import Foundation
import UserNotifications
import GRDB

/// Manages receiving phone notifications and displaying them on Mac.
/// Stores notification history in SQLite via GRDB.
class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let notificationCenter = UNUserNotificationCenter.current()
    private var database: DatabaseQueue?

    static let replyActionId = "BRIDG_REPLY"
    static let replyCategoryId = "BRIDG_REPLY_CATEGORY"
    static let answerActionId = "BRIDG_CALL_ANSWER"
    static let declineActionId = "BRIDG_CALL_DECLINE"
    static let callCategoryId = "BRIDG_CALL_CATEGORY"

    /// (notificationId, actionId, replyText) — set by AppState so replies reach the phone.
    var onReply: ((String, String, String) -> Void)?

    /// Answer / reject a ringing phone call from the Mac. Set by AppState.
    var onCallAction: ((BridgProtoCallControl.Action) -> Void)?

    /// The user cleared a banner here; the phone should clear it too.
    /// Set by AppState.
    var onDismiss: ((String) -> Void)?

    override init() {
        super.init()
        notificationCenter.delegate = self
        registerReplyCategory()
        setupDatabase()
        // Defer: called straight from AppState's @StateObject init, this runs
        // before the app finishes launching and the framework just answers
        // "Notifications are not allowed" without ever prompting.
        DispatchQueue.main.async { [weak self] in self?.requestAuthorization() }
    }

    /// Registered once at startup. The old code rebuilt the whole category set
    /// on every incoming notification, silently killing Reply on earlier ones.
    private func registerReplyCategory() {
        let replyAction = UNTextInputNotificationAction(
            identifier: Self.replyActionId,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a reply..."
        )
        let answerAction = UNNotificationAction(
            identifier: Self.answerActionId,
            title: "Answer",
            options: [.foreground]
        )
        let declineAction = UNNotificationAction(
            identifier: Self.declineActionId,
            title: "Decline",
            options: [.destructive]
        )
        notificationCenter.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.replyCategoryId,
                actions: [replyAction],
                intentIdentifiers: [],
                options: .customDismissAction
            ),
            UNNotificationCategory(
                identifier: Self.callCategoryId,
                actions: [answerAction, declineAction],
                intentIdentifiers: [],
                options: .customDismissAction
            )
        ])
    }

    // MARK: - Authorization

    private func requestAuthorization() {
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error = error {
                print("Notification authorization error: \(error)")
            }
        }
    }

    // MARK: - Display Notification

    /// Display a phone notification on the Mac.
    func displayNotification(_ event: BridgProtoNotificationEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title.isEmpty ? event.appLabel : event.title
        content.subtitle = event.appLabel
        content.body = event.text
        content.sound = .default

        // Ringing call → Answer/Decline; otherwise reply support if available.
        if event.isCall {
            content.categoryIdentifier = Self.callCategoryId
            if #available(macOS 12.0, *) { content.interruptionLevel = .timeSensitive }
        } else if event.hasReplyAction_p {
            content.categoryIdentifier = Self.replyCategoryId
        }

        // Group by package name
        content.threadIdentifier = event.packageName

        let request = UNNotificationRequest(
            identifier: event.id,
            content: content,
            trigger: nil
        )

        notificationCenter.add(request) { error in
            if let error = error {
                print("Failed to post notification: \(error)")
            }
        }

        storeNotification(event)
    }

    func dismissNotification(id: String) {
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [id])
    }

    // MARK: - Notification History

    func getHistory(limit: Int = 100) -> [StoredNotification] {
        var notifications: [StoredNotification] = []

        do {
            try database?.read { db in
                notifications = try StoredNotification
                    .order(Column("timestamp").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            print("Failed to fetch history: \(error)")
        }

        return notifications
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier

        switch response.actionIdentifier {
        case Self.replyActionId:
            if let textInput = response as? UNTextInputNotificationResponse {
                sendReply(notificationId: identifier, replyText: textInput.userText)
            }
        case Self.answerActionId:
            onCallAction?(.answer)
        case Self.declineActionId:
            onCallAction?(.reject)
            dismissNotification(id: identifier)
        case UNNotificationDismissActionIdentifier:
            onDismiss?(identifier)
        default:
            break
        }

        completionHandler()
    }

    // MARK: - Private

    private func sendReply(notificationId: String, replyText: String) {
        // This used to build an envelope and then drop it on the floor.
        onReply?(notificationId, notificationId, replyText)
    }

    private func setupDatabase() {
        do {
            let dbPath = NSSearchPathForDirectoriesInDomains(
                .applicationSupportDirectory, .userDomainMask, true
            ).first! + "/Bridg/notifications.db"

            let dbDir = (dbPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dbDir, withIntermediateDirectories: true)

            let db = try DatabaseQueue(path: dbPath)
            self.database = db

            try db.write { db in
                try db.create(table: "notifications", ifNotExists: true) { t in
                    t.column("id", .text).primaryKey()
                    t.column("package_name", .text)
                    t.column("app_label", .text)
                    t.column("title", .text)
                    t.column("text_content", .text)
                    t.column("timestamp", .datetime)
                    t.column("has_reply_action", .boolean)
                }
            }
        } catch {
            print("Database setup error: \(error)")
        }
    }

    private func storeNotification(_ event: BridgProtoNotificationEvent) {
        do {
            try database?.write { db in
                var notification = StoredNotification(
                    id: event.id,
                    packageName: event.packageName,
                    appLabel: event.appLabel,
                    title: event.title,
                    textContent: event.text,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(event.timestamp) / 1000),
                    hasReplyAction: event.hasReplyAction_p
                )
                // `insert` throws on a duplicate primary key. Android reposts the
                // same notification id constantly for ordinary updates (an
                // unread count ticking up, a download's progress) — with
                // `insert`, only the very first post of any given id was ever
                // stored, and every update after that silently failed and was
                // dropped. `save` is insert-or-replace, matching how a live
                // notification actually behaves.
                try notification.save(db)
            }
        } catch {
            print("Failed to store notification: \(error)")
        }
    }
}

struct StoredNotification: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "notifications"

    let id: String
    let packageName: String
    let appLabel: String
    let title: String
    let textContent: String
    let timestamp: Date
    let hasReplyAction: Bool

    /// GRDB maps Swift property names straight to column names by default —
    /// without this, every insert failed with "no column named packageName"
    /// against this table's snake_case schema, and no notification was ever
    /// actually stored.
    enum CodingKeys: String, CodingKey {
        case id
        case packageName = "package_name"
        case appLabel = "app_label"
        case title
        case textContent = "text_content"
        case timestamp
        case hasReplyAction = "has_reply_action"
    }
}
