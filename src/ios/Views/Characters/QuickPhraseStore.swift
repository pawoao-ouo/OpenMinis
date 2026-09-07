import Foundation

/// 常用短语博。点输入栏那颗书签炸出来一份可多增删改的清单，点个子上用。
///
/// 能不走文件就不走：UserDefaults 装得下这类单行文本，先简单，等要分账号
/// (按角色分 rá 册） 或同步才考虑搬出去。key: "quickPhrases.v1"
final class QuickPhraseStore: ObservableObject {

    static let shared = QuickPhraseStore()

    private static let key = "quickPhrases.v1"

    @Published private(set) var phrases: [String] = []

    private init() {
        load()
    }

    func add(_ phrase: String) {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !phrases.contains(trimmed) else { return }
        phrases.insert(trimmed, at: 0)
        persist()
    }

    func remove(at offsets: IndexSet) {
        phrases.remove(atOffsets: offsets)
        persist()
    }

    func update(old: String, to new: String) {
        guard let idx = phrases.firstIndex(of: old) else { return }
        let v = new.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty {
            phrases.remove(at: idx)
        } else if !phrases.contains(v) {
            phrases[idx] = v
        }
        persist()
    }

    private func load() {
        if let data = UserDefaults.standard.array(forKey: Self.key) as? [String] {
            phrases = data
        } else {
            // 冷启动首次：预填几句体感流常用的，不预道欢迎话术那种冷面话。
            phrases = [
                "等等我",
                "我回来了",
                "今天好累",
                "亲我一口",
            ]
            persist()
        }
    }

    private func persist() {
        UserDefaults.standard.set(phrases, forKey: Self.key)
    }
}
