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
                        Image(systemName: selected ? d.symbol + ".fill" : d.symbol)
                            .font(.system(size: 19, weight: selected ? .semibold : .regular))
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
            Menu {
                Button("Sign Out") { app.signOut() }
            } label: {
                Image(systemName: "person.crop.circle").font(.system(size: 19))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 48, height: 44)
            .padding(.bottom, 12)
        }
        .frame(width: 72)
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
        .animation(.smooth(duration: 0.25), value: app.destination)
    }
}
