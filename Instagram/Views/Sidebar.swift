import SwiftUI

/// Velvet's and Twitter's sidebar layout: a floating panel inset from the window edge.
enum SidebarMetrics {
    /// Column widths, the panel's inset from the window edge included.
    static let fullWidth: CGFloat = 232
    static let railWidth: CGFloat = 88
    static let inset: CGFloat = 8
    /// Room at the top of the panel for the window's close/minimize/zoom buttons.
    static let windowButtons: CGFloat = 44
    static let cornerRadius: CGFloat = 16
}

/// The destinations, Create and your account in a floating panel, as in Velvet and Twitter
/// (Instagram's own icons). Collapsed (⌘S, or the button in the top bar), it becomes a narrow
/// rail of icons with short labels.
struct Sidebar: View {
    @Environment(AppModel.self) private var app
    @Namespace private var selection

    var body: some View {
        let collapsed = app.isSidebarCollapsed
        VStack(spacing: 2) {
            Color.clear.frame(height: SidebarMetrics.windowButtons)
            ForEach(app.destinations) { d in
                item(icon: app.destination == d ? d.glyph.filled : d.glyph.outline, title: d.title,
                     badge: d == .messages ? app.inbox?.unreadCount ?? 0 : 0,
                     selected: app.destination == d, collapsed: collapsed,
                     help: "\(d.title) (⌘\(String(d.shortcut.character)))") { app.destination = d }
                    .keyboardShortcut(d.shortcut)
            }
            if collapsed {
                Rectangle().fill(Theme.hairline).frame(width: 32, height: 1).padding(.vertical, 6)
            } else {
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 8)
            }
            // Create: instagram.com's "+", which opens Post, Reel, Story (filled while open).
            let creating = app.creating != nil || app.showCreateMenu
            item(icon: creating ? .newPostFilled : .newPost, title: "Create", selected: false, highlighted: creating,
                 collapsed: collapsed, help: "Create (⌘N)") {
                if app.storyEditor == nil { app.showCreateMenu.toggle() }
            }
            .keyboardShortcut("n")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { app.createItemFrame = $0 }
            Spacer(minLength: 0)
            SettingsItem(collapsed: collapsed)
            AccountCard(collapsed: collapsed)
        }
        .padding(collapsed ? 8 : 10)
        .frame(width: (collapsed ? SidebarMetrics.railWidth : SidebarMetrics.fullWidth) - SidebarMetrics.inset)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SidebarPanel())
        .clipShape(RoundedRectangle(cornerRadius: SidebarMetrics.cornerRadius, style: .continuous))
        .padding([.leading, .vertical], SidebarMetrics.inset)
        .animation(.smooth(duration: 0.28), value: app.destination)
        .animation(.smooth(duration: 0.25), value: app.inbox?.unreadCount)
    }

    @ViewBuilder
    private func item(icon: IGIcon, title: String, badge: Int = 0, selected: Bool, highlighted: Bool = false,
                      collapsed: Bool, help: String, action: @escaping () -> Void) -> some View {
        if collapsed {
            RailItem(icon: icon, title: title, badge: badge, isSelected: selected, highlighted: highlighted,
                     selection: selection, action: action)
                .help(help)
        } else {
            SidebarRow(icon: icon, title: title, badge: badge, isSelected: selected, highlighted: highlighted,
                       selection: selection, action: action)
                .help(help)
        }
    }
}

struct SidebarPanel: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SidebarMetrics.cornerRadius, style: .continuous)
        shape.fill(Theme.panel).overlay(shape.strokeBorder(Theme.panelStroke))
    }
}

private struct SidebarRow: View {
    let icon: IGIcon
    let title: String
    var badge = 0
    let isSelected: Bool
    var highlighted = false
    let selection: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IGGlyph(icon: icon, size: 20)
                    .foregroundStyle(isSelected || highlighted ? .primary : .secondary)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary.opacity(isSelected ? 1 : 0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if badge > 0 { CountBadge(count: badge) }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.selected)
                        .matchedGeometryEffect(id: "selection", in: selection)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.hover)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct RailItem: View {
    let icon: IGIcon
    let title: String
    var badge = 0
    let isSelected: Bool
    var highlighted = false
    let selection: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                IGGlyph(icon: icon, size: 20)
                    .frame(height: 22)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 { CountBadge(count: badge).scaleEffect(0.85).offset(x: 12, y: -8) }
                    }
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected || highlighted ? .primary : .secondary)
            .frame(width: 64, height: 54)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.selected)
                        .matchedGeometryEffect(id: "selection", in: selection)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.hover)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Unread chats on Messages.
private struct CountBadge: View {
    let count: Int
    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 10.5, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(Theme.like))
            .transition(.scale.combined(with: .opacity))
    }
}

/// You: click for your profile; the menu (… or right-click) switches accounts and signs out.
private struct AccountCard: View {
    let collapsed: Bool
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    private var onMine: Bool {
        guard let me = app.me else { return false }
        return app.profiles.last?.id == me.id
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let me = app.me {
                    Avatar(url: me.avatar, size: 32)
                        .padding(2)
                        .overlay(Circle().strokeBorder(onMine ? Color.primary : .clear, lineWidth: 1.5))
                } else {
                    Image(systemName: "person.crop.circle").font(.system(size: 22)).foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                }
            }
            if !collapsed, let me = app.me {
                VStack(alignment: .leading, spacing: 1) {
                    Text(me.fullName.isEmpty ? me.username : me.fullName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("@" + me.username)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu { menuItems } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Accounts and settings")
            }
        }
        .padding(collapsed ? 6 : 8)
        .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture { if let me = app.me { app.openProfile(me) } }
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
        .help("Your profile (right-click to switch accounts)")
    }

    @ViewBuilder
    private var menuItems: some View {
        ForEach(app.accounts) { account in
            let current = account.id == app.accountId
            Button { app.switchAccount(to: account.id) } label: {
                if current { Label(account.handle, systemImage: "checkmark") } else { Text(account.handle) }
            }
            .disabled(current || app.switchingAccount)
        }
        Button("Add Account…") { app.addAccount() }
        Divider()
        Button("Settings…") { app.showSettings = true }
        Divider()
        Button(app.me.map { "Sign Out of @\($0.username)" } ?? "Sign Out") { app.signOut() }
    }
}

/// Settings (⌘,), just above your account.
private struct SettingsItem: View {
    let collapsed: Bool
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        Button { app.showSettings = true } label: {
            Group {
                if collapsed {
                    VStack(spacing: 4) {
                        Image(systemName: "gearshape").font(.system(size: 18, weight: .regular)).frame(height: 22)
                        Text("Settings").font(.system(size: 10, weight: .medium)).lineLimit(1)
                    }
                    .frame(width: 64, height: 54)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "gearshape").font(.system(size: 17, weight: .regular)).frame(width: 24)
                        Text("Settings").font(.system(size: 14)).foregroundStyle(.primary.opacity(0.85))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 38)
                }
            }
            .foregroundStyle(app.showSettings ? .primary : .secondary)
            .background(RoundedRectangle(cornerRadius: collapsed ? 12 : 10, style: .continuous)
                .fill(app.showSettings ? Theme.selected : hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Settings (⌘,)")
    }
}
