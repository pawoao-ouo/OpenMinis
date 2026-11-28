import SwiftUI
import UIKit

struct EnvironmentVariablesView: View {
    @StateObject private var store = EnvVarStore.shared
    @StateObject private var privacy = EnvVarPrivacyStore.shared
    @ObservedObject private var deepLink = DeepLinkCoordinator.shared
    @ObservedObject private var fontSettings = FontSettings.shared
    @State private var searchText = ""
    @State private var showingAddSheet = false
    @State private var editingEntry: EnvVarEntry?
    @State private var revealedKeys: Set<String> = []
    @State private var copiedId: String?
    @State private var prefillKey = ""
    @State private var prefillValue = ""
    @State private var prefillNote = ""
    @State private var overwriteConfirm: OverwriteRequest?
    // [Batch 23] The list's own failure surface. lastSaveFailure is NOT
    // @Published, so the footer reads this @State instead — the action
    // captures the reason here, same pattern as the form's saveError.
    @State private var listError: String?
    @State private var copyConfirm: CopyRequest?

    private struct OverwriteRequest: Identifiable {
        let id = UUID()
        let entryId: String
        let key: String
        let newValue: String
    }

    private struct CopyRequest: Identifiable {
        let id = UUID()
        let entryId: String
        let key: String
        let value: String
    }

    private var filteredEntries: [EnvVarEntry] {
        if searchText.isEmpty {
            return store.entries
        }
        return store.entries.filter { $0.key.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            Section {
                Toggle("Privacy Mode", isOn: $privacy.enabled)
            }

            // [Batch 23] One inline place for list-action failures
            // (deep-link update, Replace, swipe-delete). Rendered from the
            // @State the action captured — lastSaveFailure itself is not
            // @Published, so a footer reading it would never appear.
            if let listError {
                Section {
                    Text(listError)
                        .font(.system(size: fontSettings.scaledApp(12)))
                        .foregroundStyle(MinisTheme.secondaryText)
                }
            }

            if store.entries.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "terminal.fill")
                            .font(.largeTitle)
                            .foregroundStyle(MinisTheme.secondaryText)
                        Text("No Environment Variables")
                            .font(.system(size: fontSettings.scaledApp(17), weight: .semibold))
                        Text("Add API keys or tokens available in the shell.")
                            .font(.system(size: fontSettings.scaledApp(12)))
                            .foregroundStyle(MinisTheme.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            } else if filteredEntries.isEmpty {
                // [Batch 23] Variables exist, the search just matches none —
                // say so, instead of a blank list. The title is NOT the
                // true-empty "No Environment Variables": that would be a lie.
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(MinisTheme.secondaryText)
                        Text("No results")
                            .font(.system(size: fontSettings.scaledApp(17), weight: .semibold))
                        Text("Try a different search term.")
                            .font(.system(size: fontSettings.scaledApp(12)))
                            .foregroundStyle(MinisTheme.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            } else {
                ForEach(filteredEntries) { entry in
                    envVarRow(entry)
                }
                .onDelete(perform: deleteEntries)
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Filter by name")
        .navigationTitle("Environment Variables")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            EnvVarFormSheet(mode: .add, initialKey: prefillKey, initialValue: prefillValue, initialNote: prefillNote) { key, value, note in
                let ok = store.add(key: key, value: value, note: note)
                if ok { listError = nil }
                return ok
            }
            .onDisappear {
                prefillKey = ""
                prefillValue = ""
                prefillNote = ""
            }
        }
        .onAppear {
            handlePendingEnvVar()
        }
        // [Batch 23] A deep link arriving while the page is already open
        // used to do nothing — pending links were only handled in onAppear.
        // EnvVarCreate is not Equatable, so watch its key as the token;
        // the handler clears pending to nil, which separates repeat links.
        .onChange(of: deepLink.pendingEnvVarCreate?.key) { _ in
            handlePendingEnvVar()
        }
        .alert(
            AppLocalized("Replace existing value?"),
            isPresented: Binding(
                get: { overwriteConfirm != nil },
                set: { if !$0 { overwriteConfirm = nil } }
            ),
            presenting: overwriteConfirm
        ) { request in
            Button(AppLocalized("Replace"), role: .destructive) {
                listError = nil
                if !store.update(id: request.entryId, key: request.key, value: request.newValue) {
                    listError = store.lastSaveFailure?.message
                        ?? AppLocalized("Could not save this variable. Please try again.")
                }
            }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: { request in
            // [Batch 23] The prompt used to print the new secret in plaintext.
            // Show the row's masked bullets instead — same masking as the list.
            Text(AppLocalized("\"\(request.key)\" already has a value. Replace it with \"\(String(repeating: "\u{2022}", count: min(request.newValue.count, 20)))\"?"))
        }
        // [Batch 23] Copying also used to write the secret straight to the
        // pasteboard with no confirmation. Gate it behind the same alert
        // pattern: the alert shows the key + masked value, and only the
        // confirm button performs the write.
        .alert(
            AppLocalized("Copy"),
            isPresented: Binding(
                get: { copyConfirm != nil },
                set: { if !$0 { copyConfirm = nil } }
            ),
            presenting: copyConfirm
        ) { request in
            Button(AppLocalized("Copy")) {
                UIPasteboard.general.string = "\(request.key)=\(request.value)"
                withAnimation { copiedId = request.entryId }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { if copiedId == request.entryId { copiedId = nil } }
                }
            }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: { request in
            Text(AppLocalized("\"\(request.key)\" = \(String(repeating: "\u{2022}", count: min(request.value.count, 20)))"))
        }
        .sheet(item: $editingEntry) { entry in
            EnvVarFormSheet(
                mode: .edit,
                initialKey: entry.key,
                initialValue: store.value(forKey: entry.key) ?? "",
                initialNote: entry.note,
                editingEntryId: entry.id,
                onSave: { key, value, note in
                    let ok = store.update(id: entry.id, key: key, value: value, note: note)
                    if ok { listError = nil }
                    return ok
                },
                onDelete: {
                    let ok = store.delete(id: entry.id)
                    if ok { listError = nil }
                    return ok
                }
            )
        }
        .settingsPage()
    }

    // [Batch 23] The old onAppear body, extracted verbatim (plus the
    // failure capture): called on appear AND when a deep link arrives
    // while the page is already open. Branch logic untouched.
    private func handlePendingEnvVar() {
        guard let pending = deepLink.pendingEnvVarCreate else { return }
        let normalizedKey = pending.key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        deepLink.pendingEnvVarCreate = nil
        if let existing = store.entries.first(where: { $0.key == normalizedKey }) {
            let currentValue = store.value(forKey: existing.key) ?? ""
            if !currentValue.isEmpty && currentValue != pending.value {
                overwriteConfirm = OverwriteRequest(
                    entryId: existing.id,
                    key: existing.key,
                    newValue: pending.value
                )
            } else if currentValue.isEmpty {
                listError = nil
                if !store.update(id: existing.id, key: existing.key, value: pending.value) {
                    listError = store.lastSaveFailure?.message
                        ?? AppLocalized("Could not save this variable. Please try again.")
                }
            }
        } else {
            prefillKey = pending.key
            prefillValue = pending.value
            prefillNote = pending.note
            showingAddSheet = true
        }
    }

    @ViewBuilder
    private func envVarRow(_ entry: EnvVarEntry) -> some View {
        let isRevealed = revealedKeys.contains(entry.id)
        let currentValue = store.value(forKey: entry.key) ?? ""

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.key)
                    .font(.system(size: fontSettings.scaledApp(17), design: .monospaced))
                    .fontWeight(.medium)
                Text(isRevealed ? currentValue : String(repeating: "\u{2022}", count: min(currentValue.count, 20)))
                    .font(.system(size: fontSettings.scaledApp(12), design: .monospaced))
                    .foregroundStyle(MinisTheme.secondaryText)
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.system(size: fontSettings.scaledApp(12)))
                        .foregroundStyle(MinisTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    if isRevealed {
                        revealedKeys.remove(entry.id)
                    } else {
                        revealedKeys.insert(entry.id)
                    }
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 14))
                        .foregroundStyle(MinisTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRevealed ? AppLocalized("Hide value") : AppLocalized("Show value"))

