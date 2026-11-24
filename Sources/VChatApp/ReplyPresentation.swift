#if os(iOS)
import ActivityKit
import UIKit
import UserNotifications
import VChatCore

@MainActor enum ReplyPresentation {
    static let modeKey = "native.background-replies"
    static let islandKey = "native.reply-activity"
    static let activityNoticeKey = "native.last-reply-activity-notice"

    static func start(id: String, topicID: String, receivedBytes: Int) {
        guard UserDefaults.standard.object(forKey: islandKey) as? Bool != false else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            UserDefaults.standard.set("系统未允许 VChat 显示实时活动。", forKey:activityNoticeKey); return
        }
        guard UIApplication.shared.applicationState != .background,
              !Activity<ReplyActivityAttributes>.activities.contains(where: { $0.attributes.jobID == id && $0.activityState == .active }) else { return }
        let attributes = ReplyActivityAttributes(jobID: id, topicID: topicID, started: Date())
        do {
            _ = try Activity.request(attributes: attributes, content: ActivityContent(state: .init(phase: .waiting, receivedBytes: receivedBytes),
                staleDate: Date().addingTimeInterval(600)), pushType: nil)
            UserDefaults.standard.removeObject(forKey:activityNoticeKey)
        } catch {
            UserDefaults.standard.set("实时活动未启动：" + error.localizedDescription, forKey:activityNoticeKey)
        }
    }
    nonisolated static func update(id: String, receivedBytes: Int) async {
        for activity in Activity<ReplyActivityAttributes>.activities where activity.attributes.jobID == id && activity.activityState == .active {
            await activity.update(ActivityContent(state: .init(phase: .waiting, receivedBytes: receivedBytes),
                                                  staleDate: activity.attributes.started.addingTimeInterval(600)))
        }
    }
    nonisolated static func hideWaitingOnReturn(ids: Set<String>) async {
        for activity in Activity<ReplyActivityAttributes>.activities where ids.contains(activity.id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
    static func dismissOrphanedActivities(activeIDs: Set<String>) async {
        for activity in Activity<ReplyActivityAttributes>.activities where !activeIDs.contains(activity.attributes.jobID) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
    static func end(_ id: String, phase: ReplyActivityAttributes.ContentState.Phase) async {
        for activity in Activity<ReplyActivityAttributes>.activities where activity.attributes.jobID == id {
            await activity.end(ActivityContent(state: .init(phase: phase), staleDate: nil),
                               dismissalPolicy: phase == .stopped ? .immediate : .after(Date().addingTimeInterval(15)))
        }
    }
    // UNNotificationSettings itself isn't Sendable on the iOS 17/18 SDK.
    nonisolated static func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }
    static func notify(_ job: BackgroundReplyJob) async {
        guard UIApplication.shared.applicationState == .background else { return }
        let status = await authorizationStatus()
        guard [.authorized, .provisional, .ephemeral].contains(status),
              UIApplication.shared.applicationState == .background else { return }
        await enqueueNotification(for: job)
    }
    nonisolated private static func enqueueNotification(for job: BackgroundReplyJob) async {
        let request = notification(for: job)
        try? await UNUserNotificationCenter.current().add(request)
    }
    nonisolated static func notification(for job: BackgroundReplyJob) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "AI 回复已收到"; content.body = "轻点查看这条回复。"
        content.sound = .default; content.threadIdentifier = job.topicID; content.userInfo = ["topicID": job.topicID]
        return UNNotificationRequest(identifier: job.id, content: content, trigger: nil)
    }
}

@MainActor final class ReplyAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = ChatViewModel(coordinator: .shared)
    nonisolated(unsafe) private var protectedDataObserver: (any NSObjectProtocol)?

    deinit {
        if let protectedDataObserver {
            NotificationCenter.default.removeObserver(protectedDataObserver)
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Scene-based apps do not get the legacy app-delegate foreground callbacks.
        NotificationCenter.default.addObserver(self, selector: #selector(leavingForeground),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(returningToForeground),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        UNUserNotificationCenter.current().delegate = self
        let hasLocationKey = launchOptions?[.location] != nil
        let isBackgroundLaunch = hasLocationKey || (application.applicationState == .background)
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                _ = await LocationAcquisitionCoordinator.shared.handleProtectedDataBecameAvailable()
            }
        }
        if isBackgroundLaunch {
            Task { @MainActor in
                _ = await LocationAcquisitionCoordinator.shared.handleDidFinishLaunching(
                    launchHadLocationKey: hasLocationKey,
                    isBackgroundLaunch: true
                )
            }
        }
        return true
    }
    @objc private func leavingForeground() {
        // Start while still foreground-eligible, only for outstanding user requests.
        for room in model.rooms.values where room.busy && room.receivesInBackground && !room.cancelled {
            if let id = room.backgroundJobID { ReplyPresentation.start(id: id, topicID: room.id, receivedBytes: room.receivedReplyBytes) }
        }
    }
    @objc private func returningToForeground() {
        let ids = Set(Activity<ReplyActivityAttributes>.activities.compactMap { $0.content.state.phase == .waiting ? $0.id : nil })
        Task { await ReplyPresentation.hideWaitingOnReturn(ids: ids) }
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundReplyTransfers.identifier else { completionHandler(); return }
        if application.applicationState == .background { model.backgrounded = true }
        model.replyTransfers.handleWake(completionHandler)
        Task { await model.load() }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let topic = response.notification.request.content.userInfo["topicID"] as? String else { return }
        await MainActor.run { model.requestedReplyTopic = topic }
    }
}
#endif
