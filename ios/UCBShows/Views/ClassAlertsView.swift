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
                        if !alerts.registrationIssue.isEmpty {
                            Text(alerts.registrationIssue).foregroundStyle(.red)
                        }
                        if !alerts.syncIssue.isEmpty {
                            Text(alerts.syncIssue).foregroundStyle(.red)
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
                                // nothing school doesn't get one.
                                if !(alerts.prefs.ucb[school.id] ?? []).isEmpty {
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
            // Opening this screen with alerts already on is the notifiable
            // moment for anyone whose prefs came from iCloud — they never touch
            // the toggle, so nothing else would ever ask. Silent when alerts
            // are off or permission is already settled.
            .task { await alerts.armIfNeeded() }
            .deniedNotificationsAlert(alerts)
        }
    }

    private func ucbSubtitle(_ id: String) -> String {
        guard let set = alerts.prefs.ucb[id] else { return "Off" }
        if set.isEmpty { return "On — no categories picked" }
        if set.count == ClassAlertsStore.ucbCategories.count { return "All categories" }
        return "\(set.count) categor\(set.count == 1 ? "y" : "ies")"
    }
}

/// Per-city UCB alert customization: on/off plus one toggle per class category.
/// Switching a school on starts at Improv only, so the header carries an
/// explicit Select all — the school toggle is no longer a bulk-select in disguise.
struct UCBAlertDetailView: View {
    let school: ClassAlertsStore.School
    @Environment(ClassAlertsStore.self) private var alerts

    private var selected: Set<String> { alerts.prefs.ucb[school.id] ?? [] }
    private var allSelected: Bool { selected.count == ClassAlertsStore.ucbCategories.count }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { alerts.isUCBEnabled(school.id) },
                                     set: { alerts.setUCB(school.id, enabled: $0) })) {
                    Text("Alert me about \(school.name)").font(.headline)
                }
                .tint(Theme.accent)
            } footer: {
                Text("New classes are checked every 10 minutes and alert immediately. Starts with Improv — add whatever else you want below.")
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
        .deniedNotificationsAlert(alerts)
    }
}

/// The "you switched this on but notifications are off" alert. Lives as a
/// modifier because it has to sit on BOTH screens — the per-school and
/// per-category toggles are in `UCBAlertDetailView`, where the sheet's footer
/// isn't, so that screen would otherwise flip a switch green and say nothing.
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
