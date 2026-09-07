import SwiftUI
import UIKit

/// The Class Alerts sheet: master switch, customizable UCB rows (NY / LA /
/// Online, each with per-category toggles), and simple on/off rows for every
/// other school. Subscriptions work independently of which theaters are
/// visible in the Shows/Classes feeds.
struct ClassAlertsView: View {
    @Environment(ClassAlertsStore.self) private var alerts
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: Binding(get: { alerts.prefs.master },
                                         set: { alerts.setMaster($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Class Alerts").font(.headline)
                            Text("Push when a school posts a new class")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tint(Theme.accent)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        // A green switch and silence is the worst outcome: say
                        // what's wrong and hand over a way to fix it.
                        if alerts.authorizationDenied {
                            Text("Notifications are turned off for Improv, so class alerts can’t reach you.")
                                .foregroundStyle(.red)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .font(.footnote)
                        }
                        // Only while alerts are on: a failed switch-off
                        // retries on its own, and a red line under an Off
                        // switch reads as a problem the user can't act on.
                        if alerts.prefs.master {
                            if !alerts.registrationIssue.isEmpty {
                                Text(alerts.registrationIssue).foregroundStyle(.red)
                            }
                            if !alerts.syncIssue.isEmpty {
                                Text(alerts.syncIssue).foregroundStyle(.red)
                            }
                        }
                    }
                }

                Section {
                    ForEach(ClassAlertsStore.ucbSchools) { school in
                        NavigationLink {
                            UCBAlertDetailView(school: school)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(school.name)
                                    Text(ucbSubtitle(school.id))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                // Bell means "actually pushing", so an on-with-
                                // nothing school doesn't get one — nor any
                                // school while the master switch is Off.
                                if alerts.prefs.master, !(alerts.prefs.ucb[school.id] ?? []).isEmpty {
                                    Image(systemName: "bell.fill")
                                        .font(.caption).foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .disabled(!alerts.prefs.master)
                    }
                } header: {
                    Text("UCB — customizable")
                } footer: {
                    Text("Checked every 10 minutes. Pick exactly which class categories alert you, per city.")
                }

                Section {
                    ForEach(ClassAlertsStore.otherSchools) { school in
                        Toggle(isOn: Binding(
                            get: { alerts.prefs.schools.contains(school.id) },
                            set: { alerts.setSchool(school.id, enabled: $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(school.name)
                                Text(school.city).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tint(Theme.accent)
                        .disabled(!alerts.prefs.master)
                    }
                } header: {
                    Text("Other schools")
                } footer: {
                    Text("Checked daily — one bundled notification per school when anything new appears. Alerts work even for theaters you don’t have toggled on elsewhere.")
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
        .deniedNotificationsAlert(alerts)
    }

    private func ucbSubtitle(_ id: String) -> String {
        // Reads Off with the master switch Off, like the toolbar badge.
        guard alerts.prefs.master, let set = alerts.prefs.ucb[id] else { return "Off" }
        if set.isEmpty { return "On — no categories picked" }
        if ClassAlertsStore.ucbCategoryKeys.isSubset(of: set) { return "All categories" }
        return "\(set.count) categor\(set.count == 1 ? "y" : "ies")"
    }
}

/// Per-city UCB alert customization: on/off plus one toggle per class category.
/// Switching a school on starts at the three-category seed (see
/// `defaultUCBCategories`), so the header carries an explicit Select all — the
/// school toggle is no longer a bulk-select in disguise.
struct UCBAlertDetailView: View {
    let school: ClassAlertsStore.School
    @Environment(ClassAlertsStore.self) private var alerts

    private var selected: Set<String> { alerts.prefs.ucb[school.id] ?? [] }
    private var allSelected: Bool { ClassAlertsStore.ucbCategoryKeys.isSubset(of: selected) }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { alerts.isUCBEnabled(school.id) },
                                     set: { alerts.setUCB(school.id, enabled: $0) })) {
                    Text("Alert me about \(school.name)").font(.headline)
                }
                .tint(Theme.accent)
            } footer: {
                Text("New classes are checked every 10 minutes and alert immediately. Starts with Improv, Improv Electives, and Featured Programs — add whatever else you want below.")
            }

            Section {
                ForEach(ClassAlertsStore.ucbCategories, id: \.key) { category in
                    Toggle(isOn: Binding(
                        get: { selected.contains(category.key) },
                        set: { alerts.setUCBCategory(school.id, category: category.key, enabled: $0) })) {
                        Text(category.label)
                    }
                    .tint(Theme.accent)
                    .disabled(!alerts.isUCBEnabled(school.id))
                }
            } header: {
                HStack {
                    Text("Categories")
                    Spacer()
                    Button(allSelected ? "Clear all" : "Select all") {
                        alerts.setAllUCBCategories(school.id, enabled: !allSelected)
                    }
                    .font(.caption)
                    .textCase(nil)
                    .disabled(!alerts.isUCBEnabled(school.id))
                }
            }
        }
        .navigationTitle(school.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The "you switched this on but notifications are off" alert. Attached once,
/// to the sheet's `NavigationStack`, so it covers BOTH screens — the per-school
/// and per-category toggles are in `UCBAlertDetailView`, where the sheet's
/// footer isn't, so that screen would otherwise flip a switch green and say
/// nothing. Once, because two `alert(isPresented:)` on one binding is two
/// presenters fighting over a single flag.
private struct DeniedNotificationsAlert: ViewModifier {
    @Bindable var alerts: ClassAlertsStore

    func body(content: Content) -> some View {
        content.alert("Turn On Notifications", isPresented: $alerts.deniedPromptVisible) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Notifications are turned off for Improv, so class alerts can\u{2019}t reach you. Turn them on in Settings and your picks here will start arriving.")
        }
    }
}

private extension View {
    func deniedNotificationsAlert(_ alerts: ClassAlertsStore) -> some View {
        modifier(DeniedNotificationsAlert(alerts: alerts))
    }
}
