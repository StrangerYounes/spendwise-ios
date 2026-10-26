import SwiftUI
import UIKit
import SpendWiseCore

/// Settings → Sync across devices (FEATURES.md §6.1): the plan, signing in, and how sync is doing;
/// then Family (§6.5).
struct AccountSection: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var signInNotice = false
    @State private var confirm: Confirm?

    var body: some View {
        let cloud = model.cloud
        SettingsSection(title: L("sync_section")) {
            if let user = cloud.user {
                HStack(spacing: 16) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 22)).foregroundStyle(Palette.primary).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.name.isEmpty ? user.email : user.name).font(.bodyL).foregroundStyle(Palette.onSurface)
                        Text(user.email).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                if cloud.tier.syncs || cloud.family != nil { SyncStatusRow(status: cloud.syncStatus) } else { premiumRow }
                SettingsRow(icon: "rectangle.portrait.and.arrow.right", title: L("sign_out"), subtitle: L("sign_out_sub"), trailing: .none) {
                    let waiting = cloud.syncStatus.waiting
                    confirm = Confirm(title: L("sign_out_q"), message: L("sign_out_body") + (waiting > 0 ? "\n\n" + P("sign_out_waiting", waiting) : ""),
                                      label: L("sign_out"), destructive: false) { Task { await cloud.signOut() } }
                }
                SettingsRow(icon: "person.crop.circle.badge.minus", title: L("delete_account"), subtitle: L("delete_account_sub"), trailing: .none, tint: Palette.error) {
                    confirm = Confirm(title: L("delete_account_q"), message: L("delete_account_body"), label: L("delete")) { Task { await cloud.deleteAccount() } }
                }
            } else {
                SettingsRow(icon: "person.crop.circle", title: L("sign_in_google"),
                            subtitle: !cloud.canSignInWithGoogle && !cloud.usingEmulators ? L("sign_in_not_set_up")
                                : cloud.tier.syncs ? L("sign_in_sub_sync") : L("sign_in_sub_family"),
                            trailing: cloud.busy ? .progress : .none) { signInNotice = true }
                    .accessibilityIdentifier("signIn")
                #if DEBUG
                if cloud.usingEmulators {
                    SettingsRow(icon: "testtube.2", title: "Sign in as test user", subtitle: "Emulators: the same account on every test phone", trailing: .none) {
                        Task { await cloud.signInForTest("Test User") }
                    }
                    SettingsRow(icon: "testtube.2", title: "Sign in as second test user", subtitle: "Emulators: a different account", trailing: .none) {
                        Task { await cloud.signInForTest("Second User") }
                    }
                }
                #endif
                if !cloud.tier.syncs { premiumRow }
            }
        }
        .sheet(isPresented: $signInNotice) {
            SignInNotice(syncs: cloud.tier.syncs) { Task { await cloud.signIn() } }
        }
        .confirm($confirm)

        if cloud.user != nil { FamilySection() }
    }

    private var premiumRow: some View {
        SettingsRow(icon: "iphone.and.arrow.forward", title: L("sync_premium_title"), subtitle: L("sync_premium_sub"), trailing: .premium) { router.upgrade() }
    }
}

/// Home's title bar: how sync is doing, for a signed-in Premium user. Tapping opens Settings.
struct SyncIndicator: View {
    @Environment(AppModel.self) private var model
    let open: () -> Void

    static func look(_ state: SyncStatus.State) -> (icon: String, label: String) {
        switch state {
        case .synced: return ("checkmark.icloud", L("sync_synced"))
        case .syncing, .joining: return ("arrow.triangle.2.circlepath.icloud", L("sync_syncing"))
        case .offline: return ("icloud.slash", L("sync_offline_short"))
        case .error, .off: return ("exclamationmark.icloud", L("sync_failed_short"))
        }
    }
    var body: some View {
        let status = model.cloud.syncStatus
        if status.state != .off {
            let look = Self.look(status.state)
            Button(action: open) { Image(systemName: look.icon).font(.system(size: 15)).foregroundStyle(Palette.onSurfaceVariant) }
                .accessibilityLabel(look.label)
        }
    }
}

