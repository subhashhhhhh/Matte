import SwiftUI

/// Edit profile: name, username, bio and link, as instagram.com's form offers them.
struct EditProfileSheet: View {
    let onSaved: () -> Void
    let onClose: () -> Void
    @Environment(AppModel.self) private var app
    @State private var form: EditableProfile?
    @State private var original: EditableProfile?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { if !saving { onClose() } }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Edit profile").font(.system(size: 16, weight: .bold))
                    Spacer()
                    Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30) }
                        .buttonStyle(.pressable)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 18)
                .frame(height: 56)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                if form != nil {
                    fields.padding(18)
                } else {
                    Spinner(size: 18).frame(maxWidth: .infinity).padding(40)
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack {
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.like).lineLimit(2) }
                    Spacer()
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .buttonStyle(.prominentCompact)
                        .disabled(form == nil || form == original || saving || (form?.username.isEmpty ?? true))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(14)
            }
            .frame(width: 460)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.panelStroke))
            .shadow(color: .black.opacity(0.3), radius: 30)
            .popIn()
        }
        .task {
            do {
                let p = try await app.client?.editableProfile()
                form = p
                original = p
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        let binding = Binding<EditableProfile>(get: { form! }, set: { form = $0 })
        VStack(alignment: .leading, spacing: 14) {
            field("Name", text: binding.name)
            field("Username", text: binding.username)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Bio").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(binding.wrappedValue.bio.count) / 150").font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(binding.wrappedValue.bio.count > 150 ? AnyShapeStyle(Theme.like) : AnyShapeStyle(.tertiary))
                }
                TextField("", text: binding.bio, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(3...6)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
            }
            field("Link", text: binding.link)
            Toggle(isOn: binding.suggestAccount) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggest your account to others").font(.system(size: 13, weight: .medium))
                    Text("Shown in suggestions on other profiles.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
        }
    }

    private func save() async {
        guard let form, let client = app.client else { return }
        if form.bio.count > 150 { error = "Your bio can be at most 150 characters."; return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await client.saveProfile(form)
            app.show("Profile saved")
            onSaved()
            onClose()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
