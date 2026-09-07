import SwiftUI

/// Sheet for refining the show list within the current theater scope: venue,
/// comedy types, livestream/free, and a date window. Binds directly to the
/// store so changes apply live. (Theaters are chosen in the sidebar — so
/// they're not filters here.)
struct FilterSheet: View {
    @Bindable var store: ShowsStore
    let theaters: Set<String>
    @Environment(\.dismiss) private var dismiss

    private var venues: [String] { store.availableVenues(theaters: theaters) }
    private var types: [String] { store.availableTypes(theaters: theaters) }

    var body: some View {
        NavigationStack {
            Form {
                // Also shown when a venue filter is set with only one venue
                // available: an active filter must never be invisible (a
                // theater with one named stage still has venue-less shows
                // that the filter drops).
                if venues.count > 1 || store.filters.venue != nil {
                    Section("Venue") {
                        Picker("Venue", selection: $store.filters.venue) {
                            Text("All venues").tag(String?.none)
                            ForEach(venues, id: \.self) { venue in
                                Text(Show.cleanVenueName(venue))
                                    .tag(Optional(venue))
                            }
                        }
                    }
                }

                if !types.isEmpty {
                    Section("Comedy type") {
                        ForEach(types, id: \.self) { type in
                            let selected = store.filters.comedyTypes.contains(type)
                            Button {
                                toggle(type)
                            } label: {
                                HStack {
                                    Image(systemName: Theme.symbol(forType: type))
                                        .foregroundStyle(Theme.tint(forType: type))
                                        .frame(width: 26)
                                    Text(type).foregroundStyle(.primary)
                                    Spacer()
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.accent)
                                            .fontWeight(.semibold)
                                    }
                                }
                            }
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                        }
                    }
                }

                Section {
                    Toggle("Livestream available", isOn: $store.filters.livestreamOnly)
                    Toggle("Free shows", isOn: $store.filters.freeOnly)
                }

                Section("When") {
                    Picker("Date", selection: $store.filters.dateWindow) {
                        ForEach(Filters.DateWindow.allCases) { window in
                            Text(window.title).tag(window)
                        }
                    }
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

    private func toggle(_ type: String) {
        if store.filters.comedyTypes.contains(type) {
            store.filters.comedyTypes.remove(type)
        } else {
            store.filters.comedyTypes.insert(type)
        }
    }
}
