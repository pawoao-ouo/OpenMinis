import Foundation
import UIKit

/// [B28 R10] Code blocks can be fullscreen-edited from collection cells, where
/// the SwiftUI view may not own the chat VM. This router keeps the view decoupled
/// from AIChatViewModel while still letting the active session persist edits.
struct ChatCodeBlockEditRequest {
    let messageId: UUID
    let blockId: UUID?
    let sourceMarkdown: String
    let codeIndex: Int
    let oldCode: String
    let newCode: String
    let language: String?
}

enum ChatCodeBlockEditRouter {
    static weak var current: AIChatViewModel?
}

extension AIChatViewModel {
    func saveEditedCodeBlock(_ request: ChatCodeBlockEditRequest) -> Bool {
        guard request.oldCode != request.newCode else {
            MinisToast.show(AppLocalized("代码没有改动"))
            return false
        }
        guard let messageIndex = messages.firstIndex(where: { $0.id == request.messageId }) else {
            MinisToast.show(AppLocalized("找不到要保存的消息"))
            return false
        }
        let message = messages[messageIndex]

        // [S15] The edit has three homes: the bubble, the model-facing
        // agentHistory and the stored rows. If the bubble was never persisted
        // (no dbRowId) and never reloaded (no sourceSortOrder), neither of the
        // last two can be reached without guessing, and a reload would silently
        // revert the UI. Refuse up front, the same way deleteSingleMessage does
        // for the same "not saved yet" state.
        if message.dbRowId == nil, message.sourceSortOrder == nil {
            AppLogger(category: "AIChatViewModel").warning(
                "[CodeBlockEdit] refusing — bubble is neither persisted (no dbRowId) nor reloaded (no sourceSortOrder)")
            errorMessage = AppLocalized("This message hasn't finished saving yet, so its code can't be edited in place. Try again in a moment.")
            MinisToast.show(AppLocalized("This message hasn't finished saving yet, so its code can't be edited in place. Try again in a moment."))
            return false
        }

        let updatedSource = ChatMarkdownSegmenter.replacingNthCode(
            in: request.sourceMarkdown,
            index: request.codeIndex,
            newCode: request.newCode
        )
        guard let updatedSource, updatedSource != request.sourceMarkdown else {
            MinisToast.show(AppLocalized("找不到要保存的代码块"))
            return false
        }

        if message.role == .assistant, let blockId = request.blockId,
           let block = message.blocks.first(where: { $0.id == blockId }) {
            // 命中具体 block：只改这一块，缓存的渲染结果一并作废。
            block.content = updatedSource
            block.cachedMarkdown = nil
            block.cachedAttributedString = nil
            block.objectWillChange.send()
        } else {
            // 用户气泡 / 拿不到 blockId 的助手消息：整条正文换掉。
            // ChatMessage 是 class，直接改属性不会惊动 messages 数组，
            // 所以自己发一次 objectWillChange。
            message.content = updatedSource
            message.objectWillChange.send()
        }

        replaceCodeInAgentHistory(message: message, oldCode: request.oldCode, newCode: request.newCode)
        persistEditedCodeBlock(message: message, oldCode: request.oldCode, newCode: request.newCode)

        notifyAIAboutCodeEdit(request: request, updatedSource: updatedSource)
        // 称呼自适应：提示里报的是当前会话绑的那个人设的名字，
        // 人设改名这里就跟着变，不写死任何具体名字。
        MinisToast.show(String(format: AppLocalized("%@ 已收到改动"), assistantDisplayName))
        return true
    }

    /// 当前会话"回答的人"叫什么——与人设同源（SOUL.md 的 name）。
    private var assistantDisplayName: String {
        ChatAddressing.assistant(sessionPersonaId: sessionPersonaId)
    }

