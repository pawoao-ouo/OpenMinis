import Foundation
import SwiftUI
import UIKit

/// Saved theme packs. Current pack stays in AppearanceStudio;
/// this is the history drawer: save / apply / rename / delete.
struct AppearanceSavedTheme: Equatable, Codable, Identifiable {
    var id: String
    var name: String
    var savedAt: Date
    var pack: AppearanceThemePack

    static let libraryKey = "appearanceStudio.themeLibrary.v1"
    static let limit = 40
}

extension AppearanceStudio {
    private static let libraryKey = AppearanceSavedTheme.libraryKey

    func savedThemes() -> [AppearanceSavedTheme] {
        guard let data = UserDefaults.standard.data(forKey: Self.libraryKey),
              let list = try? JSONDecoder().decode([AppearanceSavedTheme].self, from: data) else {
            return []
        }
        return list.sorted { $0.savedAt > $1.savedAt }
    }

    func saveCurrentTheme(name: String? = nil) -> AppearanceSavedTheme {
        var pack = exportThemePack(includeWallpaper: true)
        let trimmed = (name ?? pack.name).trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? pack.name : trimmed
        pack.name = label
        let item = AppearanceSavedTheme(
            id: UUID().uuidString.lowercased(),
            name: label,
            savedAt: Date(),
            pack: pack
        )
        var list = savedThemes()
        list.insert(item, at: 0)
        if list.count > AppearanceSavedTheme.limit {
            list = Array(list.prefix(AppearanceSavedTheme.limit))
        }
        persistLibrary(list)
        return item
    }

    func applySavedTheme(id: String) -> Bool {
        guard let item = savedThemes().first(where: { $0.id == id }) else { return false }
        applyThemePack(item.pack)
        return true
    }

    func renameSavedTheme(id: String, name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var list = savedThemes()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return false }
        list[idx].name = trimmed
        list[idx].pack.name = trimmed
        persistLibrary(list)
        return true
    }

    func deleteSavedTheme(id: String) -> Bool {
        var list = savedThemes()
        let before = list.count
        list.removeAll { $0.id == id }
        guard list.count != before else { return false }
        persistLibrary(list)
        return true
    }

    private func persistLibrary(_ list: [AppearanceSavedTheme]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.libraryKey)
        }
        themePackRevision += 1
        objectWillChange.send()
    }
}
