import SwiftUI

/// 短语点单面板。点一条 → 进输入框。上下滑删/item 长那按编辑。
///
/// 顺手能新增——留一个空 TextField 在底，写一句回车就入库。
struct QuickPhraseSheet: View {

    /// 选中一条后直接拼装别处送去（输入框/侧栏都行），由调用方决定。
    let onPick: (String) -> Void

    @ObservedObject private var store = QuickPhraseStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var editingOld: String? = nil
    @State private var editingDraft = ""

    var body: some View {
        NavigationStack {
            List {
                if store.phrases.isEmpty {
                    Text(AppLocalized("头一句，瞎写一句也成。用了它就会记住。"))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(store.phrases, id: \.self) { p in
                        if editingOld == p {
                            HStack {
                                TextField(AppLocalized("改短语"), text: $editingDraft)
                                    .textFieldStyle(.roundedBorder)
                                Button(AppLocalized("收")) {
                                    store.update(old: p, to: editingDraft)
                                    editingOld = nil
                                }
                                .buttonStyle(.borderless)
                            }
                        } else {
                            Button {
                                onPick(p)
                                dismiss()
                            } label: {
                                Text(p)
                                    .foregroundStyle(ChatColors.primaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contextMenu {
                                Button {
                                    editingOld = p
                                    editingDraft = p
                                } label: {
                                    Label(AppLocalized("改"), systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    if let idx = store.phrases.firstIndex(of: p) {
                                        store.remove(at: IndexSet(integer: idx))
                                    }
                                } label: {
                                    Label(AppLocalized("删"), systemImage: "trash")
                                }
                            }
                        }
                    }
                    .onDelete { store.remove(at: $0) }
                }

                Section {
                    HStack {
                        TextField(AppLocalized("写句新的，回来就直接填进输入框"), text: $draft)
                            .submitLabel(.done)
                            .onSubmit { add() }
                        Button(AppLocalized("存")) { add() }
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(AppLocalized("常用短语"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalized("关")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        store.add(draft)
        draft = ""
    }
}