private struct SyncStatusRow: View {
    let status: SyncStatus
    var body: some View {
        let row = describe()
        HStack(spacing: 16) {
            Image(systemName: row.icon).foregroundStyle(Palette.primary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("sync")).font(.bodyL).foregroundStyle(Palette.onSurface)
                Text(row.text).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityIdentifier("syncStatus")
    }

    private func describe() -> (icon: String, text: String) {
        let waiting = status.waiting > 0 ? " · " + P("sync_waiting", status.waiting) : ""
        switch status.state {
        case .synced: return ("checkmark.icloud", L("sync_up_to_date") + (status.lastSyncedAt.map { " · " + ago($0) } ?? ""))
        case .syncing: return ("arrow.triangle.2.circlepath.icloud", L("sync_syncing_long", waiting))
        case .joining: return ("arrow.triangle.2.circlepath.icloud", L("sync_joining"))
        case .offline: return ("icloud.slash", L("sync_offline_long", waiting))
        case .error: return ("exclamationmark.icloud", L("sync_retrying", waiting) + (status.error.map { "\n\($0)" } ?? ""))
        case .off: return ("icloud.slash", L("sync_off"))
        }
    }

    private func ago(_ at: Millis) -> String {
        let seconds = Double(nowMillis() - at) / 1000
        if seconds < 60 { return L("just_now") }
        let f = RelativeDateTimeFormatter()
        f.locale = Lang.formatLocale
        return f.localizedString(for: Date(millis: at), relativeTo: Date())
    }
}

/// Before signing in: what leaves the phone.
private struct SignInNotice: View {
    @Environment(\.dismiss) private var dismiss
    let syncs: Bool
    let proceed: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "icloud.and.arrow.up").font(.system(size: 28)).foregroundStyle(Palette.primary).frame(maxWidth: .infinity)
                    Text(L("cloud_account"))
                    // The plan is only known after signing in: an account may already have Premium or a family
                    Text(L(syncs ? "cloud_syncs" : "cloud_maybe"))
                    Text(L("cloud_photos")).foregroundStyle(Palette.onSurfaceVariant)
                    Button(L("privacy_policy")) { UIApplication.shared.open(Links.privacy) }.foregroundStyle(Palette.primary)
                }
                .font(.bodyM).foregroundStyle(Palette.onSurface)
                .padding(20)
            }
            .background(Palette.containerHigh.ignoresSafeArea())
            .navigationTitle(L("cloud_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L("continue_")) { dismiss(); proceed() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Settings → Family: share every list with other accounts, each on their own phones.
private struct FamilySection: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var confirm: Confirm?
    @State private var joining = false
    @State private var code = ""

    var body: some View {
        let cloud = model.cloud
        SettingsSection(title: L("family")) {
            if let family = cloud.family {
                ForEach(family.members, id: \.uid) { m in
                    let you = m.uid == cloud.user?.uid
                    HStack(spacing: 16) {
                        Image(systemName: m.owner ? "star.fill" : "person.fill").foregroundStyle(Palette.primary).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            let name = m.name.isEmpty ? m.email : m.name
                            Text(you ? L("family_you", name) : name).font(.bodyL).foregroundStyle(Palette.onSurface)
                            Text(m.owner ? L("family_owner_email", m.email) : m.email).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if family.isOwner && !you {
                            Button {
                                confirm = Confirm(title: L("family_remove_q", m.name.isEmpty ? m.email : m.name), message: L("family_remove_body"), label: L("remove")) {
                                    Task { await cloud.removeMember(m) }
                                }
                            } label: { Image(systemName: "person.badge.minus") }
                            .accessibilityLabel(L("family_remove_cd", m.name))
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                if family.isOwner {
                    SettingsRow(icon: "person.badge.plus", title: L("family_invite"), subtitle: L("family_invite_sub"), trailing: .none) { Task { await cloud.invite() } }
                    SettingsRow(icon: "person.2.slash", title: L("family_close"), subtitle: L("family_close_sub"), trailing: .none) {
                        confirm = Confirm(title: L("family_close_q"), message: L("family_close_body"), label: L("family_close_button")) { Task { await cloud.closeFamily() } }
                    }
                } else {
                    SettingsRow(icon: "rectangle.portrait.and.arrow.right", title: L("family_leave"), subtitle: L("family_leave_sub"), trailing: .none) {
                        confirm = Confirm(title: L("family_leave_q"), message: L("family_leave_body"), label: L("family_leave_button"), destructive: false) {
                            Task { await cloud.leaveFamily() }
                        }
                    }
                }
            } else {
                SettingsRow(icon: "figure.2.and.child.holdinghands", title: L("family_share"), subtitle: L("family_share_sub"),
                            trailing: cloud.tier.syncs ? .none : .premium) {
                    if cloud.tier.syncs {
                        confirm = Confirm(title: L("family_share_q"), message: L("family_share_body"), label: L("family_start"), destructive: false) {
                            Task { await cloud.createFamily() }
                        }
                    } else { router.upgrade() }
                }
                SettingsRow(icon: "person.2.badge.plus", title: L("family_join"), subtitle: L("family_join_sub"), trailing: .none) { code = ""; joining = true }
            }
        }
        .confirm($confirm)
        .alert(L("family_join"), isPresented: $joining) {
            TextField("XXXX XXXX", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
            Button(L("family_join_button")) { Task { await cloud.joinFamily(code) } }
            Button(L("cancel"), role: .cancel) {}
        } message: { Text(L("family_join_body")) }
        .alert(L("family_invite_code"), isPresented: Binding(get: { cloud.inviteCode != nil }, set: { if !$0 { cloud.inviteCode = nil } })) {
            if let c = cloud.inviteCode {
                ShareLink(item: L("family_invite_message", c)) { Text(L("family_send_code")) }
            }
            Button(L("ok"), role: .cancel) { cloud.inviteCode = nil }
        } message: {
            Text((cloud.inviteCode ?? "") + "\n\n" + L("family_invite_how"))
        }
    }
}

#if DEBUG
/// Debug builds: the plan switch (emulators only), and the emulators switch.
struct DeveloperSection: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let cloud = model.cloud
        SettingsSection(title: "Developer (debug builds only)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Plan").font(.bodyL).foregroundStyle(Palette.onSurface)
                if !cloud.planSwitchable {
                    Text("From your account on the server (\(cloud.tier == .premium ? "Premium" : "Free")). The switch works with the local emulators.")
                        .font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                }
                Picker("", selection: Binding(get: { cloud.tier }, set: { cloud.setDebugTier($0) })) {
                    Text("Free").tag(Tier.free)
                    Text("Premium").tag(Tier.premium)
                }
                .pickerStyle(.segmented)
                .disabled(!cloud.planSwitchable)
            }
            .padding(16)
            Toggle(isOn: Binding(get: { cloud.previewPremium }, set: { cloud.setPreviewPremium($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Premium screens").font(.bodyL).foregroundStyle(Palette.onSurface)
                    Text("This phone only, to look around. The server still decides what the AI and sync allow.")
                        .font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                }
            }
            .tint(Palette.primary)
            .padding(16)
            SettingsRow(icon: "tray.and.arrow.down", title: "Load sample data", subtitle: "Four months of lists, prices and a report, added to what's here", trailing: .none) {
                DemoData.load(model)
                model.show("Sample data loaded")
            }
            Toggle(isOn: Binding(get: { Cloud.emulatorsWanted }, set: { Cloud.emulatorsWanted = $0; model.show("Restart the app to switch servers") })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use local Firebase emulators").font(.bodyL).foregroundStyle(Palette.onSurface)
                    Text(cloud.usingEmulators ? "In use (127.0.0.1: 9196, 8196, 5196)" : "Applies after restarting the app").font(.bodyS).foregroundStyle(Palette.onSurfaceVariant)
                }
            }
            .tint(Palette.primary)
            .padding(16)
        }
    }
}
#endif
