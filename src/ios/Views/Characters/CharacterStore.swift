import Foundation
import SwiftUI

/// 人物卡。SillyTavern 式——谁也不服谁，没有"主副"之别。
///
/// 记忆隔离：每个人物的 memory 是 real file (characters/<id>/memory.md) 
/// 的内存 mirror；跟主聊天跑的别的窗口无关。人设完全自定。
/// 头像：优先自定义图（characters/avatars/），没有就文档形状 fallback。
///
/// 不是 agent：他们不干别的活儿，除了聊天。像来接物的亲人。
internal struct CharacterCard: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// 在 characters/avatars/<id>.jpg；没图就用圆底 + 首字
    var avatarImageFile: String?
    /// 喜欢的颜色 hue(0...1)，id 哈希落地，用户能换
    var hue: Double
    /// 人设注入（into user-message prefix）
    var persona: String
    /// 每轮回答后自行追加；用户也可手改
    var memory: String
    /// 人物默认绑的模型入口 id；nil 跟当前会话模型
    var modelEntryId: String?
    var createdAt: Date

    var placeholderGlyph: String {
        String(name.prefix(1))
    }
    var displayColor: Color {
        Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }

    init(
        id: UUID = UUID(),
        name: String,
        avatarImageFile: String? = nil,
        hue: Double? = nil,
        persona: String = "",
        memory: String = "",
        modelEntryId: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.avatarImageFile = avatarImageFile
        self.hue = hue ?? Double(abs(id.uuidString.hashValue) % 360) / 360.0
        self.persona = persona
        self.memory = memory
        self.modelEntryId = modelEntryId
        self.createdAt = createdAt
    }
}

/// 人物 Store。characters.json 是夹名、avatar 元数据、最新更新时间，
/// 大头记忆在单独的 memory.md——用户能直接读写的筠-筠-eds。
@MainActor
final class CharacterStore: ObservableObject {

    static let shared = CharacterStore()

    @Published private(set) var characters: [CharacterCard] = []

    private let fm = FileManager.default
    private var rootDir: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("characters", isDirectory: true)
    }
    private var avatarsDir: URL { rootDir.appendingPathComponent("avatars", isDirectory: true) }
    private var memoryDir: URL { rootDir.appendingPathComponent("memory", isDirectory: true) }
    private var indexURL: URL { rootDir.appendingPathComponent("index.json") }

    private init() {
        for sub in [avatarsDir, memoryDir] {
            try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        }
        loadIndex()
    }

    // MARK: - CRUD

    func upsert(_ character: CharacterCard) {
        if let idx = characters.firstIndex(where: { $0.id == character.id }) {
            characters[idx] = character
        } else {
            characters.insert(character, at: 0)
        }
        saveIndex()
    }

    func remove(id: UUID) {
        let keep = characters.first(where: { $0.id == id })
        characters.removeAll { $0.id == id }
        saveIndex()
        // 删头像/记忆落盘内容（会话本体不动）
        if let a = keep?.avatarImageFile {
            try? fm.removeItem(at: avatarsDir.appendingPathComponent(a) )
        }
        try? fm.removeItem(at: memoryURL(for: id))
    }

    func setAvatarJPEG(_ data: Data, for characterID: UUID) {
        guard let idx = characters.firstIndex(where: { $0.id == characterID }) else { return }
        let fname = "\(characterID.uuidString).jpg"
        let url = avatarsDir.appendingPathComponent(fname)
        do {
            try data.write(to: url, options: .atomic)
            characters[idx].avatarImageFile = fname
            saveIndex()
        } catch {
            AppLogger(category: "Characters").error("[Characters] avatar write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Memory

    func memory(for characterID: UUID) -> String {
        guard let data = try? Data(contentsOf: memoryURL(for: characterID)),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// 把新一行写入角色的 memory；rf by id string，不带冗余
    func appendMemory(_ line: String, to characterID: UUID) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let newLine = "- [\(stamp)] \(trimmed)\n"
        let url = memoryURL(for: characterID)
        if fm.fileExists(atPath: url.path),
           let existing = try? Data(contentsOf: url) {
            let combined = existing + newLine.data(using: .utf8)!
            try? combined.write(to: url)
        } else {
            try? newLine.data(using: .utf8)?.write(to: url)
        }
    }

    private func memoryURL(for characterID: UUID) -> URL {
        memoryDir.appendingPathComponent("\(characterID.uuidString).md")
    }

    // MARK: - Persistence

    private struct IndexFile: Codable {
        var characters: [CharacterCard]
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let idx = try? JSONDecoder().decode(IndexFile.self, from: data) else { return }
        characters = idx.characters.sorted { $0.createdAt < $1.createdAt }
    }

    private func saveIndex() {
        let payload = IndexFile(characters: characters)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(payload) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}

// MARK: - Avatar cache (off-main)

extension CharacterStore {
    actor AvatarCache {
        static let shared = AvatarCache()
        private var cache: [String: UIImage] = [:]
        private var avatarsDir: URL {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("characters/avatars", isDirectory: true)
        }
        func image(for file: String?) async -> UIImage? {
            guard let f = file else { return nil }
            if let hit = cache[f] { return hit }
            let url = avatarsDir.appendingPathComponent(f)
            guard let data = try? Data(contentsOf: url),
                  let img = UIImage(data: data) else { return nil }
            cache[f] = img
            return img
        }
        func invalidate(_ file: String) { cache[file] = nil }
    }
}
