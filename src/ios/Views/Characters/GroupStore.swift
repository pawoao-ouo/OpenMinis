import Foundation
import SwiftUI

/// 群聊卡：几个人物的"拉群"。QQ 式——挑联系人，起名，开聊。
///
/// 数据落 Documents/groups/<id>.json 的一个数组 index。会话存在 ChatStore
/// （source="group:<uuid>"），主聊天 listSessions 里有 NOT LIKE 'group:%'
/// 过滤；这里通过 listSessionsForGroup 找回来。
///
/// 记忆共享策略：群里各角色还是各背各的 memory.md；群聊有自己的
/// groupNotes.md 记录的是这场群里约定的事（类 memory 但群特有）。
internal struct GroupCard: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// 参与的 CharacterCard.id 集合
    var memberIds: [UUID]
    /// 喜欢的颜色（用于头像 fallback）
    var hue: Double
    /// 自定义头像文件（可选；没有就用成员首字拼图）
    var avatarImageFile: String?
    /// 这个群说明性的描述，会同时进入 system overlay（规则、氛围）
    var brief: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        memberIds: [UUID] = [],
        hue: Double? = nil,
        avatarImageFile: String? = nil,
        brief: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.memberIds = memberIds
        self.hue = hue ?? Double(abs(id.uuidString.hashValue) % 360) / 360.0
        self.avatarImageFile = avatarImageFile
        self.brief = brief
        self.createdAt = createdAt
    }
}

/// 群聊的管理家。读写落盘 groups.json。Avatar 也走
/// Documents/groups/avatars/<gid>.jpg。
@MainActor
final class GroupStore: ObservableObject {

    static let shared = GroupStore()

    @Published private(set) var groups: [GroupCard] = []

    private let fm = FileManager.default
    private var rootDir: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("groups", isDirectory: true)
    }
    private var avatarsDir: URL { rootDir.appendingPathComponent("avatars", isDirectory: true) }
    private var indexURL: URL { rootDir.appendingPathComponent("index.json") }

    private init() {
        try? fm.createDirectory(at: avatarsDir, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: - CRUD

    func upsert(_ group: GroupCard) {
        if let idx = groups.firstIndex(where: { $0.id == group.id }) {
            groups[idx] = group
        } else {
            groups.append(group)
        }
        saveIndex()
    }

    func remove(id: UUID) {
        let keep = groups.first(where: { $0.id == id })
        groups.removeAll { $0.id == id }
        saveIndex()
        if let a = keep?.avatarImageFile {
            try? fm.removeItem(at: avatarsDir.appendingPathComponent(a))
        }
    }

    func setAvatarJPEG(_ data: Data, for groupID: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let fname = "\(groupID.uuidString).jpg"
        do {
            try data.write(to: avatarsDir.appendingPathComponent(fname), options: .atomic)
            groups[idx].avatarImageFile = fname
            saveIndex()
        } catch {
            AppLogger(category: "Groups").error("[Groups] avatar write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Persistence

    private struct IndexFile: Codable { var groups: [GroupCard] }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let idx = try? JSONDecoder().decode(IndexFile.self, from: data) else { return }
        groups = idx.groups.sorted { $0.createdAt < $1.createdAt }
    }

    private func saveIndex() {
        let payload = IndexFile(groups: groups)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(payload) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
