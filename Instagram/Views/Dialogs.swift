import SwiftUI

/// The app's dialog card, as the "Send to…" sheet draws it: a dimmed backdrop that closes it,
/// a rounded card that pops in.
struct DialogCard<Content: View>: View {
    var width: CGFloat
    var height: CGFloat?
    let close: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture(perform: close)
            content
                .frame(width: width, height: height)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.background))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.panelStroke))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 30)
                .popIn()
        }
    }
}

/// "Delete post?" and the like: a title, a line of explanation, a red action and Cancel.
struct ConfirmDialog: View {
    let title: String
    let message: String
    let action: String
    var busy = false
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        DialogCard(width: 340, close: cancel) {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text(title).font(.system(size: 17, weight: .bold))
                    Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 26)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Button(action: confirm) {
                    HStack(spacing: 8) {
                        if busy { Spinner(size: 13) }
                        Text(busy ? "Deleting…" : action)
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.like)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .disabled(busy)
                .keyboardShortcut(.defaultAction)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Button(action: cancel) {
                    Text("Cancel").font(.system(size: 14)).frame(maxWidth: .infinity).frame(height: 48).contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .keyboardShortcut(.cancelAction)
            }
        }
    }
}

/// Asks before deleting your post (`app.confirmingDelete`).
struct DeletePostDialog: View {
    let media: Media
    @Environment(AppModel.self) private var app
    @State private var busy = false

    var body: some View {
        let reel = media.productType == "clips"
        ConfirmDialog(title: reel ? "Delete reel?" : "Delete post?",
                      message: "It's removed from your profile and can't be brought back.",
                      action: "Delete", busy: busy,
                      confirm: {
                          guard let actions = app.actions, !busy else { return }
                          busy = true
                          Task {
                              _ = await actions.delete(media)
                              busy = false
                              app.confirmingDelete = nil
                          }
                      },
                      cancel: { if !busy { app.confirmingDelete = nil } })
    }
}

/// "Edit caption" for your post: its picture, the caption with a character counter, Save.
struct CaptionEditSheet: View {
    let media: Media
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var saving = false
    @FocusState private var focused: Bool

    private var tooLong: Bool { text.count > CreateModel.captionLimit }
    private var unchanged: Bool { text == (app.actions?.caption(media) ?? "") }

    var body: some View {
        DialogCard(width: 480, close: close) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    RemoteImage(url: media.image(minWidth: 80), contentMode: .fill)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("Edit caption").font(.system(size: 15, weight: .bold))
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.pressable)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 16)
                .frame(height: 60)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                CaptionField(text: $text, focused: $focused, height: 150)
                    .padding(14)
                HStack {
                    CaptionCounter(count: text.count)
                    Spacer()
                    Button(saving ? "Saving…" : "Save") { save() }
                        .buttonStyle(.prominentCompact)
                        .disabled(saving || tooLong || unchanged)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .onAppear {
            text = app.actions?.caption(media) ?? ""
            focused = true
        }
    }

    private func save() {
        guard let actions = app.actions, !saving, !tooLong else { return }
        saving = true
        Task {
            let ok = await actions.saveCaption(text, for: media)
            saving = false
            if ok { close() }
        }
    }

    private func close() { if !saving { app.editingCaption = nil } }
}

/// A multi-line caption box in the app's panel style, with a placeholder.
struct CaptionField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var height: CGFloat = 120
    var placeholder = "Write a caption…"

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder).font(.system(size: 14)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 5).padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused(focused)
                .padding(.vertical, 8)
        }
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
    }
}

/// "123/2,200", red past the limit.
struct CaptionCounter: View {
    let count: Int

    var body: some View {
        Text("\(count.formatted())/\(CreateModel.captionLimit.formatted())")
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(count > CreateModel.captionLimit ? AnyShapeStyle(Theme.like) : AnyShapeStyle(.tertiary))
    }
}

/// A small on/off switch drawn in the app's style (no system switch).
struct PillSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(Theme.link) : AnyShapeStyle(Color.primary.opacity(0.16)))
            .frame(width: 34, height: 20)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 16, height: 16).padding(2)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            }
            .contentShape(Capsule())
            .onTapGesture { withAnimation(Motion.slide) { isOn.toggle() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isOn ? "On" : "Off")
    }
}
