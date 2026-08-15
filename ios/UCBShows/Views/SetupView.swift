import SwiftUI

// MARK: - First-launch onboarding (pick a theater)

/// One-step first-launch setup: pick your home theater (or All Theaters) from
/// the full list, grouped by city. Persists via `AppState`; changing theaters
/// later from the sidebar simply overwrites the saved selection.
struct SetupFlowView: View {
    @Bindable var app: AppState
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Welcome to Improv")
                            .font(.title2.bold())
                        Text("Pick your home theater — you can select any mix of theaters later from the sidebar.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .listRowSeparator(.hidden)
                }

                ForEach(SourceCatalog.byCity, id: \.city) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            SetupTheaterRow(
                                app: app,
                                id: entry.id,
                                name: entry.name,
                                blurb: entry.blurb
                            )
                        }
                    } header: {
                        Label(group.city.rawValue, systemImage: group.city.symbol)
                    }
                }
            }
            .navigationTitle("Choose Your Theater")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    onDone()
                } label: {
                    Text("Get Started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
    }
}

private struct SetupTheaterRow: View {
    @Bindable var app: AppState
    let id: String
    let name: String
    let blurb: String

    var body: some View {
        let selected = app.selectedTheaters == [id]
        Button {
            app.select(id)
        } label: {
            HStack(spacing: 12) {
                TheaterIcon(id: id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body.weight(selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text(blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: app.selectedTheaters)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
