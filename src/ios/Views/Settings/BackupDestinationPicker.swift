import SwiftUI

private let logger = AppLogger(category: "Backup")

/// Choose where backups go.
///
/// Replaces the earlier pair of buttons ("Add Folder…" / "Add Server…"), which
/// asked the user to pick a MECHANISM before they knew what was on offer — and
/// hid servers they had already configured behind the wrong one of the two.
///
/// This shows, in one place:
///   1. servers already set up — the common case is reusing one, not making
///      another
///   2. add a new server (SMB / WebDAV / SFTP / S3 / FTP)
///   3. add a local or Files-connected folder
///
/// Saved servers come first deliberately: someone who typed in a NAS address
/// once should not have to re-enter it to point a second backup at it.
struct BackupDestinationPicker: View {
    @ObservedObject private var fontSettings = FontSettings.shared

    /// Called after anything is added or selected, so the caller can refresh.
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var remotes: [RcloneRemoteStore.Remote] = []
    @State private var folders: [MountedFolderEntry] = []
    /// [A19] Last-known reachability per remote, from a real probe.
    /// Shown under each server so an unreachable one is never silently
    /// presented as a valid destination.
    @State private var remoteHealth: [String: RcloneRemoteStore.RemoteHealth] = [:]
    @State private var showAddServer = false
    @State private var showFolderPicker = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                if !remotes.isEmpty || !folders.isEmpty {
                    savedSection
                }
                addSection

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.system(size: fontSettings.scaledApp(13)))
                            .foregroundStyle(MinisTheme.destructive)
                        // [T-backup-mount-error-retry] The message alone left
                        // the user with nowhere to go — the add button is
                        // further up the form, and the failure was the last
                        // thing they did. A retry right under the reason turns
                        // "it didn't work" into one tap.
                        Button {
                            self.errorText = nil
                            showFolderPicker = true
                        } label: {
                            Label("Pick the folder again", systemImage: "arrow.clockwise")
                                .font(.system(size: fontSettings.scaledApp(13)))
                        }
                    }
                }
            }
            .navigationTitle("Backup Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddServer) {
                RcloneAddServerView {
                    reload()
                    onChanged()
                }
            }
            .sheet(isPresented: $showFolderPicker) {
                BackupFolderPicker { url in
                    do {
                        _ = try BackupDestinations.addDestination(pickedURL: url)
                        reload()
                        onChanged()
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
            }
            .onAppear(perform: reload)
            .task {
                // [A19] Probe reachability when the picker opens. The list
                // shows first from stored state; each probe updates its row
                // as it answers.
                await probeRemotes()
            }
        }
    }

    // MARK: - Already configured

    private var savedSection: some View {
        Section {
            ForEach(remotes) { r in
                Toggle(isOn: Binding(
                    get: { r.enabled },
                    set: { on in
                        RcloneRemoteStore.setEnabled(r.name, on)
                        reload()
                        onChanged()
                    }
                )) {
                    NavigationLink {
                        BackupDestinationDetailView(target: .remote(r)) {
                            reload()
                            onChanged()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            icon(RcloneBackendCatalog.backend(for: r.backend)?.icon
                                 ?? "externaldrive.connected.to.line.below", .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name)
                                Text("\(r.backend.uppercased()) · /\(r.path)")
                                    .font(.system(size: fontSettings.scaledApp(12)))
                                    .foregroundStyle(MinisTheme.secondaryText)
                                // [A19] Last-known reachability. An enabled
                                // remote that does not answer is shown as
                                // unreachable — never silently valid.
                                Text(healthText(for: r))
                                    .font(.system(size: fontSettings.scaledApp(12)))
                                    .foregroundStyle(healthColour(for: r))
                            }
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        RcloneRemoteStore.remove(name: r.name)
                        reload()
                        onChanged()
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }

            ForEach(folders) { f in
                Toggle(isOn: Binding(
                    get: { BackupDestinations.isSelected(f.id) },
                    set: { on in
                        BackupDestinations.toggle(f.id, on: on)
                        reload()
                        onChanged()
                    }
                )) {
                    NavigationLink {
                        BackupDestinationDetailView(target: .folder(f)) {
                            reload()
                            onChanged()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            icon("folder.fill", .indigo)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name)
                                Text(f.sourceDisplayName)
                                    .font(.system(size: fontSettings.scaledApp(12)))
                                    .foregroundStyle(MinisTheme.secondaryText)
                            }
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    // Drops it from the destination list only — the mount
                    // itself may also be in use by the agent, and removing
                    // that from a backup screen would be a surprise.
                    Button(role: .destructive) {
                        BackupDestinations.forget(f.id)
                        reload()
                        onChanged()
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Saved Destinations")
        } footer: {
            Text("Backups are copied to the enabled destinations. Tap for details, or swipe to remove.")
        }
    }

    // MARK: - Adding

    private var addSection: some View {
        Section {
            Button {
                showAddServer = true
            } label: {
                HStack(spacing: 12) {
                    icon("network", .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add Server…").foregroundStyle(.primary)
                        Text("SMB, WebDAV, SFTP, S3, FTP")
                            .font(.system(size: fontSettings.scaledApp(12)))
                            .foregroundStyle(MinisTheme.secondaryText)
                    }
                }
            }

            Button {
                showFolderPicker = true
            } label: {
                HStack(spacing: 12) {
                    icon("folder.badge.plus", .indigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add Folder…").foregroundStyle(.primary)
                        // Names both cases, because "folder" alone reads as
                        // on-device only and hides the more useful half.
                        Text("On this iPhone, iCloud Drive, or a server connected in Files")
                            .font(.system(size: fontSettings.scaledApp(12)))
                            .foregroundStyle(MinisTheme.secondaryText)
                    }
                }
            }
        } header: {
            Text("Add New")
        }
    }

    // MARK: - Helpers

    private func icon(_ name: String, _ colour: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(colour, in: Circle())
    }

    private func reload() {
        remotes = RcloneRemoteStore.remotes
        folders = BackupDestinations.eligibleFolders
        remoteHealth = RcloneRemoteStore.remoteHealth
        errorText = nil
    }

    /// [A19] Probe every configured remote and refresh the shown state.
    /// Runs on appear; a probe that fails leaves the row marked
    /// unreachable rather than removing the remote or flipping its toggle.
    private func probeRemotes() async {
        for r in RcloneRemoteStore.remotes {
            _ = await RcloneRemoteStore.probe(r)
            remoteHealth = RcloneRemoteStore.remoteHealth
        }
    }

    private func healthText(for r: RcloneRemoteStore.Remote) -> String {
        guard let h = remoteHealth[r.name] else { return AppLocalized("Not checked yet") }
        return h.reachable ? AppLocalized("Reachable") : AppLocalized("Unreachable")
    }

    private func healthColour(for r: RcloneRemoteStore.Remote) -> Color {
        guard let h = remoteHealth[r.name] else { return MinisTheme.secondaryText }
        return h.reachable ? .green : .orange
    }
}
