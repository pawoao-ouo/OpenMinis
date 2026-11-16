//
//  MountDetailView.swift
//  MinisApp
//
//  Unified detail page for both "Shared Folders" (shared/skills/memory) and
//  "Mount External Folders" (user-picked external directories). Provides:
//   - Header card with display name, source, linux path, status
//   - Editable name field (external mounts only)
//   - Allow-writes toggle (external mounts, when OS-writable)
//   - Files-visibility toggle (shared folders only)
//   - "Browse Files" button (both)
//   - "Unmount" destructive button (external mounts only)
//   - Top-right Save button enabled only when changes are pending
//

import SwiftUI
import FileProvider

/// Kind of mount this detail page is editing.
enum MountDetailKind {
    case shared
    case external
}

/// Immutable input to the detail view — describes the mount being edited.
struct MountDetailContext: Equatable {
    let kind: MountDetailKind

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

    // Editable defaults
    let initialName: String
    /// Whether the name can be edited. Shared folders disable this.
    let canRename: Bool

    // External-mount-only state
    let externalMountId: UUID?
    /// OS-level writability. If false, the allow-writes toggle is disabled + off.
    let isOSWritable: Bool
    /// Current user-intent allow-writes flag.
    let initialUserAllowWrite: Bool
    /// Activation state of this mount, when known. Nil for shared folders
    /// (which have no activation step). Drives the status pill in the
    /// header: a live mount keeps its write badge, a dead mount names its
    /// state instead. Defaults to nil so call sites that have no state
    /// (shared folders) compile unchanged.
    let activationState: MountActivationState? = nil

    // Shared-folders-only state
    /// For shared folders: the UserDefaults key / subdir name.
    let sharedFolderName: String?
    let initialVisibleInFiles: Bool
    /// Read-only badge for shared folders (skills/memory are read-only from Files).
    let isReadOnlyFromFiles: Bool

    /// Explicit initializer: the memberwise one does not accept
    /// `activationState` (a defaulted property), so the external-mount
    /// call site cannot pass it. This init takes every field, with
    /// `activationState` defaulting to nil for shared folders.
    init(
        kind: MountDetailKind,
        linuxPath: String,
        sourceDisplayName: String?,
        hostURL: URL,
        iconName: String,
        iconColor: Color,
        subtitle: String?,
        initialName: String,
        canRename: Bool,
        externalMountId: UUID?,
        isOSWritable: Bool,
        initialUserAllowWrite: Bool,
        activationState: MountActivationState? = nil,
        sharedFolderName: String?,
        initialVisibleInFiles: Bool,
        isReadOnlyFromFiles: Bool
    ) {
        self.kind = kind
        self.linuxPath = linuxPath
        self.sourceDisplayName = sourceDisplayName
        self.hostURL = hostURL
        self.iconName = iconName
        self.iconColor = iconColor
        self.subtitle = subtitle
        self.initialName = initialName
        self.canRename = canRename
        self.externalMountId = externalMountId
        self.isOSWritable = isOSWritable
        self.initialUserAllowWrite = initialUserAllowWrite
        self.activationState = activationState
        self.sharedFolderName = sharedFolderName
        self.initialVisibleInFiles = initialVisibleInFiles
        self.isReadOnlyFromFiles = isReadOnlyFromFiles
    }
}

struct MountDetailView: View {
    @ObservedObject private var fontSettings = FontSettings.shared
    let context: MountDetailContext
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismissEnvironment

    @State private var nameText: String
    @State private var allowWrite: Bool
    @State private var visibleInFiles: Bool
    @State private var showingBrowser = false
    @State private var showingUnmountConfirm = false
    @State private var errorText: String?

    init(context: MountDetailContext, onDismiss: @escaping () -> Void) {
        self.context = context
        self.onDismiss = onDismiss
        _nameText = State(initialValue: context.initialName)
        _allowWrite = State(initialValue: context.initialUserAllowWrite)
        _visibleInFiles = State(initialValue: context.initialVisibleInFiles)
    }

    // MARK: - Dirty tracking

    private var nameChanged: Bool {
        nameText.trimmingCharacters(in: .whitespaces) != context.initialName
    }

    private var allowWriteChanged: Bool {
        context.kind == .external && allowWrite != context.initialUserAllowWrite
    }

    private var visibilityChanged: Bool {
        context.kind == .shared && visibleInFiles != context.initialVisibleInFiles
    }

    private var hasChanges: Bool {
        nameChanged || allowWriteChanged || visibilityChanged
    }

    private var nameIsValid: Bool {
        MountedFolderEntry.isValidMountName(nameText)
    }

    private var canSave: Bool {
        guard hasChanges else { return false }
        if nameChanged && !nameIsValid { return false }
        return true
    }

    // MARK: - Body

