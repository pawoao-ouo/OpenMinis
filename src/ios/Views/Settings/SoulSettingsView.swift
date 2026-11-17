import SwiftUI

/// Settings page for SOUL.md — Minis's persistent personality file.
/// Lives between Skills and Memory in the Agent Runtime section.
struct SoulSettingsView: View {
    @ObservedObject private var fontSettings = FontSettings.shared
    @State private var name: String = SoulMetadata.default.name
    /// Raw emoji value loaded from SOUL.md. Not user-editable; preserved
    /// verbatim on save so we don't rewrite a value the user (or another
    /// device) may have set in the file. It is never rendered anywhere.
    @State private var rawEmoji: String = SoulMetadata.default.emoji
    /// [T-soul-custom-icon] The user's identity icon: a relative file
    /// reference (`avatars/….png`), or empty for the default. (A legacy
    /// non-image value is kept on disk but renders as the default.)
    /// [D4] 这只是 SOUL.md 里那个镜像值的本地份：头像在通讯录里换，
    /// 这里只显示。保存时写的是 displayIcon（通讯录那份），不是它。
    @State private var icon: String = SoulMetadata.default.icon
    @State private var style: String = SoulMetadata.default.style
    @State private var lang: String = SoulMetadata.default.lang
    @State private var bodyText: String = ""
    @State private var saveError: String? = nil
    @State private var didJustSave: Bool = false
    @State private var showRestoreConfirm: Bool = false
    @StateObject private var loadedRef = LoadedFileRef()

    private static var langOptions: [(label: String, value: String)] {
        [
            (AppLocalized("Auto"), "auto"),
            (AppLocalized("Chinese"), "zh"),
            (AppLocalized("English"), "en"),
        ]
    }

