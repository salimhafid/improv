import SwiftUI

// MARK: - First-launch onboarding (two steps: city → theaters)

struct SetupFlowView: View {
    @Bindable var app: AppState
    var onDone: () -> Void

    @State private var step = 1
    @State private var selectedCities: Set<City> = [.newYork]

    var body: some View {
        NavigationStack {
            Group {
                if step == 1 {
                    cityStep
                } else {
                    theaterStep
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .animation(.snappy(duration: 0.25), value: step)
        }
    }

    // MARK: Step 1 — City

    private var cityStep: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Where do you take classes?")
                        .font(.title2.bold())
                    Text("Step 1 of 2 — pick your city, then choose theaters.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .listRowSeparator(.hidden)
            }

            Section {
                ForEach(City.allCases) { city in
                    let isSelected = selectedCities.contains(city)
                    Button {
                        if isSelected {
                            if selectedCities.count > 1 { selectedCities.remove(city) }
                        } else {
                            selectedCities.insert(city)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(city.short)
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(.primary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(city.rawValue)
                                    .font(.body.weight(isSelected ? .semibold : .regular))
                                    .foregroundStyle(.primary)
                                let entries = SourceCatalog.all.filter { $0.city == city }
                                Text("\(entries.count) theaters")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? Theme.accent : Color(.quaternaryLabel))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: selectedCities)
                }
            }
        }
        .navigationTitle("Choose Your City")
        .safeAreaInset(edge: .bottom) {
            Button {
                step = 2
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

    // MARK: Step 2 — Theaters

    private var theaterStep: some View {
        let groups = SourceCatalog.byCity.filter { selectedCities.contains($0.city) }
        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Which theaters?")
                        .font(.title2.bold())
                    Text("Step 2 of 2 — their classes lead your list; others stay a tap away.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .listRowSeparator(.hidden)
            }

            ForEach(groups, id: \.city) { group in
                Section {
                    ForEach(group.entries) { entry in
                        SetupTheaterRow(app: app, id: entry.id, name: entry.name, blurb: entry.blurb)
                    }
                } header: {
                    if groups.count > 1 {
                        Label(group.city.rawValue, systemImage: group.city.symbol)
                    }
                }
            }
        }
        .navigationTitle("Choose Theaters")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { step = 1 } label: {
                    Image(systemName: "chevron.left")
                }
            }
        }
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

    private var isSelected: Bool { app.selectedTheaters.contains(id) }

    var body: some View {
        Button {
            app.toggle(id)
        } label: {
            HStack(spacing: 12) {
                TheaterIcon(id: id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text(blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.accent : Color(.quaternaryLabel))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: app.selectedTheaters)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