    var body: some View {
        List {
            headerSection

            if context.canRename {
                nameSection
            }

            if context.kind == .external && context.isOSWritable {
                allowWriteSection
            }

            if context.kind == .shared {
                visibilitySection
            }

            browseSection

            if context.kind == .external {
                unmountSection
            }
        }
        .navigationTitle(context.canRename ? AppLocalized("Edit Mount") : AppLocalized("Folder Details"))
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
        .alert(
            AppLocalized("Unmount this folder?"),
            isPresented: $showingUnmountConfirm
        ) {
            Button(AppLocalized("Unmount"), role: .destructive) {
                unmountExternal()
            }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text("The source folder in Files will not be deleted. You can re-mount it later.")
        }
        .alert(
            AppLocalized("Error"),
            isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )
        ) {
            Button(AppLocalized("OK"), role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: - Sections

    /// Status pill in the header, mirroring the row's language
    /// (MountedFolderRow.statusBadge): a live mount keeps its write badge
    /// (R/W / Locked / Read-only); a dead mount names its activation state
    /// instead, so a dead mount never claims R/W here either. Nil (shared
    /// folders, which have no activation step) shows nothing.
    @ViewBuilder
    private var statusPill: some View {
        if let state = context.activationState {
            if state.isActive {
                writeBadge
            } else {
                switch state {
                case .active:
                    writeBadge // Unreachable (isActive above); keeps the switch exhaustive.
                case .stale:
                    badgePill(text: AppLocalized("Stale"), color: .orange)
                case .permissionDenied:
                    badgePill(text: AppLocalized("Denied"), color: .red)
                case .failed:
                    badgePill(text: AppLocalized("Failed"), color: .red)
                case .contentsUnavailable:
                    badgePill(text: AppLocalized("Not downloaded"), color: .orange)
                }
            }
        }
    }

    /// Write badge for a live mount, mirroring the row's accessBadge:
    /// "R/W" when the OS and the user both allow writes, "Locked" when
    /// the user turned Allow Writes off, "Read-only" when the OS itself
    /// forbids writes. Reads the saved context values (not the pending
    /// toggle), same as the row reads the saved entry.
    @ViewBuilder
    private var writeBadge: some View {
        if !context.isOSWritable {
            badgePill(text: AppLocalized("Read-only"), color: .orange)
        } else if !context.initialUserAllowWrite {
            badgePill(text: AppLocalized("Locked"), color: .purple)
        } else {
            badgePill(text: AppLocalized("R/W"), color: .green)
        }
    }

    private func badgePill(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: fontSettings.scaledApp(11), weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1)
            )
    }

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
                    statusPill
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
                    // A failed mount says why, mirroring the row: the message
                    // comes from the activation error (empty when the state
                    // is only the missing-state fallback).
                    if case .failed(let message) = context.activationState, !message.isEmpty {
                        Text(verbatim: message)
                            .font(.system(size: fontSettings.scaledApp(11)))
                            .foregroundStyle(MinisTheme.destructive)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private var nameSection: some View {
        Section {
            TextField("name", text: $nameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if nameChanged && !nameIsValid {
                Text("Mount name must not be empty, contain '/', or be '.' or '..'.")
                    .font(.system(size: fontSettings.scaledApp(12)))
                    .foregroundStyle(MinisTheme.destructive)
            }
        } header: {
            Text("Name")
        } footer: {
            Text("Becomes the folder name under /var/minis/mounts/")
        }
    }

    private var allowWriteSection: some View {
        Section {
            Toggle(isOn: $allowWrite) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow writes")
                    Text(allowWrite
                         ? AppLocalized("AI, shell, and Files browser can modify files in this mount.")
                         : AppLocalized("This mount is exposed as read-only to protect it from accidental edits."))
                        .font(.system(size: fontSettings.scaledApp(12)))
                        .foregroundStyle(MinisTheme.secondaryText)
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("When off, the iSH shell and AI tools cannot create, edit, or delete files in this mount.")
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
            if context.isReadOnlyFromFiles {
                Text("Read-only from the Files app. The app itself can always read and write.")
                    .font(.system(size: fontSettings.scaledApp(12)))
                    .foregroundStyle(MinisTheme.secondaryText)
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

    private var unmountSection: some View {
        Section {
            Button(role: .destructive) {
                showingUnmountConfirm = true
            } label: {
                Label {
                    Text("Unmount")
                } icon: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .frame(width: 21, height: 21)
                        .background(.red, in: Circle())
                }
            }
        }
    }

    // MARK: - Actions

    private func save() {
        switch context.kind {
        case .external:
            guard let id = context.externalMountId else { return }
            let manager = MountedFoldersManager.shared
            do {
                if nameChanged {
                    try manager.rename(id: id, to: nameText.trimmingCharacters(in: .whitespaces))
                }
                if allowWriteChanged {
                    manager.setUserAllowWrite(id: id, to: allowWrite)
                }
            } catch {
                errorText = error.localizedDescription
                return
            }
        case .shared:
            if visibilityChanged, let name = context.sharedFolderName {
                SharedFolderVisibility.setVisible(name, to: visibleInFiles)
                // Ask the FileProvider to re-enumerate so iOS Files reflects the change.
                signalFileProviderRoot()
            }
        }
        onDismiss()
        dismissEnvironment()
    }

    private func unmountExternal() {
        guard let id = context.externalMountId else { return }
        MountedFoldersManager.shared.remove(id: id)
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