    var body: some View {
        Form {
            Section {
                previewCard
            }

            Section {
                LabeledContent(AppLocalized("Name")) {
                    TextField("嘟嘟", text: $name)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                }
                LabeledContent(AppLocalized("Style")) {
                    TextField(AppLocalized("e.g. Warm, direct, opinionated"), text: $style)
                        .multilineTextAlignment(.trailing)
                }
                Picker(AppLocalized("Language"), selection: $lang) {
                    ForEach(Self.langOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
            } header: {
                Text(AppLocalized("Identity"))
            } footer: {
                // [audit-D1] 说清它现在真的会生效：作为回复语言硬约束写进人设提示。
                Text("回复语言：选「中文 / 英文」后，会作为硬约束写进人设提示（每条都按它回复）；「自动」= 跟随你说话的语言。")
            }

            Section {
                personalityEditor
            } header: {
                Text(AppLocalized("Personality Prompt"))
            } footer: {
                bodyLengthFooter
            }

            Section {
                Button(role: .destructive) {
                    showRestoreConfirm = true
                } label: {
                    Label(AppLocalized("Restore Default"), systemImage: "arrow.uturn.backward")
                }

            }

            if let saveError {
                Section {
                    Text(saveError)
                        .font(.system(size: fontSettings.scaledApp(13)))
                        .foregroundStyle(MinisTheme.destructive)
                }
            }
        }
        .navigationTitle(AppLocalized("Soul"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(AppLocalized("Save")) { save() }
                    .disabled(!isDirty)
            }
        }
        .onAppear(perform: reload)
        // Using .alert (not .confirmationDialog) so the dialog stays
        // centered on iPad / Mac. confirmationDialog without a source
        // rect renders as a popover anchored to the screen's top edge
        // on regular-width size classes.
        .alert(
            AppLocalized("Restore Default"),
            isPresented: $showRestoreConfirm
        ) {
            Button(AppLocalized("Restore Default"), role: .destructive, action: restoreDefault)
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalized("Restore default SOUL.md? Your current personality will be replaced."))
        }
        .overlay(alignment: .bottom) {
            if didJustSave {
                Text(AppLocalized("Saved"))
                    .font(.system(size: fontSettings.scaledApp(13), weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(MinisTheme.success.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .settingsPage()
    }

    // MARK: - Subviews

    // Standard Form row — the insetGrouped section provides the rounded
    // card chrome automatically, so we only render content here. Matches
    // the visual width of every other section on the page.
    /// [B28 R18] 头像真源是 Persona.avatar（通讯录那份）。SOUL.md 的 icon
    /// 只是镜像，老数据可能还指着旧文件，所以这里也以通讯录为准。
    private var displayIcon: String {
        let pid = PersonaStore.currentID()
        if let stored = PersonaStore.shared.personas.first(where: { $0.id == pid })?.avatar,
           !stored.isEmpty {
            return stored
        }
        return icon
    }

    private var previewCard: some View {
        HStack(alignment: .center, spacing: 12) {
            // [T-soul-custom-icon] Tappable, and it has to LOOK tappable: a
            // bare glyph sitting on the card reads as decoration, and the
            // pencil badge alone was too easy to miss. A filled circle gives
            // the icon a defined edge and a hit area the eye can find, which
            // is the same treatment the category badges elsewhere in Settings
            // use. It doubles as a backdrop for transparent PNG icons, whose
            // whole point is having no background of their own.
            // [B28 R18] 头像只有一个入口：通讯录。这里只显示，不给改——
            // 两处都能改就必然两套存储，AI 也会分不清该动哪条命令。
            // [B28 R19] 用和通讯录同一个视图渲染：同一张图、同一种裁切（圆形填充），
            // 不再出现"方图塞进圆框"的两种长相。
            PersonaAvatarView(iconRef: displayIcon, size: 52)
                .accessibilityLabel(AppLocalized("Icon"))
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? "嘟嘟" : name)
                    .font(.system(size: fontSettings.scaledApp(20), weight: .semibold))
                Text(AppLocalized("头像在通讯录里换"))
                    .font(.system(size: fontSettings.scaledApp(11)))
                    .foregroundStyle(MinisTheme.secondaryText)
                if !style.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(style)
                        .font(.system(size: fontSettings.scaledApp(13)))
                        .foregroundStyle(MinisTheme.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var personalityEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $bodyText)
                .frame(minHeight: 220)
                .font(.system(size: fontSettings.scaledApp(17), design: .monospaced))
                .scrollContentBackground(.hidden)
            // SwiftUI's TextEditor has no native placeholder. We render
            // a greyed hint on top when the body is empty + not being
            // typed into. allowsHitTesting(false) so taps fall through
            // to the editor below.
            if bodyText.isEmpty {
                Text(AppLocalized("Describe the personality and voice you want for your agent"))
                    .font(.system(size: fontSettings.scaledApp(17), design: .monospaced))
                    .foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Footer under the personality editor. Shows a live token count
    /// (informational only — the hard cap was removed, so there is no
    /// over-limit state to render any more).
    private var bodyLengthFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.justify.left")
                .foregroundStyle(MinisTheme.secondaryText)
            Text(soulBodyCountText(bodyText))
                .foregroundStyle(MinisTheme.secondaryText)
        }
        .font(.system(size: fontSettings.scaledApp(13)))
    }

    /// Counter shown when the body is within budget.
    private func soulBodyCountText(_ body: String) -> String {
        let count = SoulStore.tokenCount(body)
        return AppLocalized("\(count) tokens")
    }

    // MARK: - Persistence

    private var currentFile: SoulFile {
        SoulFile(
            metadata: SoulMetadata(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                // Round-trip the on-disk emoji untouched — UI no longer
                // edits this field, but a SOUL.md authored elsewhere
                // (other device / hand-edit) should not have its emoji
                // rewritten on save.
                emoji: rawEmoji,
                style: style,
                lang: lang,
                // [D4] 以前写的是本页本地的 icon（reload 时从 SOUL.md 读的）：
                // 通讯录里换了头像之后这里还指着旧文件，保存就把旧镜像
                // 又写回去。显示的头像来自 Persona.avatar，保存就写显示
                // 的那一份——分叉时这次保存顺手把镜像修好，而不是重申旧值。
                icon: displayIcon
            ),
            body: bodyText
        )
    }

    private var isDirty: Bool {
        currentFile != loadedRef.value
    }

    private func reload() {
        let file = SoulStore.load() ?? SoulFile(metadata: .default, body: "")
        name = file.metadata.name
        rawEmoji = file.metadata.emoji
        icon = file.metadata.icon
        style = file.metadata.style
        lang = file.metadata.lang
        bodyText = file.body
        loadedRef.value = file
        saveError = nil
    }

    private func save() {
        do {
            let f = currentFile
            try SoulStore.save(f)
            loadedRef.value = f
            saveError = nil
            withAnimation { didJustSave = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { didJustSave = false }
            }
        } catch {
            saveError = "Save failed: \(error.localizedDescription)"
        }
    }


    private func restoreDefault() {
        let parsed = SoulMDParser.parse(SoulStore.defaultContent)
        name = parsed.metadata.name
        rawEmoji = parsed.metadata.emoji
        // The default content carries no icon, so this resets to "" (default
        // presentation). Omitting it left the custom icon in place AND let
        // the save() below write it into the "restored" file permanently.
        icon = parsed.metadata.icon
        style = parsed.metadata.style
        lang = parsed.metadata.lang
        bodyText = parsed.body
        save()
    }

    private final class LoadedFileRef: ObservableObject {
        var value: SoulFile = SoulFile(metadata: .default, body: "")
    }
}
