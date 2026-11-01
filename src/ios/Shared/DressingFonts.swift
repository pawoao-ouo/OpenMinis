import CoreText
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Uploaded fonts (user-supplied font files)
//
// A font the user uploads is a RECORD, like a bubble or a
// pendant: a stable FON number (FON-0005 up; FON-0001..0004
// are the four built-in families), a title, the file name
// under ApplicationSupport/AppearanceStudio/fonts/, and the
// font's postScript name (read from the file at import, never
// guessed from the file name — a file called "cute.ttf" is
// almost never named "cute" inside). Numbers are never reused;
// deleting a font removes its file and its record, and any
// part wearing it falls back to its family (the theme pack
// fields are cleared by the same delete call, so live chat
// can never point at a missing font).
//
// Registration: files are registered with CoreText at store
// init (so a font uploaded in an earlier launch is live on
// the next launch too) and at import. A file that fails to
// register is never added as a record — there is no phantom
// card for a font that cannot render.
//
// Scope, stated plainly: an uploaded font applies through
// the same two parts as built-in families — message part via
// MinisThemeShape.messageFont, UI part via ChatFont. Markdown
// rendering (SelectableMarkdownView) uses UIFont.systemFont
// directly and does not yet follow any family choice; that
// pre-existing gap is untouched by this batch.

struct UploadedFont: Identifiable, Equatable, Codable {
    var number: String
    var title: String
    var fileName: String
    var postScriptName: String
    var detail: String

    var id: String { number }
}

@MainActor
final class UploadedFontStore: ObservableObject {
    static let shared = UploadedFontStore()
    private static let key = "dressing.uploadedFonts"

    @Published private(set) var fonts: [UploadedFont] = []
    private var nextSerial = 5

    /// Built-in families as shop cards, same FON numbering
    /// rule: FON-0001..0004, never reused, never deleted.
    static let builtIns: [(number: String, family: AppearanceFontFamily)] = [
        ("FON-0001", .system),
        ("FON-0002", .rounded),
        ("FON-0003", .serif),
        ("FON-0004", .mono),
    ]

    static func fontsDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AppearanceStudio/fonts", isDirectory: true)
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([UploadedFont].self, from: data) {
            var seen: Set<String> = []
            fonts = decoded.filter { f in
                guard !f.number.isEmpty, !f.fileName.isEmpty,
                      !f.fileName.contains("/"),
                      seen.insert(f.number).inserted else { return false }
                return true
            }
            let maxSerial = fonts.compactMap { Int($0.number.dropFirst(4)) }.max() ?? 4
            nextSerial = max(5, maxSerial + 1)
        }
        registerAll()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(fonts) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    private func registerAll() {
        guard let dir = Self.fontsDirectory() else { return }
        for font in fonts {
            let url = dir.appendingPathComponent(font.fileName)
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Import a user-picked .ttf/.otf file. Returns the new
    /// record, or nil when the file cannot be copied or
    /// registered — a failed import adds nothing.
    @discardableResult
    func importFont(from sourceURL: URL) -> UploadedFont? {
        guard let dir = Self.fontsDirectory() else { return nil }
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        let ext = sourceURL.pathExtension.isEmpty ? "ttf" : sourceURL.pathExtension
        let number = String(format: "FON-%04d", nextSerial)
        let fileName = "\(number).\(ext)"
        let dest = dir.appendingPathComponent(fileName)
        // A document-picker URL is security-scoped: read it
        // inside the access block, then copy from the data.
        var data: Data?
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        data = try? Data(contentsOf: sourceURL)
        guard let data else { return nil }
        do { try data.write(to: dest, options: .atomic) } catch { return nil }
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(dest as CFURL, .process, &error),
              error == nil else {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        // PostScript name from the file itself, not the file name.
        // CoreText path (CGFontCreateWithDataProvider is deprecated
        // and CGFont.postScriptName does not bridge to String here):
        // descriptor from the file data, then a CTFont, then its
        // PostScript name. CTFontCopyPostScriptName returns CFString
        // directly in Swift (no Unmanaged), so cast it to String.
        guard let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) else {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        let ctFont = CTFontCreateWithFontDescriptor(descriptor, 0, nil)
        let psName = CTFontCopyPostScriptName(ctFont) as String
        guard !psName.isEmpty else {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        let title = (sourceURL.deletingPathExtension().lastPathComponent).isEmpty
            ? psName : sourceURL.deletingPathExtension().lastPathComponent
        let font = UploadedFont(number: number, title: title, fileName: fileName,
                                postScriptName: psName,
                                detail: "用户上传的字体，消息或界面可用，预览与真用同一支字体")
        nextSerial += 1
        fonts.append(font)
        save()
        return font
    }

    /// Delete an uploaded font only (built-ins cannot be
    /// deleted). Parts wearing it fall back to their family:
    /// the theme pack's custom-font fields are cleared here,
    /// in the same call, so no part keeps pointing at a
    /// deleted file.
    func delete(_ font: UploadedFont) {
        guard fonts.contains(where: { $0.number == font.number }) else { return }
        if let dir = Self.fontsDirectory() {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(font.fileName))
        }
        fonts.removeAll { $0.number == font.number }
        save()
        let studio = AppearanceStudio.shared
        var pack = studio.currentThemePack()
        var changed = false
        if pack.messageCustomFont == font.postScriptName { pack.messageCustomFont = nil; changed = true }
        if pack.uiCustomFont == font.postScriptName { pack.uiCustomFont = nil; changed = true }
        if changed { studio.persistPack(pack) }
    }

    /// Preview font for an uploaded font, falling back to the
    /// system font when the file is not registered on this
    /// device (a preview never draws a missing font as blank).
    func previewFont(for font: UploadedFont, size: CGFloat) -> Font {
        if let uiFont = UIFont(name: font.postScriptName, size: size) {
            return Font(uiFont)
        }
        return .system(size: size)
    }
}

// MARK: - Document picker for .ttf/.otf files

struct FontFilePicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.font])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
