// MeetingPromptNotification.swift
// PRISM
//
// The actionable local notification shown when a supported meeting client
// starts using PRISM. The notification is a question, never an instruction:
// only its explicit Start action begins the existing Meeting mode.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import UserNotifications

enum MeetingPromptNotification {
    static let categoryIdentifier = "PRISM_MEETING_PROMPT"
    static let startActionIdentifier = "PRISM_START_MEETING_MODE"
    static let notNowActionIdentifier = "PRISM_NOT_NOW"
    static let signingIDKey = "PRISMMeetingSigningID"
    private static let requestPrefix = "horse.prism.meeting-prompt."

    static func registerActions() {
        let start = UNNotificationAction(identifier: startActionIdentifier,
                                         title: "Start Meeting Mode")
        let notNow = UNNotificationAction(identifier: notNowActionIdentifier,
                                          title: "Not Now")
        let category = UNNotificationCategory(identifier: categoryIdentifier,
                                              actions: [start, notNow],
                                              intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func post(_ candidate: MeetingJoinCandidate) {
        let content = UNMutableNotificationContent()
        content.title = "Start Meeting mode?"
        content.subtitle = candidate.applicationName
        content.body = "PRISM can transcribe this call locally. Audio is not saved, and nothing starts unless you approve."
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = categoryIdentifier
        content.userInfo = [signingIDKey: candidate.signingID]

        let request = UNNotificationRequest(
            identifier: requestIdentifier(for: candidate.signingID),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func remove(for signingIDs: [String]) {
        let identifiers = signingIDs.map { requestIdentifier(for: $0) }
        guard !identifiers.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    static func removeAll() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(requestPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        center.getDeliveredNotifications { notifications in
            let ids = notifications.map { $0.request.identifier }
                .filter { $0.hasPrefix(requestPrefix) }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    static func signingID(from response: UNNotificationResponse) -> String? {
        response.notification.request.content.userInfo[signingIDKey] as? String
    }

    private static func requestIdentifier(for signingID: String) -> String {
        requestPrefix + signingID.lowercased()
    }
}
