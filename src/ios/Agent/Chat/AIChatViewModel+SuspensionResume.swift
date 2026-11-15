import Foundation

/// [s2-suspend-base] 本文件自带 logger（主类里的 logger 是 private，扩展文件不可见，
/// 按 Agent/Chat 下其他扩展文件的惯例各自声明）。
private let logger = AppLogger(category: "AIChatVM")

// MARK: - [s2-suspend-base] 挂起恢复后继续跑
//
// App 被杀时正在等用户点按的挂起（如问用户），恢复后用户给出答案，
// 通过这里把答案作为 tool_result 投回 agentHistory，再走现有的 resume()
// 让 agent loop 从断点继续（history 尾是 tool_result 时 resume 不会再插
// "Continue" 提示，直接进下一轮模型请求）。

extension AIChatViewModel {
    /// 把一次恢复的挂起的答案投回原会话并继续跑。
    /// - Parameters:
    ///   - toolCallId: 原 tool_use 的 id（答案要配对的那个）。
    ///   - toolName: 工具名（如 "ask_user_input_v0"）。
    ///   - answerJSON: 答案 JSON，作为 tool_result 的内容。
    ///   - summary: 写进 UI 工具块的摘要。
    func continueAfterRestoredAsk(
        toolCallId: String,
        toolName: String,
        answerJSON: String,
        summary: String
    ) {
        guard !isProcessing else {
            logger.info("[SuspensionResume] session busy, skip restored-answer delivery tuId=\(toolCallId.prefix(12))")
            return
        }
        // 1. 答案作为 tool_result 投回 agentHistory（user role，
        //    与正常工具结果同形，下一轮请求能直接配对上原来的 tool_use）。
        //
        // [400-fix] 先查有没有已经落好的同 id tool_result：deferred 那条
        // 在工具循环里已经进了 agentHistory（AIChatViewModel.swift:6828
        // 追加 + 落盘）。再追加一条同 id 的结果，下一轮请求就带两份结果
        // 配一个 tool_use，Gemini 直接报 400 "Requests ending with a
        // model turn are not supported"。有就原地换内容（一个 tool_use
        // 永远只配一个 tool_result，且仍紧贴它的 tool_use），并把 DB 里
        // 那行也同步改掉；没有才追加。
        if let replacedIdx = replaceExistingToolResult(
            toolCallId: toolCallId, toolName: toolName, answerJSON: answerJSON
        ) {
            if let dbId = agentHistory[replacedIdx].dbMessageId {
                syncRestoredAnswerToDB(dbMessageId: dbId, toolCallId: toolCallId, answerJSON: answerJSON)
            } else {
                logger.info("[SuspensionResume] replaced in memory only, row was never persisted tuId=\(toolCallId.prefix(12))")
            }
        } else if toolUseExistsInHistory(toolCallId: toolCallId) {
            let resultMessage = AgentMessage(role: .user, parts: [
                .toolResult(id: toolCallId, name: toolName, content: answerJSON, isError: false),
            ])
            agentHistory.append(resultMessage)
            let resultIdx = agentHistory.count - 1
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let pid = await self.persistAgentMessage(resultMessage),
                   resultIdx < self.agentHistory.count {
                    self.agentHistory[resultIdx].dbMessageId = pid
                }
            }
        } else {
            // tool_use 已经不在 history 里（比如被压缩掉了）：再补 tool_result
            // 会变成没配对的孤儿，请求层会直接丢掉它，答案白白没了。改成
            // 一条普通 user 文本，模型照样看得到答案，请求也永远合法。
            let textMessage = AgentMessage(role: .user, parts: [
                .text("[The user answered the earlier question (tool \(toolName), id \(toolCallId))]: \(answerJSON)"),
            ])
            agentHistory.append(textMessage)
            let textIdx = agentHistory.count - 1
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let pid = await self.persistAgentMessage(textMessage),
                   textIdx < self.agentHistory.count {
                    self.agentHistory[textIdx].dbMessageId = pid
                }
            }
        }
        // 2. UI 上把原来的工具块标成已完成，写上摘要。
        for msg in messages where msg.role == .assistant {
            if let block = msg.blocks.first(where: { $0.toolUseId == toolCallId }) {
                block.content = summary
                block.toolStatus = .success
            }
        }
        // 3. 重进是 DB 里捞出来的内容，没有没提交的流式尾巴——
        //    把 committedBlockCount 对齐，避免 resume() 的 pre-trim 误伤。
        if let lastMsg = messages.last, lastMsg.role == .assistant {
            committedBlockCount = lastMsg.blocks.count
        }
        // 4. 走现有 resume() 从断点继续。
        canResume = true
        resume()
    }

    /// [400-fix] 在 agentHistory 里找 id 相同的 tool_result，找到就把
    /// 它的内容原地换成答案，返回被改消息的下标；没找到返回 nil。
    /// 原 part 自带的 imageData/pageURL 等原样保留（ask_user 的结果
    /// 本来就没有这些，留着只是以防万一）。
    private func replaceExistingToolResult(toolCallId: String, toolName: String, answerJSON: String) -> Int? {
        for msgIdx in agentHistory.indices {
            guard agentHistory[msgIdx].role == .user else { continue }
            for partIdx in agentHistory[msgIdx].parts.indices {
                if case .toolResult(let id, _, _, _, let imageData, let imageMimeType, let pageURL, let imageLinuxPath) = agentHistory[msgIdx].parts[partIdx],
                   id == toolCallId {
                    agentHistory[msgIdx].parts[partIdx] = .toolResult(
                        id: toolCallId, name: toolName, content: answerJSON, isError: false,
                        imageData: imageData, imageMimeType: imageMimeType,
                        pageURL: pageURL, imageLinuxPath: imageLinuxPath
                    )
                    logger.info("[SuspensionResume] replaced deferred tool_result in place tuId=\(toolCallId.prefix(12)) msgIdx=\(msgIdx)")
                    return msgIdx
                }
            }
        }
        return nil
    }

    /// agentHistory 里还有没有这个 id 的 tool_use。
    private func toolUseExistsInHistory(toolCallId: String) -> Bool {
        for msg in agentHistory {
            for part in msg.parts {
                if case .toolUse(let id, _, _) = part, id == toolCallId {
                    return true
                }
            }
        }
        return false
    }

    /// 把恢复答案同步写回 DB：只改那一行里 id 相同的 tool_result part，
    /// 其余 part（同批别的工具结果、快照）原样保留。loadMessages 是整
    /// 会话读，只在回答恢复卡片时跑一次。
    private func syncRestoredAnswerToDB(dbMessageId: String, toolCallId: String, answerJSON: String) {
        guard let sid = sessionId else {
            logger.info("[SuspensionResume] no sessionId, DB keeps deferred content tuId=\(toolCallId.prefix(12))")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let rows = await ChatStore.shared.loadMessages(sessionId: sid)
            guard let row = rows.first(where: { $0.id == dbMessageId }) else {
                logger.info("[SuspensionResume] deferred row not found in DB, skip sync tuId=\(toolCallId.prefix(12))")
                return
            }
            var parts = row.parts
            var changed = false
            for i in parts.indices {
                if case .toolResult(let tr) = parts[i], tr.toolUseId == toolCallId {
                    parts[i] = .toolResult(ToolResult(
                        toolUseId: tr.toolUseId, output: answerJSON, success: true,
                        mediaRef: tr.mediaRef, snapshot: tr.snapshot,
                        pageURL: tr.pageURL, status: "success"
                    ))
                    changed = true
                }
            }
            if changed {
                await ChatStore.shared.updateMessageParts(messageId: dbMessageId, parts: parts)
                logger.info("[SuspensionResume] DB row updated with restored answer tuId=\(toolCallId.prefix(12))")
            }
        }
    }
}
