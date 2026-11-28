import SwiftUI

struct OffloadPermissionSettingsView: View {
    @ObservedObject private var manager = OffloadPermissionManager.shared
    @ObservedObject private var configGate = MinisConfigPermissionStore.shared
    @ObservedObject private var correctionConsent = VoiceCorrectionCollectionConsent.shared
    @ObservedObject private var shellApproval = ShellApprovalSettings.shared
    @State private var showClearCorrectionConfirm = false
    @State private var correctionDataCleared = false

    var body: some View {
        List {
            Section("Background") {
                NavigationLink {
                    EnhancedBackgroundSettingsView()
                } label: {
                    Label("Background", systemImage: "location.circle.fill")
                }
            }

            Section {
                Toggle("Allow minis-config", isOn: $configGate.enabled)
            } header: {
                Text("Configuration Tool")
            } footer: {
                Text("Off: the agent can't read or change settings via minis-config. It gets permission_denied and can still guide you with deep links. History stays in Logs → Config Changes.")
            }

            Section("Privacy") {
                ForEach(settingsCommands, id: \.name) { cmd in
                    CommandPermissionRow(command: cmd)
                }
            }

            // [T-02 / H-01] 主题面单独一节：改的是她亲手调过的配色/壁纸/
            // 头像/主题库，不属于隐私数据，混在 Privacy 里名不副实。
            Section {
                ForEach(appearanceCommands, id: \.name) { cmd in
                    CommandPermissionRow(command: cmd)
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("主题命令会改配色、壁纸、头像和主题套。第一次用时问一次；只读命令不打扰。删除、改名、换头像、换壁纸、重置每次都单独确认。")
            }

            // [s2-approve] 工作区命令（shell_execute）审批总开关，默认关。
            Section {
                Toggle("执行前先询问", isOn: $shellApproval.needsApproval)
            } header: {
                Text("Workspace Commands")
            } footer: {
                Text("打开后执行每条命令都先问你，可在弹窗里选「本次会话不再询问」。默认关闭。MCP、日历/提醒写入走各自的审批，不受影响。")
            }

            Section {
                Toggle(AppLocalized("Collect voice correction data",
                              comment: "Permissions: toggle for voice-correction learning data collection"),
                       isOn: $correctionConsent.isEnabled)
                Button(role: .destructive) {
                    showClearCorrectionConfirm = true
                } label: {
                    Label(AppLocalized("Clear Collected Data",
                                 comment: "Permissions: wipe voice-correction learning data"),
                          systemImage: "trash")
                }
            } header: {
                Text("Voice Correction Learning")
            } footer: {
                Text("Stores your voice-transcript fixes, accepted/rejected AI corrections, and frequent terms on-device to improve future corrections. Nothing is uploaded. Off by default.")
            }
            .confirmationDialog(
                AppLocalized("Clear all collected voice correction data?",
                       comment: "Permissions: confirm wipe of correction learning data"),
                isPresented: $showClearCorrectionConfirm,
                titleVisibility: .visible
            ) {
                Button(AppLocalized("Clear All", comment: "Confirm clearing correction data"),
                       role: .destructive) {
                    Task {
                        if let db = VoiceCorrectionDB.shared {
                            await db.clearTable("confusion_dictionary")
                            await db.clearTable("typed_vocabulary")
                            await db.clearTable("correction_events")
                        }
                        correctionDataCleared = true
                    }
                }
                Button(AppLocalized("Cancel", comment: "Cancel"), role: .cancel) {}
            }
            .alert(AppLocalized("Voice correction data cleared",
                          comment: "Permissions: wipe done confirmation"),
                   isPresented: $correctionDataCleared) {
                Button("OK") {}
            }
        }
        .navigationTitle("Permissions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Set All Bypass") {
                    manager.setAllBypass()
                    // The minis-config master switch is a separate
                    // store from OffloadPermissionManager (different
                    // subsystem) so its own setAllBypass doesn't touch
                    // it. Flip it on here so "Set All Bypass" really
                    // does enable everything the user can see on this
                    // screen.
                    configGate.enabled = true
                }
            }
        }
        .settingsPage()
    }

    private var settingsCommands: [OffloadCommandInfo] {
        OffloadPermissionManager.allCommands.filter {
            $0.showInSettings && $0.category != .appearance
        }
    }

    private var appearanceCommands: [OffloadCommandInfo] {
        OffloadPermissionManager.allCommands.filter {
            $0.showInSettings && $0.category == .appearance
        }
    }
}

private struct CommandPermissionRow: View {
    @ObservedObject private var fontSettings = FontSettings.shared
    let command: OffloadCommandInfo
    @ObservedObject private var manager = OffloadPermissionManager.shared

    /// Reads/writes the manager directly. Seeding a local @State in init
    /// (the old approach) had no re-read path, so bulk changes from
    /// "Set All Bypass" left every row showing its pre-tap level while the
    /// effective permission had already changed. The manager bumps
    /// `levelsRevision` on writes, which re-renders this row via
    /// @ObservedObject and re-reads the current level here.
    private var levelBinding: Binding<OffloadPermissionLevel> {
        Binding(
            get: { manager.permissionLevel(for: command.name) },
            set: { manager.setPermissionLevel($0, for: command.name) }
        )
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.displayLabel)
                Text(command.description)
                    .font(.system(size: fontSettings.scaledApp(12)))
                    .foregroundStyle(MinisTheme.secondaryText)
            }
            Spacer()
            Picker("", selection: levelBinding) {
                ForEach(OffloadPermissionLevel.allCases, id: \.self) { lvl in
                    Text(lvl.displayName).tag(lvl)
                }
            }
            .pickerStyle(.menu)
        }
    }
}
