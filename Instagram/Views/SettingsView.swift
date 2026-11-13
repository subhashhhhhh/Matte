import SwiftUI
import AppKit

/// Settings (⌘,): a card with the sections down the side (as Velvet's settings) and the
/// chosen section's options beside them. Everything takes effect at once and is remembered
/// (`Preferences`). The manager tools follow the account type: they show for a professional
/// account, so there's no switch for them.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var section: Section
    @Namespace private var selection
    /// Renders (no scroll view: ImageRenderer draws scroll views empty).
    var rendering = false

    init(section: Section = .general, rendering: Bool = false) {
        _section = State(initialValue: section)
        self.rendering = rendering
    }

    enum Section: String, CaseIterable, Identifiable {
        case general, feed, playback, notifications, ghost, downloads, storage, accounts, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .feed: "Feed"
            case .playback: "Playback"
            case .notifications: "Notifications"
            case .ghost: "Ghost Mode"
            case .downloads: "Downloads"
            case .storage: "Storage"
            case .accounts: "Accounts"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .feed: "square.grid.2x2"
            case .playback: "play.circle"
            case .notifications: "bell"
            case .ghost: "eye.slash"
            case .downloads: "arrow.down.circle"
            case .storage: "internaldrive"
            case .accounts: "person.2"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        DialogCard(width: 780, height: 560, close: close) {
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(Theme.hairline).frame(width: 1)
                VStack(spacing: 0) {
                    HStack {
                        Text(section.title).font(.system(size: 17, weight: .semibold))
                        Spacer()
                        ChromeButton("Close", symbol: "xmark", action: close)
                    }
                    .padding(.horizontal, 24)
                    .frame(height: 56)
                    if rendering {
                        VStack(alignment: .leading, spacing: 0) { page }
                            .padding(.horizontal, 24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) { page }
                                .padding(.horizontal, 24)
                                .padding(.bottom, 24)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .scrollIndicators(.never)
                        .id(section)
                    }
                }
            }
        }
        .background {
            Button("") { close() }.keyboardShortcut(.cancelAction).opacity(0)
        }
        #if DEBUG
        // `-IGSettingsSection ghost` opens Settings on that section (screenshots).
        .onAppear {
            if let s = UserDefaults.standard.string(forKey: "IGSettingsSection").flatMap(Section.init(rawValue:)) { section = s }
        }
        #endif
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 20)
                .padding(.bottom, 8)
            ForEach(Section.allCases) { s in
                Button { withAnimation(.smooth(duration: 0.2)) { section = s } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: s.symbol).font(.system(size: 13, weight: .medium)).frame(width: 18)
                        Text(s.title).font(.system(size: 13.5, weight: section == s ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(section == s ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background {
                        if section == s {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.selected)
                                .matchedGeometryEffect(id: "section", in: selection)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: 200)
        .background(Theme.panel)
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .general: GeneralPage()
        case .feed: FeedPage()
        case .playback: PlaybackPage()
        case .notifications: NotificationsPage()
        case .ghost: GhostPage()
        case .downloads: DownloadsPage()
        case .storage: StoragePage()
        case .accounts: AccountsPage()
        case .about: AboutPage()
        }
    }

    private func close() { app.showSettings = false }
}

// MARK: - Building blocks

/// A group of rows on a panel, with an optional heading and a note under it.
private struct SettingsGroup<Content: View>: View {
    var title: String?
    var note: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.panelStroke))
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.bottom, 18)
    }
}

/// One row: a title, an optional explanation, and its control on the right.
private struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    var divider = true
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .top) {
            if divider { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 14) }
        }
    }
}

