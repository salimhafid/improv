import SwiftUI

// MARK: - First-launch onboarding (city → theater)

/// Two-step first-launch setup: pick your city, then pick your default theater
/// (or All Theaters) in that city. Both persist via `AppState`; changing the
/// theater later from the sidebar simply overwrites the saved default.
struct SetupFlowView: View {
    @Bindable var app: AppState
    var onDone: () -> Void

    @State private var showTheaterStep = false

    var body: some View {
        NavigationStack {
            cityStep
                .navigationDestination(isPresented: $showTheaterStep) {
                    theaterStep
                }
        }
        .modifier(UITestOnboardingAdvance(showTheaterStep: $showTheaterStep))
    }

    // MARK: Step 1 — city

    private var cityStep: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Improv")
                        .font(.title2.bold())
                    Text("Pick the city you're in — you can change it anytime.")
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
        .navigationTitle("Choose Your City")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                showTheaterStep = true
            } label: {
                Text("Continue")
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

    // MARK: Step 2 — theater

    private var theaterStep: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Where do you usually go?")
                        .font(.title2.bold())
                    Text("Shows and classes open to this theater by default. Switch anytime from the sidebar.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .listRowSeparator(.hidden)
            }

            Section {
                SetupTheaterRow(
                    app: app,
                    id: SourceCatalog.allTheatersID,
                    name: "All Theaters",
                    blurb: "Everything in \(app.selectedCity.short)",
                    symbol: "square.grid.2x2.fill"
                )
                ForEach(app.cityTheaters) { entry in
                    SetupTheaterRow(
                        app: app,
                        id: entry.id,
                        name: entry.name,
                        blurb: entry.blurb,
                        symbol: "theatermasks.fill"
                    )
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

private struct SetupTheaterRow: View {
    @Bindable var app: AppState
    let id: String
    let name: String
    let blurb: String
    let symbol: String

    var body: some View {
        let selected = app.selectedTheater == id
        Button {
            app.selectedTheater = id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                    .frame(width: 26)
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
        .sensoryFeedback(.selection, trigger: app.selectedTheater)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// DEBUG-only: jump straight to the theater step (UITEST_ONBOARDING=2) for
/// verification screenshots. No-op in release.
private struct UITestOnboardingAdvance: ViewModifier {
    @Binding var showTheaterStep: Bool

    func body(content: Content) -> some View {
        #if DEBUG
        content.onAppear {
            if ProcessInfo.processInfo.environment["UITEST_ONBOARDING"] == "2" {
                showTheaterStep = true
            }
        }
        #else
        content
        #endif
    }
}

// MARK: - Change City (sheet from the sidebar)

/// City selector shown from the sidebar's "Change City". The saved theater is
/// kept when it's still valid for the chosen city (All Theaters always is);
/// otherwise it falls back to the city's first theater.
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
                        Text("Pick the city you're in. You'll see its theaters in the sidebar and can switch theaters anytime.")
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

struct CityRow: View {
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
