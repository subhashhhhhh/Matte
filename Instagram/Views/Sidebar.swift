import SwiftUI

/// A narrow rail of destinations: Home, Reels, Messages.
struct Sidebar: View {
    @Environment(AppModel.self) private var app
    @Namespace private var selection

    var body: some View {
        VStack(spacing: 6) {
            Color.clear.frame(height: 44)
            ForEach(Destination.allCases) { d in
                let selected = app.destination == d
                Button { app.destination = d } label: {
                    ZStack(alignment: .topTrailing) {
                        IGGlyph(icon: selected ? d.glyph.filled : d.glyph.outline, size: 22)
                            .frame(width: 48, height: 44)
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.selected)
                                        .matchedGeometryEffect(id: "sel", in: selection)
                                }
                            }
                        if d == .messages, let n = app.inbox?.unreadCount, n > 0 {
                            Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                                .background(Capsule().fill(Theme.like))
                                .offset(x: 2, y: 2)
                        }
                    }
                    .foregroundStyle(selected ? .primary : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .help("\(d.title) (⌘\(String(d.shortcut.character)))")
                .keyboardShortcut(d.shortcut)
            }
            Spacer()
            // You: opens your profile; right-click to sign out.
            Button {
                if let me = app.me { app.openProfile(me) }
            } label: {
                Group {
                    if let me = app.me {
                        let onMine = app.profiles.last?.id == me.id
                        Avatar(url: me.avatar, size: 30)
                            .padding(3)
                            .overlay(Circle().strokeBorder(onMine ? Color.primary : .clear, lineWidth: 2))
                    } else {
                        Image(systemName: "person.crop.circle").font(.system(size: 22)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help("Your profile")
            .contextMenu { Button("Sign Out") { app.signOut() } }
            .padding(.bottom, 12)
        }
        .frame(width: 72)
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
        .animation(Motion.slide, value: app.destination)
    }
}
