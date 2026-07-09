import SwiftUI

/// Sheet for refining the classes list within the current city + theater scope:
/// level/track and an open-only toggle. (City + theater are chosen elsewhere —
/// Setup and the sidebar.) Binds directly to the store so changes apply live.
struct ClassFilterSheet: View {
    @Bindable var store: ClassesStore
    let city: String
    let theater: String
    @Environment(\.dismiss) private var dismiss

    private var levels: [String] { store.availableLevels(city: city, theater: theater) }

    var body: some View {
        NavigationStack {
            Form {
                if !levels.isEmpty {
                    Section("Level") {
                        Picker("Level", selection: $store.filters.level) {
                            Text("All levels").tag(String?.none)
                            ForEach(levels, id: \.self) { level in
                                Text(level).tag(Optional(level))
                            }
                        }
                    }
                }

                Section {
                    Toggle("Open classes only", isOn: $store.filters.openOnly)
                }

                Section {
                    Button("Clear All Filters", role: .destructive) {
                        store.filters.clear()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(!store.filters.isActive)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sensoryFeedback(.selection, trigger: store.filters)
        }
        .presentationDetents([.medium, .large])
    }
}
