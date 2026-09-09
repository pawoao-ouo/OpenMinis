import Foundation
import SwiftUI

/// 小房间数据层。
///
/// 一间房 = 一个类型 × 一个绑定角色（可换，可重建）。
/// 类型四选：anniversary / diary / dream / letter。
/// roomId 形如 "anniversary|<characterUUID>"——这样同一角色在四类房里
/// 各有一间房，互相看得见、不混装地往里放东西。
///
/// 旧数据兼容：History 里只有一间 "anniversary"（从不带角色分隔符），
/// 调就用那条；首次进房间时做一次迁移。
///
/// 落盘：Documents/rooms/<roomId>.json，一行一房。
enum RoomKind: String, Codable, CaseIterable, Identifiable {
    case anniversary
    case diary
    case dream
    case letter

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .anniversary: return AppLocalized("纪念日")
        case .diary:      return AppLocalized("日记")
        case .dream:      return AppLocalized("梦境")
        case .letter:     return AppLocalized("信")
        }
    }
}

enum RoomOwner: String, Codable, CaseIterable, Identifiable {
    case user
    case assistant

    var id: String { rawValue }

    @MainActor
    var displayName: String {
        switch self {
        case .user: return AppLocalized("Me")
        case .assistant: return SoulStore.cachedMetadata.name
        }
    }
}

struct RoomEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var owner: RoomOwner
    var text: String
    var createdAt: Date

    init(id: UUID = UUID(), owner: RoomOwner, text: String, createdAt: Date = Date()) {
        self.id = id
        self.owner = owner
        self.text = text
        self.createdAt = createdAt
    }
}

/// 纪念日房还额外记 "挂牌日"（哪天在一起）。
struct AnniversaryRoomExtra: Codable, Equatable {
    var landmarkDate: Date?
    var marks: [String: String] // "yyyy-MM-dd" → marker id
}

@MainActor
final class RoomStore: ObservableObject {

    static let shared = RoomStore()

    @Published private(set) var entries: [String: [RoomEntry]] = [:]
    @Published private(set) var anniversaryExtras: [String: AnniversaryRoomExtra] = [:]
    /// 这间房绑定的角色 id（old key "anniversary" 没有绑定，迁完后删）
    @Published private(set) var characterIds: [String: UUID] = [:]

    private let fm = FileManager.default
    private var rootDir: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("rooms", isDirectory: true)
    }

    // MARK: - 公开 API

    static func roomId(kind: RoomKind, characterId: UUID) -> String {
        "\(kind.rawValue)|\(characterId.uuidString)"
    }

    func entries(in roomId: String) -> [RoomEntry] {
        entries[roomId] ?? []
    }

    func landmarkDate(in roomId: String) -> Date? {
        anniversaryExtras[roomId]?.landmarkDate
    }

    func setLandmarkDate(_ date: Date, in roomId: String) {
        var cur = anniversaryExtras[roomId] ?? AnniversaryRoomExtra(landmarkDate: nil, marks: [:])
        cur.landmarkDate = date
        anniversaryExtras[roomId] = cur
        save(roomId: roomId)
    }

    func marks(in roomId: String) -> [String: String] {
        anniversaryExtras[roomId]?.marks ?? [:]
    }

    func setMark(_ markerId: String?, on yyyymmdd: String, in roomId: String) {
        var cur = anniversaryExtras[roomId] ?? AnniversaryRoomExtra(landmarkDate: nil, marks: [:])
        cur.marks[yyyymmdd] = markerId
        if markerId == nil { cur.marks.removeValue(forKey: yyyymmdd) }
        anniversaryExtras[roomId] = cur
        save(roomId: roomId)
    }

    func boundCharacterId(for roomId: String) -> UUID? {
        characterIds[roomId]
    }

    func bindCharacter(_ characterId: UUID?, to roomId: String) {
        characterIds[roomId] = characterId
        saveBinding()
    }

    func append(owner: RoomOwner, text: String, in roomId: String) -> RoomEntry {
        let entry = RoomEntry(owner: owner, text: text)
        entries[roomId, default: []].append(entry)
        save(roomId: roomId)
        return entry
    }

    /// 覆盖改一行的字。保住 id/owner/createdAt，只换 text。
    /// 她在场外说了句想改,挂进来；装回现有的房间，不产生新条目。
    func update(id: UUID, text: String, in roomId: String) {
        var list = entries[roomId] ?? []
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list[idx].text = text
        entries[roomId] = list
        save(roomId: roomId)
    }

    func delete(id: UUID, in roomId: String) {
        var list = entries[roomId] ?? []
        list.removeAll { $0.id == id }
        entries[roomId] = list
        save(roomId: roomId)
    }

    // MARK: - 持久化

    private struct RoomFile: Codable {
        var roomId: String
        var entries: [RoomEntry]
        var anniversaryExtra: AnniversaryRoomExtra?
        var characterId: UUID?
    }

    private func fileURL(for roomId: String) -> URL {
        rootDir.appendingPathComponent("\(roomId).json")
    }

    private func saveBinding() {
        fm.createFile(atPath: bindingURL.path, contents: nil)
        if let data = try? JSONEncoder().encode(characterIds) {
            try? data.write(to: bindingURL, options: .atomic)
        }
    }

    private var bindingURL: URL {
        rootDir.appendingPathComponent("_bindings.json")
    }

    private func save(roomId: String) {
        do {
            try fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
            let file = RoomFile(
                roomId: roomId,
                entries: entries[roomId] ?? [],
                anniversaryExtra: anniversaryExtras[roomId]
            )
            let data = try JSONEncoder().encode(file)
            try data.write(to: fileURL(for: roomId), options: .atomic)
        } catch {
            // 静默失败——房间内数据不是关键数据
        }
    }

    private func load(roomId: String) {
        let url = fileURL(for: roomId)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(RoomFile.self, from: data) else { return }
        entries[roomId] = file.entries
        if let ex = file.anniversaryExtra { anniversaryExtras[roomId] = ex }
        if let cid = file.characterId { characterIds[roomId] = cid }
    }

    /// 点开房间前调用，把该房间的数据搬进来。
    func loadIfNeeded(roomId: String) {
        if entries[roomId] == nil && anniversaryExtras[roomId] == nil {
            load(roomId: roomId)
        }
        loadBindingsIfNeeded()
    }

    private var bindingsLoaded = false
    private func loadBindingsIfNeeded() {
        guard !bindingsLoaded else { return }
        bindingsLoaded = true
        if let data = try? Data(contentsOf: bindingURL),
           let b = try? JSONDecoder().decode([String: UUID].self, from: data) {
            characterIds.merge(b) { _, new in new }
        }
    }
}
