//
//  MountDetailView.swift
//  MinisApp
//
//  Detail page for "Shared Folders" (shared/skills/memory). Provides:
//   - Header card with display name, source, linux path
//   - Files-visibility toggle (whether the folder shows in iOS Files)
//   - "Browse Files" button
//   - Top-right Save button enabled only when changes are pending
//
//  This used to be a unified page shared with "Mount External Folders".
//  That feature was deleted (the folder picker cannot work on the
//  resigned build), so the external-mount half — rename, allow-writes,
//  activation state, unmount — is gone with it.
//

import SwiftUI
import FileProvider

/// Immutable input to the detail view — describes the folder being edited.
struct MountDetailContext: Equatable {
    // Display
    let linuxPath: String
    let sourceDisplayName: String?
    /// The resolved host URL for the "Browse Files" action.
    let hostURL: URL
    /// SF Symbol name used in the header icon.
    let iconName: String
    /// Icon background color.
    let iconColor: Color
    /// Shown in a subtitle line; optional.
    let subtitle: String?

    let initialName: String

    /// The UserDefaults key / subdir name.
    let sharedFolderName: String?
    let initialVisibleInFiles: Bool
    /// Read-only badge (skills/memory are read-only from Files).
    let isReadOnlyFromFiles: Bool
}

struct MountDetailView: View {
    @ObservedObject private var fontSettings = FontSettings.shared
    let context: MountDetailContext
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismissEnvironment

    @State private var visibleInFiles: Bool
    @State private var showingBrowser = false

    init(context: MountDetailContext, onDismiss: @escaping () -> Void) {
        self.context = context
        self.onDismiss = onDismiss
        _visibleInFiles = State(initialValue: context.initialVisibleInFiles)
    }

    // MARK: - Dirty tracking

    private var visibilityChanged: Bool {
        visibleInFiles != context.initialVisibleInFiles
    }

    private var hasChanges: Bool {
        visibilityChanged
    }

    private var canSave: Bool {
        hasChanges
    }

    // MARK: - Body

    var body: some View {
        List {
            headerSection

            visibilitySection

            browseSection
        }
        .navigationTitle(AppLocalized("Folder Details"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(AppLocalized("Save")) {
                    save()
                }
                .disabled(!canSave)
            }
        }
        .sheet(isPresented: $showingBrowser) {
            NavigationStack {
                FileBrowserView(
                    rootPath: context.hostURL,
                    rootLabel: context.linuxPath
                )
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: context.iconName)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(context.iconColor, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.initialName)
                        .font(.system(size: fontSettings.scaledApp(17), weight: .semibold))
                    Text(context.linuxPath)
                        .font(.system(size: fontSettings.scaledApp(12)).monospaced())
                        .foregroundStyle(MinisTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let source = context.sourceDisplayName {
                        Text(verbatim: "← \(source)")
                            .font(.system(size: fontSettings.scaledApp(11)))
                            .foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
                            .lineLimit(1)
                    }
                    if let subtitle = context.subtitle {
                        Text(subtitle)
                            .font(.system(size: fontSettings.scaledApp(11)))
                            .foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private var visibilitySection: some View {
        Section {
            Toggle(isOn: $visibleInFiles) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show in Files app")
                    Text(visibleInFiles
                         ? AppLocalized("This folder appears in Files → On My iPhone → 嘟嘟.")
                         : AppLocalized("Hidden from the iOS Files app only. AI, shell, and @-mention can still read this folder."))
                        .font(.system(size: fontSettings.scaledApp(12)))
                        .foregroundStyle(MinisTheme.secondaryText)
                }
            }
            // [Batch 26] Without the App Group this toggle cannot reach the
            // FileProvider extension — disable it and say why.
            .disabled(!SharedContainerStore.isAppGroupAvailable)
            if !SharedContainerStore.isAppGroupAvailable {
                Text(AppLocalized("Shared folders can't sync with the Files app in this build (App Group permission missing)."))
                    .font(.system(size: fontSettings.scaledApp(12)))
                    .foregroundStyle(MinisTheme.secondaryText)
            }
            if context.isReadOnlyFromFiles {
            }
        } header: {
            Text("Files app")
        }
    }

    private var browseSection: some View {
        Section {
            Button {
                showingBrowser = true
            } label: {
                Label {
                    Text("Browse Files")
                } icon: {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .frame(width: 21, height: 21)
                        .background(.blue, in: Circle())
                }
            }
        }
    }

    // MARK: - Actions

    private func save() {
        if visibilityChanged, let name = context.sharedFolderName {
            SharedFolderVisibility.setVisible(name, to: visibleInFiles)
            // Ask the FileProvider to re-enumerate so iOS Files reflects the change.
            signalFileProviderRoot()
        }
        onDismiss()
        dismissEnvironment()
    }

    private func signalFileProviderRoot() {
        let domainIdentifier = NSFileProviderDomainIdentifier("com.openminis.clone.files")
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
            guard let domain = domains.first(where: { $0.identifier == domainIdentifier }) else {
                return
            }
            NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer) { _ in }
        }
    }
}