    /// [S15] Rewrite the `agentHistory` copy of the bubble we just edited —
    /// the entry carrying the bubble's own DB row (plus, for an assistant
    /// bubble, the continuation rows folded into it), matched by `dbRowId`.
    /// The old version searched the WHOLE history for the first text part
    /// containing `oldCode`, so a snippet repeated in an earlier turn took the
    /// edit while the edited bubble kept the old code in the model context.
    private func replaceCodeInAgentHistory(message: ChatMessage, oldCode: String, newCode: String) {
        guard let rowId = message.dbRowId,
              let hi = agentHistory.firstIndex(where: { $0.dbMessageId == rowId }) else {
            // NOTE: `rowId` is NOT in scope in a guard-else branch — the
            // guard-let binding only exists after the guard succeeds.
            AppLogger(category: "AIChatViewModel").warning(
                "[CodeBlockEdit] no agentHistory entry for bubble dbRowId=\(message.dbRowId?.prefix(8) ?? "nil") — history edit skipped")
            return
        }
        // Assistant bubbles fold several DB rows into one UI message, so the
        // edited block can live in any of them; scan the bubble's own span
        // only (the same fold deleteSingleMessage uses), never further entries.
        var lastIdx = hi
        if message.role == .assistant {
            var j = hi + 1
            while j < agentHistory.count, !Self.isUserBubbleEntry(agentHistory[j]) {
                lastIdx = j
                j += 1
            }
        }
        for i in hi...lastIdx {
            for j in agentHistory[i].parts.indices {
                if case .text(let text) = agentHistory[i].parts[j],
                   let updated = ChatMarkdownSegmenter.replacingCode(in: text, oldCode: oldCode, newCode: newCode),
                   updated != text {
                    agentHistory[i].parts[j] = .text(updated)
                }
            }
        }
    }

    private func persistEditedCodeBlock(message: ChatMessage, oldCode: String, newCode: String) {
        // 一条 UI 消息可能由多条 raw 行拼成（助手回合尤其如此）。
        // 优先按这条消息自己的 dbRowId 改；改不动再按它的 sort_order 区间
        // 精确扫——只碰折叠进这条消息的那几行，不整库乱改。
        let rowId = message.dbRowId
        let range: ClosedRange<Int>?
        if let start = message.sourceSortOrder, let end = message.lastSourceSortOrder {
            range = min(start, end)...max(start, end)
        } else {
            range = message.sourceSortOrder.map { $0...$0 }
        }
        let sid = sessionId
        Task { @MainActor in
            var done = false
            if let rowId {
                done = await ChatStore.shared.replaceTextPartContainingCode(
                    messageId: rowId, oldCode: oldCode, newCode: newCode)
            }
            if !done, let sid, let range {
                let n = await ChatStore.shared.replaceCodeInSortRange(
                    sessionId: sid, range: range, oldCode: oldCode, newCode: newCode)
                if n == 0 {
                    AppLogger(category: "AIChatViewModel").warning(
                        "[CodeBlockEdit] 持久化未命中任何行 row=\(rowId?.prefix(8) ?? "nil") range=\(range.lowerBound)...\(range.upperBound)")
                }
            } else if !done, sessionId != nil, range == nil {
                // No id write succeeded AND there is no sort-order window to fall
                // back to: the persisted copy keeps the old code. Log loudly
                // instead of leaving the edit silently unwritten.
                AppLogger(category: "AIChatViewModel").warning(
                    "[CodeBlockEdit] 持久化未命中且无 sort_order 区间 row=\(rowId?.prefix(8) ?? "nil")")
            }
        }
    }

    private func notifyAIAboutCodeEdit(request: ChatCodeBlockEditRequest, updatedSource: String) {
        let language = request.language ?? "code"
        // 称呼同样是自适应的：她给自己填了名字就用她的名字，没填用"用户"。
        let who = ChatAddressing.userForModel()
        let note = """
        <system-reminder>
        \(who)刚刚手动修改了聊天消息里的一个 \(language) 代码块，并已保存。请把修改后的代码块视为当前有效版本；如果它存在问题，直接修正；如果只是正常调整，简短确认即可。
        修改前代码：
        \(request.oldCode)
        修改后代码：
        \(request.newCode)
        所在消息原始上下文：
        \(updatedSource)
        </system-reminder>
        """
        Task { @MainActor [weak self] in
            await self?.submitProgrammaticPrompt(note, origin: .userCodeEdit)
        }
    }
}