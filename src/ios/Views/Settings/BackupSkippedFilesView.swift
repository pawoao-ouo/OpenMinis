import SwiftUI

/// The files a backup left out, and which conversation each came from.
///
/// The summary could only say "64 file(s)". That answers "how many" and never
/// "which ones" — so a user could not tell whether the cap had quietly dropped
/// something they cared about or a pile of incidental scratch files. Deciding
/// whether to raise the limit needs the names and the sizes.
///
/// Grouped by conversation because that is how the files are organised in the
/// user's head; a flat list of 500 filenames is not browsable.
struct BackupSkippedFilesView: View {
    @ObservedObject private var fontSettings = FontSettings.shared
    let record: BackupHistory.Record

    private struct Group: Identifiable {
        let id: String
        let title: String
        let entries: [BackupHistory.SkippedEntry]
        var bytes: Int64 { entries.reduce(0) { $0 + $1.size } }
    }

    /// Conversations first (ordered by how much they contributed), then
    /// everything else. Sorting by total bytes puts the reason the package is
    /// incomplete at the top.
    private var groups: [Group] {
        var byKey: [String: [BackupHistory.SkippedEntry]] = [:]
        for e in record.skippedEntries {
            let parts = e.path.split(separator: "/")
            let key: String
            if parts.count > 1, parts[0] == "chats" {
                key = e.sessionTitle ?? String(parts[1])
            } else {
                key = parts.first.map(String.init) ?? "other"
            }
            byKey[key, default: []].append(e)
        }
        return byKey
            .map { Group(id: $0.key, title: $0.key,
                         entries: $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.bytes > $1.bytes }
    }

    private var shownCount: Int { record.skippedEntries.count }

    /// [A8] The reason an entry was left out, in the user's language.
    /// Nil for the size cap (and for records written before reasons were
    /// tracked): that was the only reason this list ever showed, so it
    /// needs no label.
    private func reasonLabel(for entry: BackupHistory.SkippedEntry) -> String? {
        switch entry.reason {
        case "not_downloaded":
            return AppLocalized("Not downloaded")
        case "unreadable":
            return AppLocalized("Unreadable")
        case "after_snapshot":
            return AppLocalized("Changed after snapshot")
        default:
            return nil
        }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Files", value: "\(record.skippedFiles)")
                LabeledContent("Total size", value: ByteCountFormatter.string(
                    fromByteCount: record.skippedEntries.reduce(0) { $0 + $1.size },
                    countStyle: .file))
            } footer: {
                // Say so when the list is partial rather than letting the
                // numbers quietly disagree with the rows below.
                if shownCount < record.skippedFiles {
                    Text("Showing the \(shownCount) largest of \(record.skippedFiles) excluded files. Their contents are not in the backup — the backup records that they existed.")
                } else {
                    Text("These files' contents are not in the backup — it records that they existed, at these sizes.")
                }
            }

            ForEach(groups) { group in
                Section {
                    ForEach(group.entries) { e in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.fileName)
                                    .font(.system(size: fontSettings.scaledApp(16)))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                // [A8] Size-cap exclusions need no label — that
                                // is what this list used to show exclusively.
                                // Anything else gets its reason, so a file left
                                // out because it was not downloaded does not
                                // read as "too big".
                                if let reason = reasonLabel(for: e) {
                                    Text(reason)
                                        .font(.system(size: fontSettings.scaledApp(12)))
                                        .foregroundStyle(MinisTheme.secondaryText)
                                }
                            }
                            Spacer(minLength: 12)
                            Text(ByteCountFormatter.string(fromByteCount: e.size,
                                                           countStyle: .file))
                                .font(.system(size: fontSettings.scaledApp(12)).monospacedDigit())
                                .foregroundStyle(MinisTheme.secondaryText)
                        }
                    }
                } header: {
                    Text(group.title)
                }
            }
        }
        .navigationTitle("Excluded Files")
        .navigationBarTitleDisplayMode(.inline)
    }
}