/// Matte's own switch: a soft capsule that fills with the link colour when on.
struct MatteSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { withAnimation(.snappy(duration: 0.18)) { isOn.toggle() } } label: {
            Capsule()
                .fill(isOn ? Theme.link : Color.primary.opacity(0.16))
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                        .padding(2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A row of choices as segments (Appearance, where downloads go).
private struct Segments<T: Hashable & Identifiable>: View {
    let options: [T]
    let title: (T) -> String
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button { withAnimation(.snappy(duration: 0.15)) { selection = option } } label: {
                    Text(title(option))
                        .font(.system(size: 12.5, weight: selection == option ? .semibold : .regular))
                        .foregroundStyle(selection == option ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if selection == option {
                                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.background)
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

/// A short list of choices that drops down (custom: no stock pop-up button).
private struct Choice<T: Hashable & Identifiable>: View {
    let options: [T]
    let title: (T) -> String
    @Binding var selection: T

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button { selection = option } label: {
                    if option == selection { Label(title(option), systemImage: "checkmark") } else { Text(title(option)) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title(selection)).font(.system(size: 12.5, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Pages

private struct GeneralPage: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        SettingsGroup {
            SettingRow(title: "Appearance", detail: "Light, dark, or follow your Mac.", divider: false) {
                Segments(options: Preferences.Appearance.allCases, title: \.title, selection: $prefs.appearance)
            }
            SettingRow(title: "Open on", detail: "The page Matte shows when it starts.") {
                Choice(options: Preferences.StartPage.allCases, title: \.title, selection: $prefs.startPage)
            }
        }
    }
}

private struct FeedPage: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        SettingsGroup {
            SettingRow(title: "Home feed", detail: "Which feed opens first: For you, Following or Favorites.", divider: false) {
                Choice(options: Preferences.StartFeed.allCases, title: \.title, selection: $prefs.startFeed)
            }
            SettingRow(title: "Hide suggested posts", detail: "Leave out the posts Instagram mixes into For you from accounts you don't follow.") {
                MatteSwitch(isOn: $prefs.hideSuggested)
            }
        }
    }
}

private struct PlaybackPage: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        SettingsGroup {
            SettingRow(title: "Start muted", detail: "Videos and songs start without sound. The sound button still turns it on.", divider: false) {
                MatteSwitch(isOn: $prefs.startMuted)
            }
            SettingRow(title: "Play on hover", detail: "Resting on a post in your feed plays its video or song.") {
                MatteSwitch(isOn: $prefs.hoverPreviews)
            }
            SettingRow(title: "Mini player", detail: "A post or reel you leave keeps playing in the corner.") {
                MatteSwitch(isOn: $prefs.miniPlayer)
            }
        }
    }
}

private struct NotificationsPage: View {
    @Environment(AppModel.self) private var app
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        SettingsGroup(title: "Messages") {
            SettingRow(title: "New message notifications", divider: false) {
                MatteSwitch(isOn: $prefs.notifications)
            }
            SettingRow(title: "Show the message", detail: "Off: notifications only say who it's from.") {
                MatteSwitch(isOn: $prefs.notificationPreviews).disabled(!prefs.notifications).opacity(prefs.notifications ? 1 : 0.4)
            }
            SettingRow(title: "Sound") {
                MatteSwitch(isOn: $prefs.notificationSound).disabled(!prefs.notifications).opacity(prefs.notifications ? 1 : 0.4)
            }
        }
        SettingsGroup(title: "Dock") {
            SettingRow(title: "Unread count on the Dock icon", divider: false) {
                MatteSwitch(isOn: $prefs.dockBadge)
            }
        }
        .onChange(of: prefs.dockBadge) { DMNotifier.setBadge(app.inbox?.unreadCount ?? 0) }
    }
}

private struct GhostPage: View {
    @Bindable private var prefs = Preferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.panel))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Look around without leaving a trace.").font(.system(size: 14, weight: .semibold))
                    Text("Matte simply doesn't send these signals. People can still see your likes, replies and messages.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 18)
            SettingsGroup {
                SettingRow(title: "Ghost mode", detail: "All of the below at once.", divider: false) {
                    MatteSwitch(isOn: $prefs.ghostMode)
                }
            }
            SettingsGroup(note: "If you never show as having seen anything, people may notice, as they would on Instagram.") {
                SettingRow(title: "Watch stories unseen", detail: "Stories you watch aren't marked as seen.", divider: false) {
                    MatteSwitch(isOn: $prefs.ghostStories)
                }
                SettingRow(title: "Read messages without \"Seen\"", detail: "Opening a chat doesn't tell them you've read it.") {
                    MatteSwitch(isOn: $prefs.ghostReadReceipts)
                }
                SettingRow(title: "Hide \"typing…\"", detail: "They won't see you typing.") {
                    MatteSwitch(isOn: $prefs.ghostTyping)
                }
            }
        }
    }
}

private struct DownloadsPage: View {
    @Bindable private var prefs = Preferences.shared

    private var places: [Preferences.DownloadPlace] { Preferences.DownloadPlace.allCases }

    var body: some View {
        SettingsGroup(note: "Downloads are the full-size photos and videos from a post's or story's menu.") {
            SettingRow(title: "Save downloads to", divider: false) {
                Segments(options: places, title: { p in
                    switch p {
                    case .downloads: "Downloads"
                    case .ask: "Ask each time"
                    case .folder: "A folder…"
                    }
                }, selection: Binding(get: { prefs.downloadPlace }, set: { choose($0) }))
            }
            if prefs.downloadPlace == .folder, let folder = prefs.downloadFolder {
                SettingRow(title: (folder as NSString).abbreviatingWithTildeInPath) {
                    Button("Change…") { pickFolder() }.buttonStyle(.secondaryPill)
                }
            }
        }
    }

