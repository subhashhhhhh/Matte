import SwiftUI

/// Settings (⌘,): the accounts signed in on this Mac. (The manager tools follow the account
/// type: they show for a professional account.)
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        DialogCard(width: 520, close: close) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Settings").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    ChromeButton("Close", symbol: "xmark", action: close)
                }
                .padding(.horizontal, 20)
                .frame(height: 56)
                Rectangle().fill(Theme.hairline).frame(height: 1)

                VStack(alignment: .leading, spacing: 22) {
                    section("Accounts") {
                        VStack(spacing: 2) {
                            ForEach(app.accounts) { account in
                                AccountRow(account: account)
                            }
                            AddAccountRow()
                        }
                        Text("Each account stays signed in on this Mac. Right-click your picture in the sidebar to switch.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                    }
                }
                .padding(20)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .background {
            Button("") { close() }.keyboardShortcut(.cancelAction).opacity(0)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            content()
        }
    }

    private func close() { app.showSettings = false }
}

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
                Circle().fill(Theme.panel)
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
