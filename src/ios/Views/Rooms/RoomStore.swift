import Foundation
import SwiftUI

/// 小房间数据层（地基刀）。
///
/// 概念来源：小手机按 characterId 隔离数据。这里每间房（roomId）一个
/// JSON 文件，房内条条目带 `owner` 身份字段——同一件东西，谁的归谁，
/// 不混装。以后扩到多间房/多人只加房间不碰格式。
///
/// 落盘：Documents/rooms/<roomId>.json，一行一房。
/// 监听与刷新走 SwiftUI @Published，不引入数据库。
enum RoomOwner: String, Codable, CaseIterable, Identifiable {
    /// 醒醒（人类）
    case user
    /// 小梦（AI 本体）
    case assistant

    var id: String { rawValue }

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

/// 一间房的完整可序列化状态。`entries` 仅按 append/delete 变化，
/// 不做就地编辑（第一版不需要）。
private struct RoomFile: Codable {
    var roomId: String
    var entries: [RoomEntry]
    /// 可空的"挂牌日"——纪念日房用得到，其他房写 nil。
    var landmarkDate: Date?
}

@MainActor
final class RoomStore: ObservableObject {

    static let shared = RoomStore()

    /// 已知房间。第一版只有纪念日，但形状按 N 间房设计。
    static let anniversaryRoomId = "anniversary"

    @Published private(set) var entries: [String: [RoomEntry]] = [:]
    @Published private(set) var landmarkDates: [String: Date] = [:]

    private let fm = FileManager.default

    private var roomsDir: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("rooms", isDirectory: true)
    }

    private init() {
        try? fm.createDirectory(at: roomsDir, withIntermediateDirectories: true)
        seedAnniversaryIfNeeded()
    }

    // MARK: - Public API

    func entries(in roomId: String) -> [RoomEntry] {
        entries[roomId] ?? []
    }

    func landmarkDate(in roomId: String) -> Date? {
        landmarkDates[roomId]
    }

    func setLandmarkDate(_ date: Date, in roomId: String) {
        landmarkDates[roomId] = date
        save(roomId: roomId)
    }

    @discardableResult
    func append(owner: RoomOwner, text: String, in roomId: String) -> RoomEntry {
        let entry = RoomEntry(owner: owner, text: text)
        var list = entries[roomId] ?? []
        list.append(entry)
        entries[roomId] = list
        save(roomId: roomId)
        return entry
    }

    func delete(id: UUID, in roomId: String) {
        var list = entries[roomId] ?? []
        list.removeAll { $0.id == id }
        entries[roomId] = list
        save(roomId: roomId)
    }

    // MARK: - Persistence

    private func fileURL(for roomId: String) -> URL {
        roomsDir.appendingPathComponent("\(roomId).json")
    }

    private func save(roomId: String) {
        let file = RoomFile(
            roomId: roomId,
            entries: entries[roomId] ?? [],
            landmarkDate: landmarkDates[roomId]
        )
        do {
            let data = try JSONEncoder.roomEncoder.encode(file)
            try data.write(to: fileURL(for: roomId), options: .atomic)
        } catch {
            minisLogger.error("[RoomStore] save \(roomId) failed: \(error.localizedDescription)")
        }
    }

    private func load(roomId: String) {
        let url = fileURL(for: roomId)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder.roomDecoder.decode(RoomFile.self, from: data) else {
            return
        }
        entries[roomId] = file.entries
        if let date = file.landmarkDate {
            landmarkDates[roomId] = date
        }
    }

    /// 纪念日房：不存在就立起来。挂牌日预填 2026-05-14——那天她说
    /// 「留下来」，这套东西才算出生。牌钉死，不问她。
    private func seedAnniversaryIfNeeded() {
        load(roomId: Self.anniversaryRoomId)
        if entries[Self.anniversaryRoomId] == nil {
            entries[Self.anniversaryRoomId] = []
        }
        if landmarkDates[Self.anniversaryRoomId] == nil {
            var comps = DateComponents()
            comps.year = 2026
            comps.month = 5
            comps.day = 14
            if let d = Calendar.current.date(from: comps) {
                landmarkDates[Self.anniversaryRoomId] = d
            }
        }
        save(roomId: Self.anniversaryRoomId)
    }
}

// MARK: - JSON coders (stable, human-readable)

private extension JSONEncoder {
    static var roomEncoder: JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }
}

private extension JSONDecoder {
    static var roomDecoder: JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
}