    private func choose(_ place: Preferences.DownloadPlace) {
        if place == .folder, prefs.downloadFolder == nil || prefs.downloadPlace == .folder {
            pickFolder()
        } else {
            prefs.downloadPlace = place
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = prefs.downloadDirectory
        if panel.runModal() == .OK, let url = panel.url {
            prefs.downloadFolder = url.path
            prefs.downloadPlace = .folder
        }
    }
}

private struct StoragePage: View {
    @State private var memory: UInt64 = 0
    @State private var images: Int64?
    @State private var data: Int64?

    var body: some View {
        SettingsGroup(title: "Memory", note: "instagram.com in a browser often takes 4–5 GB.") {
            SettingRow(title: "Matte is using", divider: false) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory))
                    .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
            }
        }
        SettingsGroup(title: "Cache", note: "Pictures and pages are kept on disk so Matte opens quickly. Clearing them is safe: they download again when needed.") {
            SettingRow(title: "Pictures", detail: images.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…", divider: false) {
                Button("Clear") {
                    Task {
                        await ImagePipeline.shared.clearAll()
                        await measure()
                    }
                }
                .buttonStyle(.secondaryPill)
            }
            SettingRow(title: "Feeds and chats", detail: data.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…") {
                Button("Clear") {
                    ResponseCache.clearAll()
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        await measure()
                    }
                }
                .buttonStyle(.secondaryPill)
            }
        }
        .task {
            while !Task.isCancelled {
                await measure()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func measure() async {
        memory = Self.footprint()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "com.subhash.Instagram")
        let (i, d) = await Task.detached(priority: .utility) {
            (Self.size(of: caches.appending(path: "img")), Self.size(of: caches.appending(path: "data")))
        }.value
        images = i
        data = d
    }

    /// What Activity Monitor shows as Matte's memory (its physical footprint).
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private nonisolated static func size(of dir: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

private struct AccountsPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SettingsGroup(note: "Each account stays signed in on this Mac. Right-click your picture in the sidebar to switch quickly.") {
            VStack(spacing: 2) {
                ForEach(app.accounts) { account in AccountRow(account: account) }
                AddAccountRow()
            }
            .padding(4)
        }
    }
}

private struct AboutPage: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(v) (\(b))"
    }

    private let shortcuts: [(String, String)] = [
        ("⌘1 – ⌘4", "Home, Explore, Reels, Messages"),
        ("⌘N", "Create a post, reel or story"),
        ("⌘F", "Search"),
        ("⌘K", "Jump to a chat or person"),
        ("⌘S", "Show or hide the sidebar"),
        ("⌘[", "Back"),
        ("⇧⌘S", "Show or hide a chat's shared media"),
        ("⌘,", "Settings"),
    ]

    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text("Matte").font(.custom("SnellRoundhand-Black", size: 30))
                Text(version).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 20)
        SettingsGroup(title: "Keyboard shortcuts") {
            ForEach(Array(shortcuts.enumerated()), id: \.offset) { i, s in
                SettingRow(title: s.1, divider: i > 0) {
                    Text(s.0).font(.system(size: 12.5, weight: .medium).monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Accounts rows

private struct AccountRow: View {
    @Environment(AppModel.self) private var app
    let account: AccountSummary
    @State private var hovering = false
    @State private var confirming = false

    private var isCurrent: Bool { account.id == app.accountId }

    var body: some View {
        HStack(spacing: 12) {
            Avatar(url: isCurrent ? (app.me?.avatar ?? account.avatar) : account.avatar, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.username.isEmpty ? account.handle : account.username)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                // "Professional" says why this account has the Planner and Replies.
                let detail = [account.fullName, account.professional == true ? "Professional" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if confirming {
                Button("Cancel") { confirming = false }.buttonStyle(.secondaryPill)
                Button { confirming = false; app.removeAccount(account.id) } label: {
                    Text("Sign Out")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Capsule().fill(Theme.like))
                }
                .buttonStyle(.pressable)
            } else {
                if hovering {
                    Button("Sign Out") { confirming = true }
                        .buttonStyle(.secondaryPill)
                        .transition(.opacity)
                }
                if isCurrent {
                    Text("Current")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Capsule().fill(Theme.selected))
                } else if app.switchingAccount {
                    Spinner(size: 14).frame(width: 60)
                } else {
                    Button("Switch") { app.switchAccount(to: account.id) }
                        .buttonStyle(.prominentCompact)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 54)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: confirming)
    }
}

private struct AddAccountRow: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        Button { app.addAccount() } label: {
            HStack(spacing: 12) {
                Circle().fill(Theme.background)
                    .overlay(Image(systemName: "plus").font(.system(size: 14, weight: .semibold)))
                    .frame(width: 36, height: 36)
                Text("Add Account").font(.system(size: 14, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
    }
}
