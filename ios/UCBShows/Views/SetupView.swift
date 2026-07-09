import SwiftUI

/// City selector: choose your home city. The whole app is scoped to it, and the
/// theater sidebar lists that city's theaters. Shown on first launch (onboarding)
/// and reachable anytime from the theater sidebar ("Change City").
struct SetupView: View {
    @Bindable var app: AppState
    var isOnboarding = false
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Choose your city")
                            .font(.title3.bold())
                        Text("Pick the city you’re in. You’ll see its theaters in the sidebar and can switch theaters anytime. Change your city here whenever you like.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .listRowSeparator(.hidden)
                }

                Section {
                    ForEach(City.allCases) { city in
                        CityRow(app: app, city: city)
                    }
                }
            }
            .navigationTitle("City")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isOnboarding ? "Continue" : "Done", action: onDone)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct CityRow: View {
    @Bindable var app: AppState
    let city: City

    var body: some View {
        let selected = app.selectedCity == city
        let count = SourceCatalog.all.filter { $0.city == city }.count

        Button {
            app.selectedCity = city
        } label: {
            HStack(spacing: 12) {
                Image(systemName: city.symbol)
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(city.rawValue)
                        .foregroundStyle(.primary)
                    Text("\(count) theater\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .sensoryFeedback(.selection, trigger: app.selectedCity)
    }
}
