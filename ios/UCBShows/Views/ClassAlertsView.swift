import StoreKit
import SwiftUI
import UIKit

/// The Class Alerts sheet: master switch, customizable UCB and BCC rows
/// with per-category toggles, and simple on/off rows for every
/// other school. Subscriptions work independently of which theaters are
/// visible in the Shows/Classes feeds.
///
/// Until the purchase gate says unlocked, a paywall leads the sheet and the
/// controls below it stay visible but disabled — what the purchase buys.
struct ClassAlertsView: View {
    @Environment(ClassAlertsStore.self) private var alerts
    @Environment(ClassAlertsAccess.self) private var access
    @Environment(\.dismiss) private var dismiss
    /// Set by Unlock/Restore. Only an unlock the user asked for in this sheet
    /// switches alerts on; one that lands by itself (the launch or foreground
    /// refresh settling) must not flip a switch they never touched. So it is
    /// cleared once used, and when the tap ends without an unlock still on
    /// the way. A pending Ask to Buy keeps it, so the approval still counts.
    @State private var userRequestedUnlock = false

    /// What the switches show. Locked reads Off whatever the saved prefs say
    /// (they ride iCloud and are never edited by the paywall), matching the
    /// bell badge. Unknown keeps the saved value, since the reconcile leaves
    /// existing subscriptions alone.
    private var alertsOn: Bool { alerts.prefs.master && !access.isLocked }