                Button {
                    copyConfirm = CopyRequest(entryId: entry.id, key: entry.key, value: currentValue)
                } label: {
                    Image(systemName: copiedId == entry.id ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 13))
                        .foregroundStyle(copiedId == entry.id ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalized("Copy"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editingEntry = entry
        }
        .accessibilityAction(named: AppLocalized("Edit")) {
            editingEntry = entry
        }
    }

    private func deleteEntries(at offsets: IndexSet) {
        let entriesToDelete = offsets.map { filteredEntries[$0] }
        listError = nil
        for entry in entriesToDelete {
            if !store.delete(id: entry.id) {
                listError = store.lastSaveFailure?.message
                    ?? AppLocalized("Could not delete this variable. Please try again.")
            }
        }
    }
}

// MARK: - Form Sheet

private struct EnvVarFormSheet: View {
    @ObservedObject private var fontSettings = FontSettings.shared
    enum Mode { case add, edit }

    let mode: Mode
    var initialKey: String = ""
    var initialValue: String = ""
    var initialNote: String = ""
    // [Batch 24] The entry being edited, for the pre-save drift check.
    // Add mode leaves it nil (nothing to drift against).
    var editingEntryId: String? = nil
    /// [Batch 20 Fix 1] Returns whether the save actually persisted.
    /// The sheet dismisses only on true; on false it stays open and
    /// shows `EnvVarStore.shared.lastSaveFailure` inline.
    let onSave: (String, String, String) -> Bool
    var onDelete: (() -> Bool)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var value = ""
    @State private var note = ""
    @State private var saveError: String?
    @State private var showingDeleteConfirm = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case key, value, note }

    /// [Batch 24] Validate what the store will actually accept: the key
    /// after the store's own trim+uppercase, and a non-blank value.
    /// Pasting " FOO " used to fail validation although the store would
    /// have accepted it; an empty value used to save as a blank line.
    /// [Batch 25] isValid covers the value too, so the Name footer must
    /// NOT read isValid — it blamed the key when only the value was empty.
    /// The footer reads isKeyValid; the button still reads isValid.
    private var normalizedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private var isKeyValid: Bool {
        EnvVarStore.isValidKey(normalizedKey)
    }

    private var isValid: Bool {
        isKeyValid
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // [Batch 24] No live uppercase rewrite: rewriting the
                    // whole string per keystroke jumped the caret to the end
                    // and broke IME/composed input. Uppercase still happens
                    // twice over — .textInputAutocapitalization(.characters)
                    // below, and the store's trim+uppercase on save.
                    TextField("NAME", text: $key)
                    .font(.system(size: fontSettings.scaledApp(17), design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .key)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .value }
                } header: {
                    Text("Name")
                }

                Section("Value") {
                    TextField("Value", text: $value)
                        .font(.system(size: fontSettings.scaledApp(17), design: .monospaced))
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .value)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .note }
                }

                Section("Note") {
                    ZStack(alignment: .topLeading) {
                        if note.isEmpty {
                            Text("Describe what this variable is for (optional)")
                                .foregroundStyle(MinisTheme.secondaryText)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $note)
                            .frame(minHeight: 80)
                            .focused($focusedField, equals: .note)
                            .scrollContentBackground(.hidden)
                    }
                }

                // [Batch 20 Fix 1] A failed save stays visible here, with
                // the real reason — the typed values are untouched and the
                // sheet stays open so she can fix it and retry.
                if let saveError {
                    Section {
                        Text(saveError)
                            .foregroundStyle(MinisTheme.destructive)
                    }
                }

                if mode == .edit, onDelete != nil {
                    Section {
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label {
                                Text("Delete Variable")
                            } icon: {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white)
                                    .frame(width: 21, height: 21)
                                    .background(.red, in: Circle())
                            }
                        }
                    }
                }
            }
            .navigationTitle(mode == .add ? "Add Variable" : "Edit Variable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .add ? "Add" : "Save") {
                        saveError = nil
                        // [Batch 24] The sheet was seeded when it opened; if
                        // the entry changed elsewhere since, saving would
                        // silently overwrite the newer value (or note, or
                        // rename it back). Compare the CURRENT entry against
                        // the SEED values — never against the typed text, so
                        // a rename the user typed herself can't trip this.
                        // A deleted entry falls through to onSave, which
                        // fails with .entryMissing and shows its own reason.
                        if mode == .edit, let entryId = editingEntryId,
                           let current = EnvVarStore.shared.entry(id: entryId) {
                            let currentValue = EnvVarStore.shared.value(forKey: current.key) ?? ""
                            if current.key != initialKey || currentValue != initialValue || current.note != initialNote {
                                saveError = AppLocalized("This variable changed elsewhere. Close and reopen to edit the latest value.")
                                return
                            }
                        }
                        // [Batch 20 Fix 1] Dismiss ONLY on a persisted save.
                        // On failure the form stays open with the typed
                        // values intact and the real reason shown inline.
                        if onSave(key, value, note.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            dismiss()
                        } else {
                            saveError = EnvVarStore.shared.lastSaveFailure?.message
                                ?? AppLocalized("Could not save this variable. Please try again.")
                        }
                    }
                    .disabled(!isValid)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .alert(
            AppLocalized("Delete this variable?"),
            isPresented: $showingDeleteConfirm
        ) {
            Button(AppLocalized("Delete"), role: .destructive) {
                // [Batch 20 Fix 1] A failed delete keeps the sheet open
                // with the reason shown, instead of closing as if deleted.
                // Clear any earlier save error first so a failed delete
                // never shows a stale save reason.
                saveError = nil
                if onDelete?() ?? false {
                    dismiss()
                } else {
                    saveError = EnvVarStore.shared.lastSaveFailure?.message
                        ?? AppLocalized("Could not delete this variable. Please try again.")
                }
            }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        }
        .onAppear {
            key = initialKey
            value = initialValue
            note = initialNote
        }
        // Use .task instead of onAppear+DispatchQueue: the wait is cancellable
        // (sheet dismissed mid-animation cancels cleanly) and we can resign any
        // existing first responder in the parent view tree first — otherwise
        // the chat input / iSH terminal can keep firstResponder and iOS
        // suppresses the sheet's keyboard intermittently.
        .task {
            // Resign any first responder owned by the presenting view tree so
            // UIKit doesn't hand the keyboard back to it when the sheet's
            // TextField asks for focus.
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
            // Wait for the sheet's present/detent animation to settle before
            // requesting focus. 0.45s covers both .medium and .large detents
            // on slower devices; if the sheet is dismissed sooner, .task is
            // cancelled and focus is never set.
            // [Batch 24] try? used to swallow the CancellationError, so the
            // focus request still fired after dismissal (keyboard churn).
            // Catch it and stop; also check isCancelled before focusing.
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch {
                return
            }
            if Task.isCancelled { return }
            if mode == .add {
                focusedField = .key
            }
        }
    }
}
