//
//  ThemeWriteConfirmation.swift
//  MinisApp
//
//  [T-02] User confirmation for destructive `minis-theme` writes.
//
//  Before this file an AI turn could delete a saved theme, rename one,
//  overwrite either avatar, replace a wallpaper or reset the whole pack
//  with no user-facing step at all. `reset --force` looked like a
//  confirmation but the flag is written by the AI itself, so it never
//  involved the user.
//
//  Ordinary colour and pack applies stay immediate and reversible — the
//  Ask Once permission gate (OffloadPermissionManager) is what makes the
//  AI's first theme write in a session ask. This type is only for actions
//  that destroy something, and it reuses the minis-config confirm gate
//  (same queue, same sheet, same timeout semantics) rather than growing a
//  second confirmation UI.
//

import Foundation

@MainActor
enum ThemeWriteConfirmation {

    enum Decision {
        case approved
        case rejected
        case timedOut

        /// The bridge's failure payload, or nil when approved.
        var refusal: [String: Any]? {
            switch self {
            case .approved: return nil
            case .rejected:
                return ["ok": false, "error": "rejected",
                        "message": "The user declined this theme change; nothing was changed."]
            case .timedOut:
                return ["ok": false, "error": "confirmation_timeout",
                        "message": "No confirmation within the wait window; nothing was changed."]
            }
        }
    }

    /// Waits for the confirmation gate's own window plus slack, so the CLI
    /// never gives up before the user can answer.
    ///
    /// Deliberately a literal: read from a nonisolated bridge method, so it
    /// cannot touch the main-actor gate's constant. 120s is
    /// `ConfigConfirmationGate.timeoutSeconds`; 30s is the slack.
    nonisolated static let waitWindow: TimeInterval = 150

    /// - Parameters:
    ///   - action: command name shown to the user, e.g. `delete`.
    ///   - what: one line naming the thing being changed.
    ///   - detail: what is lost, in plain words.
    ///   - verb: row verb shown in the sheet.
    static func check(_ action: String, what: String, detail: String,
                    verb: String = "delete") async -> Decision {
        let item = PendingConfigChangeItem(
            id: UUID().uuidString,
            displayName: what,
            path: "minis-theme \(action)",
            oldDisplay: detail,
            newDisplay: "",
            verb: verb,
            risk: .destructive)
        let change = PendingConfigChange(
            items: [item],
            caption: "AI 请求执行主题操作：minis-theme \(action)")
        switch await ConfigConfirmationGate.shared.requestConfirmation(change) {
        case .approved(let items):
            return items.contains(where: { $0.id == item.id && $0.isApproved }) ? .approved : .rejected
        case .rejected:
            return .rejected
        case .timedOut:
            return .timedOut
        case .pending:
            return .rejected
        }
    }
}