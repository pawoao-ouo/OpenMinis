//
//  ComposerActionSheet.swift
//  Minis - chat page (AIChatView)
//
//  加号的原生小抽屉。[T-composer-oneshot]
//
//  她原话：「+号点出来是 iOS 手机原生小抽屉，和 thinking 那种小抽屉弹出来
//  一样的。不要那个模型名字。」
//
//  所以这里不画 grabber、不画圆角、不画背景——全部交给系统 sheet 自己做，
//  只排内容:四个常用动作摆成一行方卡,下面两张卡——工具入口(终端/浏览器/
//  会话文件/Token 用量/导出/语音)和会话设置。模型那一行直接不出现(要换模型
//  在设置里换,输入栏旁边不再挂一个会变的标签)。
//

import SwiftUI

struct ComposerActionSheet: View {
    let memoryEnabled: Bool
    let sessionId: String?
    let onItemTap: (PlusPanelItemType) -> Void
    let onSetMemory: (Bool) -> Void
    let onToggleSkill: (String, Bool) -> Void
    let onToggleConnector: (String, Bool) -> Void

    @ObservedObject private var skillStore = SkillStore.shared
    @ObservedObject private var mcpStore = MCPStore.shared
    @State private var page: Page = .root
    @Environment(\.dismiss) private var dismiss

    private enum Page: Hashable { case root, skills, connectors }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    switch page {
                    case .root: rootContent
                    case .skills: skillList
                    case .connectors: connectorList
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(CSSThemeVariables.bg(scope: ThemeColorLayer.sheet))
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if page != .root {
                        Button(AppLocalized("返回")) {
                            withAnimation(.snappy) { page = .root }
                        }
                    }
                }
            }
        }
        .onAppear { mcpStore.load() }
    }

    private var navTitle: String {
        switch page {
        case .root: return AppLocalized("添加到对话")
        case .skills: return AppLocalized("技能")
        case .connectors: return AppLocalized("连接器")
        }
    }

    // MARK: 根页

    private var rootContent: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                tile(AppLocalized("相机"), "camera.fill") { pick(.camera) }
                tile(AppLocalized("照片"), "photo.fill") { pick(.photo) }
                tile(AppLocalized("文件"), "doc.fill") { pick(.doc) }
                tile(AppLocalized("表情包"), "face.smiling.inverse") { pick(.sticker) }
            }

            // [T-plus-tool-rows] 11-07 把老的下拉面板换成这个原生小抽屉时，老面板
            // 底座上那排快捷键(终端/浏览器/会话文件/Token 用量/导出/语音)跟着一起
            // 下掉了，动作本身一直还在(performPlusPanelAction 那套没动)，缺的只是
            // 入口。她 11-09 发现「终端和浏览器啥的好像没有了」，这里补回来。
            VStack(spacing: 0) {
                // 文案和图标直接用 PlusPanelItemType 自己那套,别再抄一遍。
                let tools: [PlusPanelItemType] = [.terminal, .browser, .files,
                                                  .gauge, .share, .voice]
                ForEach(Array(tools.enumerated()), id: \.element) { idx, item in
                    navRow(AppLocalized(item.title), item.systemImageName, value: nil) {
                        pick(item)
                    }
                    if idx < tools.count - 1 { divider }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(CSSThemeVariables.card(scope: ThemeColorLayer.sheet))
            )

            VStack(spacing: 0) {
                toggleRow(AppLocalized("记忆"),
                          subtitle: AppLocalized("这一句起，小梦会不会把这次对话记下来"),
                          isOn: memoryEnabled) { onSetMemory($0) }
                divider
                navRow(AppLocalized("技能"), "puzzlepiece.extension",
                       value: skillCountText) {
                    withAnimation(.snappy) { page = .skills }
                }
                divider
                navRow(AppLocalized("连接器"), "wrench.and.screwdriver",
                       value: connectorCountText) {
                    withAnimation(.snappy) { page = .connectors }
                }
                divider
                navRow(AppLocalized("一起听"), "headphones", value: nil) { pick(.together) }
                divider
                navRow(AppLocalized("新建会话"), "square.and.pencil", value: nil) { pick(.newChat) }
                divider
                navRow(AppLocalized("压缩上下文"), "arrow.down.right.and.arrow.up.left", value: nil) {
                    pick(.compactHistory)
                }
                divider
                navRow(AppLocalized("清空当前对话"), "trash", value: nil) { pick(.clearChat) }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(CSSThemeVariables.card(scope: ThemeColorLayer.sheet))
            )
        }
    }

    // MARK: 二级列表

    private var skillList: some View {
        VStack(spacing: 0) {
            ForEach(skillsSorted) { skill in
                toggleRow(skill.name,
                          subtitle: skill.description.trimmingCharacters(in: .whitespacesAndNewlines),
                          isOn: skillEnabled(skill)) {
                    onToggleSkill(skill.id, $0)
                }
                divider
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(CSSThemeVariables.card(scope: ThemeColorLayer.sheet))
        )
    }

    private var connectorList: some View {
        VStack(spacing: 0) {
            ForEach(connectorsSorted) { server in
                toggleRow(server.id,
                          subtitle: server.transportSummary,
                          isOn: connectorEnabled(server)) {
                    onToggleConnector(server.id, $0)
                }
                divider
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(CSSThemeVariables.card(scope: ThemeColorLayer.sheet))
        )
    }

    private var skillsSorted: [Skill] {
        let _ = skillStore.sessionOverrideVersion
        return skillStore.skills.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var connectorsSorted: [MCPServerConfig] {
        let _ = mcpStore.sessionOverrideVersion
        return mcpStore.servers.sorted {
            $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }

    private var skillCountText: String {
        "\(skillStore.skills.count)"
    }

    private var connectorCountText: String {
        "\(mcpStore.servers.count)"
    }

    private func skillEnabled(_ skill: Skill) -> Bool {
        guard let sid = sessionId else { return skill.isEnabled }
        return skillStore.isEnabledForSession(skill.id, sessionId: sid)
    }

    private func connectorEnabled(_ server: MCPServerConfig) -> Bool {
        guard let sid = sessionId else { return server.enabled }
        return mcpStore.isEnabledForSession(server.id, sessionId: sid)
    }

    // MARK: 组件

    private func pick(_ item: PlusPanelItemType) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        dismiss()
        onItemTap(item)
    }

    private func tile(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(ChatFont.font(21, weight: .regular))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: ThemeColorLayer.sheet))
                Text(title)
                    .font(ChatFont.font(11, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: ThemeColorLayer.sheet))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(CSSThemeVariables.card(scope: ThemeColorLayer.sheet))
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func navRow(_ title: String, _ icon: String, value: String?, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(ChatFont.font(16))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: ThemeColorLayer.sheet))
                    .frame(width: 24)
                Text(title)
                    .font(ChatFont.font(15))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: ThemeColorLayer.sheet))
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(ChatFont.font(14))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: ThemeColorLayer.sheet))
                }
                Image(systemName: "chevron.right")
                    .font(ChatFont.font(12, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: ThemeColorLayer.sheet).opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(_ title: String, subtitle: String?, isOn: Bool,
                           action: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ChatFont.font(15))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: ThemeColorLayer.sheet))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(ChatFont.font(12))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: ThemeColorLayer.sheet))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { isOn }, set: { action($0) }))
                .labelsHidden()
                .tint(CSSThemeVariables.accent())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Rectangle()
            .fill(CSSThemeVariables.divider(scope: ThemeColorLayer.sheet).opacity(0.6))
            .frame(height: 0.5)
            .padding(.leading, 50)
    }
}
