import SwiftUI
import SpendWiseCore

/// Signed in to an account while the phone holds another account's lists (Android
/// OtherAccountDialog, FEATURES.md §6.3): add them to this account, or start with this account's
/// lists (removing the phone's, after an optional backup), or cancel the sign-in. Shown over any
/// screen and can't be swiped away; nothing goes up until it is answered.
struct OtherAccountSheet: View {
    @Environment(AppModel.self) private var model
    let user: SignedIn
    @State private var confirmFresh = false
    @State private var busy = false
    @State private var exportDoc: BackupDocument?
    @State private var backupNote: String?

    var body: some View {
        // The account's own address (a relay one is still theirs); its name when Apple gave no email
        let email = user.email.isEmpty ? accountTitle(user.name, user.email) : user.email
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: confirmFresh ? "iphone.slash" : "person.2.badge.gearshape")
                        .font(.system(size: 30)).foregroundStyle(confirmFresh ? Palette.error : Palette.primary)
                        .frame(maxWidth: .infinity)
                    Text(L(confirmFresh ? "other_account_fresh_q" : "other_account_title")).font(.titleL).foregroundStyle(Palette.onSurface)
                    if confirmFresh { freshConfirmation(email) } else { choices(email) }
                }
                .padding(20)
            }
            .background(Palette.containerHigh.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if confirmFresh {
                        Button(L("back")) { confirmFresh = false }.disabled(busy).accessibilityIdentifier("otherAccountBack")
                    } else {
                        Button(L("cancel")) { answer(.cancel) }.disabled(busy).accessibilityIdentifier("otherAccountCancel")
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            #if DEBUG
            if DemoMode.isOn && DemoMode.screen == "other_account_fresh" { confirmFresh = true }
            #endif
        }
        .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }), document: exportDoc,
                      contentType: .json, defaultFilename: exportDoc?.name) { result in
            switch result {
            case .success: backupNote = L("msg_backup_saved")
            case .failure(let e): backupNote = UserErrors.message(e, L("err_save_backup"))
            }
            exportDoc = nil
        }
    }

    private func choices(_ email: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("other_account_body", email)).font(.bodyM).foregroundStyle(Palette.onSurface)
            Button { answer(.addThem) } label: {
                Text(L("other_account_add", email)).frame(maxWidth: .infinity)
            }
            .buttonStyle(FilledButtonStyle())
            .disabled(busy)
            .accessibilityIdentifier("otherAccountAdd")
            Button { confirmFresh = true } label: {
                Text(L("other_account_fresh")).font(.labelL).frame(maxWidth: .infinity).frame(minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.outline))
            }
            .buttonStyle(.plainRow)
            .foregroundStyle(Palette.primary)
            .disabled(busy)
            .accessibilityIdentifier("otherAccountFresh")
        }
    }

    private func freshConfirmation(_ email: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("other_account_fresh_body", email)).font(.bodyM).foregroundStyle(Palette.onSurface)
            Button { backup() } label: {
                Label(L("other_account_backup"), systemImage: "externaldrive.badge.icloud").font(.labelL)
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.outline))
            }
            .buttonStyle(.plainRow)
            .foregroundStyle(Palette.primary)
            .disabled(busy)
            .accessibilityIdentifier("otherAccountBackup")
            if let backupNote { Text(backupNote).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant) }
            Button(role: .destructive) { answer(.startFresh) } label: {
                Text(L("other_account_remove")).frame(maxWidth: .infinity)
            }
            .buttonStyle(FilledButtonStyle(background: Palette.error))
            .disabled(busy)
            .accessibilityIdentifier("otherAccountRemove")
        }
    }

    private func answer(_ a: Cloud.OwnerAnswer) {
        busy = true
        Task {
            await model.cloud.answer(a)
            busy = false
        }
    }

    private func backup() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        do {
            let text = try model.backup.exportData(itemsOnly: false)
            exportDoc = BackupDocument(text: text, name: "spendwise_full_backup_\(f.string(from: Date())).json")
        } catch {
            backupNote = UserErrors.message(error, L("err_make_backup"))
        }
    }
}

/// Sign out (FEATURES.md §6.1): Keep lists on this phone (the default) or Remove them from this
/// phone; warns when changes haven't reached the account yet.
struct SignOutSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var removeLists = false

    var body: some View {
        let waiting = model.cloud.syncStatus.waiting
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L(removeLists ? "sign_out_body_remove" : "sign_out_body")).font(.bodyM).foregroundStyle(Palette.onSurface)
                    VStack(spacing: 0) {
                        option(false, L("sign_out_keep"), id: "signOutKeep")
                        option(true, L("sign_out_remove"), id: "signOutRemove")
                    }
                    if waiting > 0 { Text(P("sign_out_waiting", waiting)).font(.bodyM).foregroundStyle(Palette.error) }
                }
                .padding(20)
            }
            .background(Palette.containerHigh.ignoresSafeArea())
            .navigationTitle(L("sign_out_q"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("sign_out")) {
                        let remove = removeLists
                        dismiss()
                        Task { await model.cloud.signOut(removeLists: remove) }
                    }
                    .foregroundStyle(removeLists ? Palette.error : Palette.primary)
                    .accessibilityIdentifier("signOutConfirm")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func option(_ remove: Bool, _ label: String, id: String) -> some View {
        Button { removeLists = remove } label: {
            HStack(spacing: 12) {
                Image(systemName: removeLists == remove ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(removeLists == remove ? Palette.primary : Palette.onSurfaceVariant)
                Text(label).font(.bodyL).foregroundStyle(Palette.onSurface).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plainRow)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(removeLists == remove ? .isSelected : [])
    }
}