    var body: some View {
        NavigationStack {
            List {
                if !access.isUnlocked {
                    paywallSection
                }

                Section {
                    Toggle(isOn: Binding(get: { alertsOn },
                                         set: { alerts.setMaster($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Class Alerts").font(.headline)
                            Text("Push when a school posts a new class")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tint(Theme.accent)
                    .disabled(!access.isUnlocked)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if case .unlocked(let reason) = access.state, let note = unlockNote(reason) {
                            Text(note)
                        }
                        // Only while alerts are on: a failed switch-off
                        // retries on its own, and a red line under an Off
                        // switch reads as a problem the user can't act on.
                        // The same goes for a switch the paywall disables.
                        if alerts.prefs.master && access.isUnlocked {
                            if !alerts.registrationIssue.isEmpty {
                                Text(alerts.registrationIssue).foregroundStyle(.red)
                            }
                            if !alerts.syncIssue.isEmpty {
                                Text(alerts.syncIssue).foregroundStyle(.red)
                            }
                        }
                    }
                }

                if alerts.prefs.master && access.isUnlocked {
                    Section {
                        if let delivery = alerts.deliveryStatus {
                            ForEach(delivery.issues) { issue in
                                Label(issue.message, systemImage: "exclamationmark.bubble")
                                    .font(.subheadline)
                            }
                            if delivery.issues.isEmpty {
                                Text("Banners and Lock Screen alerts are enabled.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        } else {
                            ProgressView("Checking notification settings…")
                        }
                        Button("Open Notification Settings") {
                            openNotificationSettings()
                        }
                    } header: {
                        Text("Notification Delivery")
                    } footer: {
                        Text("To see class alerts as they arrive, enable Banners and Immediate Delivery in Settings. If you use a Focus, allow notifications from Improv in that Focus.")
                    }
                }

                Section {
                    ForEach(ClassAlertCatalog.ucbSchools) { school in
                        categorizedSchoolRow(school)
                    }
                } header: {
                    Text("UCB — customizable")
                } footer: {
                    Text("Checked every few minutes. Pick exactly which class categories alert you, per city.")
                }

                Section {
                    categorizedSchoolRow(ClassAlertCatalog.bccSchool)
                } header: {
                    Text("BCC — customizable")
                } footer: {
                    Text("Checked daily. Pick which class categories alert you.")
                }

                Section {
                    ForEach(ClassAlertCatalog.otherSchools) { school in
                        Toggle(isOn: Binding(
                            get: { alerts.prefs.schools.contains(school.id) },
                            set: { alerts.setSchool(school.id, enabled: $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(school.name)
                                Text(school.city).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tint(Theme.accent)
                        .disabled(!alerts.prefs.master || !access.isUnlocked)
                    }
                } header: {
                    Text("Other schools")
                } footer: {
                    Text("Checked daily — one notification per new class, or a single summary when a school posts many at once. Alerts work even for theaters you don’t have toggled on elsewhere.")
                }
            }
            .navigationTitle("Class Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Opening this screen with alerts already on is the notifiable
        // moment for anyone whose prefs came from iCloud — they never touch
        // the toggle, so nothing else would ever ask. Silent when alerts
        // are off or permission is already settled. On the stack, not the
        // root list: the list disappears under every push, and re-arming
        // on each pop back is an APNs + CloudKit round trip for nothing.
        .task { await alerts.armIfNeeded() }
        // A purchase or restore made here is the moment to turn alerts on —
        // and it is notifiable, so `setMaster` asks for permission. Saved
        // prefs that already say On (iCloud, or a re-purchase) skipped the
        // sheet-open ask while locked; arm them now instead.
        .onChange(of: access.isUnlocked) { wasUnlocked, isUnlocked in
            guard userRequestedUnlock, !wasUnlocked, isUnlocked else { return }
            userRequestedUnlock = false
            if alerts.prefs.master {
                Task { await alerts.armIfNeeded() }
            } else {
                alerts.setMaster(true)
            }
        }
        .deniedNotificationsAlert(alerts)
    }

    /// The pitch, the buy button and Restore. Buying and restoring stay
    /// available while the gate is still checking: a buyer on a fresh device
    /// shouldn't wait on a slow AppTransaction to restore.
    private var paywallSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Class Alerts").font(.title3.bold())
                Text("Get a notification when UCB, BCC, Magnet and other schools post a new class — one per class, with the instructor and category, and a tap opens it.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            if access.state == .unknown {
                ProgressView("Checking your purchase…")
            }

            buyButton

            Button("Restore Purchase") {
                userRequestedUnlock = true
                Task {
                    await access.restore()
                    // Nothing found, cancelled or failed: a restore has no
                    // later outcome, so a later unlock isn't this tap's.
                    if !access.isUnlocked { userRequestedUnlock = false }
                }
            }
            .disabled(access.isPurchasing)
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("One-time purchase. No subscription.")
                if let message = access.purchaseMessage {
                    Text(message)
                }
            }
        }
    }

    @ViewBuilder
    private var buyButton: some View {
        if let product = access.product {
            unlockButton(price: product.displayPrice) {
                userRequestedUnlock = true
                Task {
                    await access.purchase()
                    // Cancelled: the user said no. Any outcome with a message
                    // keeps the request, above all a pending Ask to Buy.
                    if !access.isUnlocked && access.purchaseMessage == nil { userRequestedUnlock = false }
                }
            }
        } else if let price = ProcessInfo.processInfo.uiTestPaywallPrice {
            // DEBUG screenshots only (the App Review screenshot): a simulator
            // launched outside Xcode can't load the product.
            unlockButton(price: price) {}
        } else if access.productLoadFailed {
            Button("Unavailable — Try Again") {
                Task { await access.refresh() }
            }
        } else {
            Text("Loading price…").foregroundStyle(.secondary)
        }
    }

    private func unlockButton(price: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if access.isPurchasing { ProgressView() }
                Text("Unlock for \(price)").bold()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(Theme.accent)
        .disabled(access.isPurchasing)
    }

    /// Why alerts are free here, for the two unlocks the user didn't buy.
    private func unlockNote(_ reason: ClassAlertsUnlockReason) -> String? {
        switch reason {
        case .purchased: return nil
        case .grandfathered: return "Included free for everyone who installed Improv before Class Alerts became a purchase."
        case .testFlightFree: return "TestFlight build: Class Alerts are unlocked without purchase."
        }
    }

    private func categorizedSchoolRow(_ school: ClassAlertCatalog.School) -> some View {
        NavigationLink {
            CategoryAlertDetailView(school: school)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(school.name)
                    Text(categorySubtitle(school.id))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // The bell counts a school only while it can send alerts.
                if alertsOn, !(alerts.prefs.categorySelections[school.id] ?? []).isEmpty {
                    Image(systemName: "bell.fill")
                        .font(.caption).foregroundStyle(Theme.accent)
                }
            }
        }
        .disabled(!alerts.prefs.master || !access.isUnlocked)
    }

    private func categorySubtitle(_ id: String) -> String {
        // Reads Off with the master switch Off (or locked), like the toolbar badge.
        guard alertsOn, let set = alerts.prefs.categorySelections[id] else { return "Off" }
        if set.isEmpty { return "On — no categories picked" }
        if ClassAlertCatalog.categoryKeys(for: id).isSubset(of: set) { return "All categories" }
        return "\(set.count) categor\(set.count == 1 ? "y" : "ies")"
    }
}

/// UCB and BCC customization. Newly enabled schools start with every category
/// except Improv Core and Sketch Core; existing selections stay as saved.
struct CategoryAlertDetailView: View {
    let school: ClassAlertCatalog.School
    @Environment(ClassAlertsStore.self) private var alerts
    /// The sheet's row only opens this screen while unlocked; this covers the
    /// gate closing (a refund) while it's already on screen.
    @Environment(ClassAlertsAccess.self) private var access

    private var selected: Set<String> { alerts.prefs.categorySelections[school.id] ?? [] }
    private var categories: [(key: String, label: String)] { ClassAlertCatalog.categories(for: school.id) }
    private var allSelected: Bool { ClassAlertCatalog.categoryKeys(for: school.id).isSubset(of: selected) }
    private var schedule: String {
        school.id == ClassAlertCatalog.bccSchool.id ? "Checked daily." : "Checked every few minutes."
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { alerts.isCategorizedSchoolEnabled(school.id) },
                                     set: { alerts.setCategorizedSchool(school.id, enabled: $0) })) {
                    Text("Alert me about \(school.name)").font(.headline)
                }
                .tint(Theme.accent)
                .disabled(!access.isUnlocked)
            } footer: {
                Text("\(schedule) When you enable this school, all categories start on except Improv Core and Sketch Core. Change your picks below.")
            }

            Section {
                ForEach(categories, id: \.key) { category in
                    Toggle(isOn: Binding(
                        get: { selected.contains(category.key) },
                        set: { alerts.setCategory(school.id, category: category.key, enabled: $0) })) {
                        Text(category.label)
                    }
                    .tint(Theme.accent)
                    .disabled(!alerts.isCategorizedSchoolEnabled(school.id) || !access.isUnlocked)
                }
            } header: {
                HStack {
                    Text("Categories")
                    Spacer()
                    Button(allSelected ? "Clear all" : "Select all") {
                        alerts.setAllCategories(school.id, enabled: !allSelected)
                    }
                    .font(.caption)
                    .textCase(nil)
                    .disabled(!alerts.isCategorizedSchoolEnabled(school.id) || !access.isUnlocked)
                }
            }
        }
        .navigationTitle(school.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The "you switched this on but notifications are off" alert. Attached once,
/// to the sheet's `NavigationStack`, so it covers BOTH screens — the per-school
/// and per-category toggles are in `CategoryAlertDetailView`, where the sheet's
/// footer isn't, so that screen would otherwise flip a switch green and say
/// nothing. Once, because two `alert(isPresented:)` on one binding is two
/// presenters fighting over a single flag.
private struct DeniedNotificationsAlert: ViewModifier {
    @Bindable var alerts: ClassAlertsStore

    func body(content: Content) -> some View {
        content.alert("Turn On Notifications", isPresented: $alerts.deniedPromptVisible) {
            Button("Open Settings") {
                openNotificationSettings()
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Notifications are turned off for Improv, so class alerts can\u{2019}t reach you. Turn them on in Settings and your picks here will start arriving.")
        }
    }
}

/// Open the actual notification controls, rather than the app's generic page.
private func openNotificationSettings() {
    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
        UIApplication.shared.open(url)
    }
}

private extension View {
    func deniedNotificationsAlert(_ alerts: ClassAlertsStore) -> some View {
        modifier(DeniedNotificationsAlert(alerts: alerts))
    }
}
