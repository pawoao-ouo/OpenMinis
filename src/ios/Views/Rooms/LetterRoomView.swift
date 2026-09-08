import SwiftUI

/// 信房。
///
/// 与其他房间不同：信件分两摞——左边"我写的"，右边"她写的"。
/// 点一封就进来读，读完可以"原封不动收好"或者打个"收讫"的记号。
struct LetterRoomView: View {

    let roomId: String
    let character: CharacterCard

    @ObservedObject private var store = RoomStore.shared
    @State private var viewMode: Segment = .all
    @State private var showCompose = false
    @State private var showHersWriting = false

    enum Segment: String, CaseIterable, Identifiable {
        case all, mine, hers
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:  return AppLocalized("全部")
            case .mine: return AppLocalized("我写的")
            case .hers: return AppLocalized("她写的")
            }
        }
    }

    private var entries: [RoomEntry] {
        let all = store.entries(in: roomId).sorted { $0.createdAt > $1.createdAt }
        switch viewMode {
        case .all:
            return all
        case .mine:
            return all.filter { $0.owner == .user }
        case .hers:
            return all.filter { $0.owner == .assistant }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $viewMode) {
                ForEach(Segment.allCases) { seg in
                    Text(seg.label).tag(seg)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            ScrollView {
                LazyVStack(spacing: 14) {
                    if entries.isEmpty {
                        Text(AppLocalized("一封都还没有。\n点右上角那支笔。"))
                            .font(.footnote)
                            .foregroundStyle(ChatColors.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.vertical, 40)
                    }
                    ForEach(entries) { entry in
                        LetterCard(entry: entry, fromCharacterName: character.name)
                            .roomEntryContextMenu(roomId: roomId, entry: entry) { editing in
                                editingEntry = editing
                            }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .background(ChatColors.background.ignoresSafeArea())
        .navigationTitle(AppLocalized("信"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showCompose = true } label: { Label(AppLocalized("我写一封"), systemImage: "pencil") }
                    Button { showHersWriting = true } label: { Label(AppLocalized("让她来写"), systemImage: "envelope.badge") }
                } label: { Image(systemName: "square.and.pencil") }
            }
        }
        .sheet(isPresented: $showCompose) {
            NavigationStack {
                LetterComposeView(roomId: roomId, character: character)
            }
        }
        .sheet(item: $editingEntry) { entry in
            NavigationStack { RoomEntryEditorView(roomId: roomId, entry: entry) }
        }
        .sheet(isPresented: $showHersWriting) {
            NavigationStack {
                LetterGenerateView(roomId: roomId, character: character)
            }
        }
        .onAppear { store.loadIfNeeded(roomId: roomId) }
    }
}

private struct LetterCard: View {
    let entry: RoomEntry
    let fromCharacterName: String

    @State private var expanded = false

    private var fromLabel: String {
        entry.owner == .assistant ? fromCharacterName : AppLocalized("你")
    }

    private var toLabel: String {
        entry.owner == .assistant ? AppLocalized("我") : fromCharacterName
    }

    var body: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(fromLabel) → \(toLabel)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(ChatColors.secondaryText)
                    Spacer()
                    Image(systemName: expanded ? "envelope.open.fill" : "envelope.fill")
                        .foregroundStyle(ChatColors.accent)
                }

                Text(entry.text)
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(ChatColors.primaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(expanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(entry.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(ChatColors.secondaryText)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(ChatColors.secondaryBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(ChatColors.inputIconBorder.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct LetterComposeView: View {
    let roomId: String
    let character: CharacterCard
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 180)
                Text(AppLocalized("写完放到信箱里，她进来看见。"))
                    .font(.caption)
                    .foregroundStyle(ChatColors.secondaryText)
            } header: {
                Text(AppLocalized("写给") + " \(character.name)")
            }
        }
        .navigationTitle(AppLocalized("写一封信"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("取消")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalized("放进信箱")) {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    RoomStore.shared.append(owner: .user, text: t, in: roomId)
                    dismiss()
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}


/// 让她来信。模型真的写，不是生成假文字。
private struct LetterGenerateView: View {
    let roomId: String
    let character: CharacterCard

    @Environment(\.dismiss) private var dismiss
    @State private var isWriting = true
    @State private var errorText: String? = nil

    var body: some View {
        VStack(spacing: 20) {
            if isWriting {
                Spacer()
                ProgressView().scaleEffect(1.2)
                Text(AppLocalized("她在写了"))
                    .font(.footnote)
                    .foregroundStyle(ChatColors.secondaryText)
                Spacer()
            } else if let err = errorText {
                Spacer()
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 36))
                    .foregroundStyle(ChatColors.secondaryText)
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(ChatColors.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Button(AppLocalized("好")) { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
            } else {
                Spacer()
                Image(systemName: "envelope.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(ChatColors.accent)
                Text(AppLocalized("信已放进你的信箱"))
                    .font(.headline)
                    .foregroundStyle(ChatColors.primaryText)
                Button(AppLocalized("去翻看")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
        .navigationTitle(AppLocalized("她在写"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let res = await RoomContentGenerator.shared.generate(kind: .letter, character: character)
            if res.succeeded {
                RoomContentGenerator.shared.commit(kind: .letter, roomId: roomId, character: character, raw: res.raw)
                isWriting = false
            } else {
                errorText = res.error ?? AppLocalized("没能写出来")
                isWriting = false
            }
        }
    }
}
