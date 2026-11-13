import SwiftUI

/// The bookmark under a post or beside a reel. A click saves or unsaves, as before; resting on
/// it lists your collections, as instagram.com's does (saved or not): tick one to put the post
/// in it (saving it too), untick to take it out, or make a new one with the post in it.
struct SaveButton: View {
    let media: Media
    var size: CGFloat = 22
    @Environment(AppModel.self) private var app
    @State private var showList = false
    @State private var overButton = false
    @State private var overList = false
    /// Typing a new collection's name: the list stays open.
    @State private var naming = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        if let actions = app.actions {
            let saved = actions.state(media).saved
            Button { actions.toggleSave(media) } label: {
                IGGlyph(icon: saved ? .saveFilled : .save, size: size).contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .onHover { overButton = $0; followPointer() }
            .popover(isPresented: $showList, arrowEdge: .bottom) {
                CollectionList(media: media, actions: actions, naming: $naming)
                    .onHover { overList = $0; followPointer() }
            }
            .onChange(of: showList) { if !showList { naming = false } }
        }
    }

    /// Opens after a short rest on the button; closes a moment after the pointer leaves both
    /// the button and the list (not while a name is being typed).
    private func followPointer() {
        hoverTask?.cancel()
        if overButton || overList {
            guard !showList, overButton else { return }
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, overButton else { return }
                app.actions?.loadCollections()
                showList = true
            }
        } else if showList {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, !overButton, !overList, !naming else { return }
                showList = false
            }
        }
    }
}

private struct CollectionList: View {
    let media: Media
    let actions: PostActions
    @Binding var naming: Bool
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        let state = actions.state(media)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Save to collection").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if state.saved {
                    Text("Saved").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            if let list = actions.collections {
                if list.isEmpty {
                    Text("No collections yet")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.bottom, 10)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(list) { c in
                                CollectionRow(collection: c, checked: state.collections.contains(c.id)) {
                                    actions.toggleCollection(c.id, media: media)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    .scrollIndicators(.never)
                    .frame(height: min(CGFloat(list.count) * 46, 322))
                }
            } else {
                Spinner(size: 16).frame(maxWidth: .infinity).padding(.vertical, 18)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.top, 6)
            if naming {
                HStack(spacing: 8) {
                    TextField("Collection name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .onSubmit(create)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.placeholder))
                    Button("Create", action: create)
                        .buttonStyle(.prominentCompact)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(10)
                .onAppear { focused = true }
                .onExitCommand { naming = false; name = "" }
            } else {
                NewCollectionRow { naming = true }
                    .padding(6)
            }
        }
        .frame(width: 270)
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        actions.createCollection(named: name, with: media)
        name = ""
        naming = false
    }
}

private struct CollectionRow: View {
    let collection: SavedCollection
    let checked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RemoteImage(url: collection.cover)
                    .frame(width: 34, height: 34)
                    .background(Theme.placeholder)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(collection.name)
                    .font(.system(size: 13, weight: checked ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 6)
                ZStack {
                    Circle().strokeBorder(Color.primary.opacity(checked ? 0 : 0.3), lineWidth: 1.5)
                    if checked {
                        Circle().fill(Theme.link)
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 20, height: 20)
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: checked)
    }
}

private struct NewCollectionRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.placeholder))
                Text("New collection").font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
