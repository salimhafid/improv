import SwiftUI

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
                    if !alerts.syncIssue.isEmpty {
                        Text(alerts.syncIssue).foregroundStyle(.red)
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
                                if alerts.isUCBEnabled(school.id) {
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
    }

    private func ucbSubtitle(_ id: String) -> String {
        let set = alerts.prefs.ucb[id] ?? []
        if set.isEmpty { return "Off" }
        if set.count == ClassAlertsStore.ucbCategories.count { return "All categories" }
        return "\(set.count) categor\(set.count == 1 ? "y" : "ies")"
    }
}

/// Per-city UCB alert customization: on/off plus one toggle per class category.
struct UCBAlertDetailView: View {
    let school: ClassAlertsStore.School
    @Environment(ClassAlertsStore.self) private var alerts

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { alerts.isUCBEnabled(school.id) },
                                     set: { alerts.setUCB(school.id, enabled: $0) })) {
                    Text("Alert me about \(school.name)").font(.headline)
                }
                .tint(Theme.accent)
            } footer: {
                Text("New classes are checked every 10 minutes and alert immediately.")
            }

            Section("Categories") {
                ForEach(ClassAlertsStore.ucbCategories, id: \.key) { category in
                    Toggle(isOn: Binding(
                        get: { (alerts.prefs.ucb[school.id] ?? []).contains(category.key) },
                        set: { alerts.setUCBCategory(school.id, category: category.key, enabled: $0) })) {
                        Text(category.label)
                    }
                    .tint(Theme.accent)
                    .disabled(!alerts.isUCBEnabled(school.id))
                }
            }
        }
        .navigationTitle(school.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
