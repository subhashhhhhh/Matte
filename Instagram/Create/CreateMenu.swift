import SwiftUI

/// The sidebar "+" (⌘N): a small card beside it with Post, Reel and Story, as Instagram's
/// create menu. P, R and S pick one; Esc or a click elsewhere closes it.
struct CreateMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.opacity(0.001).ignoresSafeArea()
                .onTapGesture { app.showCreateMenu = false }
            VStack(alignment: .leading, spacing: 2) {
                CreateMenuRow(title: "Post", detail: "Photos on your profile", key: "p") { MenuGlyph.post } action: {
                    app.openCreate(target: .post)
                }
                CreateMenuRow(title: "Reel", detail: "A video in Reels", key: "r") { MenuGlyph.reel } action: {
                    app.openCreate(target: .reel)
                }
                CreateMenuRow(title: "Story", detail: "Edit and share for 24 hours", key: "s") { MenuGlyph.story } action: {
                    app.openStoryEditor()
                }
            }
            .padding(6)
            .frame(width: 250)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.panelStroke))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
            .popIn(from: 0.9)
            .padding(.leading, 72 + 6)
            .padding(.bottom, 66)
        }
        .background {
            Button("") { app.showCreateMenu = false }.keyboardShortcut(.cancelAction).opacity(0)
        }
    }
}

private enum MenuGlyph {
    static var post: some View { IGGlyph(icon: .newPost, size: 20) }
    static var reel: some View { IGGlyph(icon: .reels, size: 20) }
    static var story: some View {
        Circle().strokeBorder(Theme.storyGradient, lineWidth: 2)
            .overlay(Image(systemName: "plus").font(.system(size: 9, weight: .bold)))
            .frame(width: 20, height: 20)
    }
}

private struct CreateMenuRow<Icon: View>: View {
    let title: String
    let detail: String
    let key: KeyEquivalent
    @ViewBuilder let icon: Icon
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon.frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(String(key.character).uppercased())
                    .font(.system(size: 11, weight: .medium).monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .keyboardShortcut(key, modifiers: [])
        .onHover { hovering = $0 }
    }
}

/// A single video dropped on the window: a reel or a story?
struct DropChooser: View {
    let urls: [URL]
    @Environment(AppModel.self) private var app

    var body: some View {
        DialogCard(width: 340, close: { app.droppedFiles = nil }) {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text("Share this video as…").font(.system(size: 16, weight: .bold))
                    Text(urls.first?.lastPathComponent ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 22)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                choice("Reel", detail: "Up to 20 minutes, in Reels", key: "r") { MenuGlyph.reel } action: {
                    app.droppedFiles = nil
                    app.openCreate(urls, target: .reel)
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                choice("Story", detail: "Edit it; up to a minute is kept", key: "s") { MenuGlyph.story } action: {
                    app.droppedFiles = nil
                    app.openStoryEditor(urls.first)
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Button { app.droppedFiles = nil } label: {
                    Text("Cancel").font(.system(size: 14)).frame(maxWidth: .infinity).frame(height: 46).contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func choice<I: View>(_ title: String, detail: String, key: KeyEquivalent, @ViewBuilder icon: () -> I,
                                 action: @escaping () -> Void) -> some View {
        CreateMenuRow(title: title, detail: detail, key: key, icon: icon, action: action).padding(6)
    }
}
