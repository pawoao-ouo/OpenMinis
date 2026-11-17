import SwiftUI

private let logger = AppLogger(category: "Backup")

/// Choose where backups go (servers only).
///
/// This shows, in one place:
///   1. servers already set up — the common case is reusing one, not making
///      another
///   2. add a new server (SMB / WebDAV / SFTP / S3 / FTP)
///
/// Saved servers come first deliberately: someone who typed in a NAS address
/// once should not have to re-enter it to point a second backup at it.
struct BackupDestinationPicker: View {
    @ObservedObject private var fontSettings = FontSettings.shared

    /// Called after anything is added or selected, so the caller can refresh.
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var remotes: [RcloneRemoteStore.Remote] = []
    /// [A19] Last-known reachability per remote, from a real probe.
    /// Shown under each server so an unreachable one is never silently
    /// presented as a valid destination.
    @State private var remoteHealth: [String: RcloneRemoteStore.RemoteHealth] = [:]
    @State private var showAddServer = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                if !remotes.isEmpty {
                    savedSection
                }
                addSection

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.system(size: fontSettings.scaledApp(13)))
                            .foregroundStyle(MinisTheme.destructive)
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
                        BackupDestinationDetailView(target: r) {
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
