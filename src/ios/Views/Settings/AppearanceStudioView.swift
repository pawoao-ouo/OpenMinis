import PhotosUI
import SwiftUI

struct AppearanceStudioView: View {
    @ObservedObject private var studio = AppearanceStudio.shared
    @State private var variant: AppearanceVariant = .light
    @State private var wallpaperScope: AppearanceScope = .global
    @State private var wallpaperItem: PhotosPickerItem?
    @State private var userAvatarItem: PhotosPickerItem?
    @State private var assistantAvatarItem: PhotosPickerItem?
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                themePreview
            } header: {
                Text("Your Look")
            } footer: {
                Text("A warm, quiet palette is used by default. Every color below can be replaced without changing the layout.")
            }

            Section {
                Picker("Palette", selection: $variant) {
                    ForEach(AppearanceVariant.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                ForEach(AppearanceColorRole.allCases) { role in
                    HStack(spacing: 12) {
                        ColorPicker(role.title,
                                    selection: studio.colorBinding(role,
                                                                   scope: .global,
                                                                   variant: variant),
                                    supportsOpacity: false)
                        Text("#\(studio.hex(role, scope: .global, variant: variant))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(studio.color(.secondaryText, scope: .global,
                                                          variant: variant))
                    }
                }
            } header: {
                Text("Color Palette")
            } footer: {
                Text("These colors flow through every page, card, label, bubble and input field. Light and dark variants switch automatically with system appearance.")
            }

            Section {
                HStack(spacing: 10) {
                    ForEach(AppearancePreset.allCases) { preset in
                        Button(preset.title) { studio.applyPreset(preset) }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Restore Default Palette", role: .destructive) {
                    studio.resetColors()
                }
            } header: {
                Text("Presets")
            }

            Section {
                Picker("Wallpaper For", selection: $wallpaperScope) {
                    ForEach(AppearanceScope.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }

                ZStack(alignment: .bottomTrailing) {
                    AppearanceBackdrop(scope: wallpaperScope)
                    Text(studio.hasWallpaper(wallpaperScope) ? "Wallpaper preview" : "Color background")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(studio.color(.primaryText, scope: wallpaperScope))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(studio.color(.raised, scope: wallpaperScope).opacity(0.88),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .padding(10)
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(studio.color(.border, scope: wallpaperScope), lineWidth: 0.8)
                )

                PhotosPicker(selection: $wallpaperItem, matching: .images) {
                    Label(studio.hasOwnWallpaper(wallpaperScope) ? "Replace This Wallpaper" : "Choose Wallpaper",
                          systemImage: "photo")
                }

                if studio.hasOwnWallpaper(wallpaperScope) {
                    Button("Use Inherited Background", role: .destructive) {
                        studio.removeWallpaper(wallpaperScope)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Wallpaper Tint")
                        Spacer()
                        Text("\(Int(studio.wallpaperShade * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $studio.wallpaperShade, in: 0...0.65, step: 0.01)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Card Opacity")
                        Spacer()
                        Text("\(Int(studio.surfaceOpacity * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $studio.surfaceOpacity, in: 0.35...1, step: 0.01)
                }
            } header: {
                Text("Page Backgrounds")
            } footer: {
                Text("Set one image for all pages, then replace it only where you want. Tint protects text contrast; card opacity decides how much of the picture shows through.")
            }

            Section {
                pairedAvatarPreview

                PhotosPicker(selection: $userAvatarItem, matching: .images) {
                    Label("Choose My Avatar", systemImage: "person.crop.square")
                }
                if !studio.userAvatar.isEmpty {
                    Button("Remove My Avatar", role: .destructive) {
                        studio.removeUserAvatar()
                    }
                }

                PhotosPicker(selection: $assistantAvatarItem, matching: .images) {
                    Label("Choose Assistant Avatar", systemImage: "sparkles.rectangle.stack")
                }
                if !SoulStore.cachedMetadata.icon.isEmpty {
                    Button("Remove Assistant Avatar", role: .destructive) {
                        do { try studio.removeAssistantAvatar() }
                        catch { errorText = error.localizedDescription }
                    }
                }
            } header: {
                Text("Paired Avatars")
            } footer: {
                Text("Both images are square-cropped and stored on this device. The assistant image also becomes the Soul icon, so every identity surface stays consistent.")
            }
        }
        .appearancePage(.settings)
        .navigationTitle("Decorate")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: wallpaperItem) { item in
            guard let item else { return }
            Task { await importImage(item) { studio.setWallpaper($0, for: wallpaperScope) } }
        }
        .onChange(of: userAvatarItem) { item in
            guard let item else { return }
            Task { await importImage(item) { studio.setUserAvatar($0) } }
        }
        .onChange(of: assistantAvatarItem) { item in
            guard let item else { return }
            Task {
                await importImage(item) { image in
                    do { try studio.setAssistantAvatar(image) }
                    catch { errorText = error.localizedDescription }
                }
            }
        }
        .alert("Image Could Not Be Used", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private var themePreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("A room you can make yours")
                        .font(.headline)
                    Text("Quiet by default. Fully editable when you want it.")
                        .font(.caption)
                        .foregroundStyle(studio.color(.secondaryText, variant: variant))
                }
                Spacer()
                Circle()
                    .fill(studio.color(.accent, variant: variant))
                    .frame(width: 18, height: 18)
            }
            HStack(spacing: 8) {
                previewSwatch(.surface)
                previewSwatch(.mutedSurface)
                previewSwatch(.userBubble)
                previewSwatch(.assistantBubble)
                previewSwatch(.input)
            }
        }
        .padding(18)
        .foregroundStyle(studio.color(.primaryText, variant: variant))
        .background(studio.color(.surface, variant: variant),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(studio.color(.border, variant: variant), lineWidth: 0.8)
        )
        .listRowBackground(Color.clear)
    }

    private func previewSwatch(_ role: AppearanceColorRole) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(studio.color(role, variant: variant))
            .frame(height: 28)
    }

    private var pairedAvatarPreview: some View {
        HStack(spacing: 12) {
            Spacer()
            VStack(spacing: 6) {
                PersonAvatarView(kind: .assistant, size: 54)
                Text(SoulStore.cachedMetadata.name.isEmpty ? "Assistant" : SoulStore.cachedMetadata.name)
                    .font(.caption)
            }
            Image(systemName: "link")
                .foregroundStyle(studio.color(.accent))
            VStack(spacing: 6) {
                PersonAvatarView(kind: .user, size: 54)
                Text("Me").font(.caption)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    @MainActor
    private func importImage(_ item: PhotosPickerItem,
                             apply: @escaping @MainActor (UIImage) -> Void) async {
        defer {
            wallpaperItem = nil
            userAvatarItem = nil
            assistantAvatarItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            errorText = "The selected image could not be read."
            return
        }
        apply(image)
    }
}
