import Foundation
import UserNotifications

/// 小梦主动 · 发送通道（第四刀，策略 B）。
/// 打分仍只入草稿。设置页手动发。通知走 UNUserNotificationCenter，
/// userInfo.sessionId 复用 ShortcutNotificationDelegate 进会话。
/// 前缀 `active-reach.` 便于 cancelPending 只拆本功能的通知。

enum ActiveReachSendError: String, Error {
    case masterOff
    case notAuthorized
    case capExhausted
    case emptyText
    case scheduleFailed
    case missingDraft
    /// 目标会话已删 / 不存在：拦发送，不记账、不排通知。
    case sessionGone
}

struct SendReceipt: Equatable {
    var notificationId: String
    var dialogId: String
    var usedBreak: Bool
    var openFallback: Bool
}

enum ActiveReachSend {
    static let idPrefix = "active-reach."
    static let categoryId = "ACTIVE_REACH"
    static let sentKey = "activeReach.sent.v1"
    static let sentLimit = 20
    static let openActionId = "open"

    /// 纯记账：成功才由调用方 +count。名额不够返回 capExhausted。
    static func prepareSend(
        draft: ActiveReachDraft,
        snapshot: inout ActiveReachSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> Result<Bool, ActiveReachSendError> {
        guard snapshot.enabled else { return .failure(.masterOff) }
        ActiveReachLogic.resetCountsIfNeeded(&snapshot, now: now, calendar: calendar)
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.emptyText) }
        if draft.wouldBreak {
            guard snapshot.dailyBreakCount < snapshot.dailyBreakCap else {
                return .failure(.capExhausted)
            }
            return .success(true)
        }
        guard snapshot.dailyCapCount < snapshot.dailyCap else {
            return .failure(.capExhausted)
        }
        return .success(false)
    }

    static func applyCount(usedBreak: Bool, snapshot: inout ActiveReachSnapshot) {
        if usedBreak {
            snapshot.dailyBreakCount += 1
        } else {
            snapshot.dailyCapCount += 1
        }
    }

    static func notificationId(for draftId: String) -> String {
        idPrefix + draftId
    }

    static func isOurs(_ identifier: String) -> Bool {
        identifier.hasPrefix(idPrefix)
    }

    static func cancelOurs() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            let ids = reqs.map(\.identifier).filter(isOurs)
            if !ids.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
        center.getDeliveredNotifications { notes in
            let ids = notes.map(\.request.identifier).filter(isOurs)
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    static func requestAuthorization() async -> UNAuthorizationStatus {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return settings.authorizationStatus
        case .denied:
            return .denied
        case .notDetermined:
            do {
                let ok = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                return ok ? .authorized : .denied
            } catch {
                return .denied
            }
        @unknown default:
            return settings.authorizationStatus
        }
    }

    static func schedule(draft: ActiveReachDraft) async -> Result<String, ActiveReachSendError> {
        let status = await requestAuthorization()
        switch status {
        case .denied:
            return .failure(.notAuthorized)
        default:
            break
        }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.emptyText) }

        let center = UNUserNotificationCenter.current()
        let open = UNNotificationAction(
            identifier: openActionId,
            title: "打开",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: [open],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])

        let content = UNMutableNotificationContent()
        content.title = "小梦"
        content.body = text
        content.sound = .default
        content.categoryIdentifier = categoryId
        content.userInfo = [
            "sessionId": draft.dialogId,
            "activeReach": true,
            "draftId": draft.id
        ]
        let nid = notificationId(for: draft.id)
        let request = UNNotificationRequest(
            identifier: nid,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            return .success(nid)
        } catch {
            return .failure(.scheduleFailed)
        }
    }

    static func loadSent(from defaults: UserDefaults) -> [ActiveReachDraft] {
        guard let data = defaults.data(forKey: sentKey),
              let decoded = try? JSONDecoder().decode([ActiveReachDraft].self, from: data)
        else { return [] }
        return decoded
    }

    static func encodeSent(_ items: [ActiveReachDraft]) -> Data? {
        try? JSONEncoder().encode(items)
    }

    static func prependSent(
        _ draft: ActiveReachDraft,
        onto list: [ActiveReachDraft],
        limit: Int = sentLimit
    ) -> [ActiveReachDraft] {
        Array(([draft] + list).prefix(limit))
    }

    /// 把主动那句写进目标会话，点开通知才能认领「我说的」。
    /// 写库失败只打日志，不回滚已成功的通知与 cap（通知已出）。
    @MainActor
    static func persistAssistantBubble(sessionId: String, text: String) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty, !body.isEmpty else { return }
        let exists = await ChatStore.shared.getSession(sessionId) != nil
        guard exists else {
            // 会话没了就别造气泡，避免脏 id。
            return
        }
        let raw = RawMessage(
            id: UUID().uuidString.lowercased(),
            sessionId: sessionId,
            role: .assistant,
            parts: [.text(body)],
            createdAt: Date(),
            tokenUsage: nil,
            reasoningContent: nil,
            streamInterruptCount: 0,
            sortOrder: 0
        )
        await ChatStore.shared.appendMessage(raw)
    }
}
