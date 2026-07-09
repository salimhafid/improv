import SwiftUI

/// Left hamburger drawer listing the selected city's theaters. Selecting one
/// scopes both the Shows and Classes tabs to that theater (via `AppState`).
/// Overlays the whole TabView from `RootView`; opened by the hamburger button in
/// each tab's toolbar. A custom drawer (not `NavigationSplitView`, which collapses
/// to a pushed stack on iPhone).
struct TheaterSidebar: View {
    @Environment(AppState.self) private var app
    @Environment(ShowsStore.self) private var store

    private let panelWidth: CGFloat = 290

    var body: some View {
        @Bindable var app = app
        ZStack(alignment: .leading) {
            if app.sidebarOpen {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { app.sidebarOpen = false }

                panel
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.snappy(duration: 0.28), value: app.sidebarOpen)
    }

    /// Close the drawer, then present the city picker, so the sheet doesn't stack
    /// over the still-open drawer.
    private func openCityPicker() {
        app.sidebarOpen = false
        app.showCityPicker = true
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(app.cityTheaters) { entry in
                        theaterRow(entry)
                    }
                }
            }
            Divider()
            Button { openCityPicker() } label: {
                Label("Change City", systemImage: "globe.americas.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
            }
            .foregroundStyle(.primary)
        }
        .frame(width: panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)   // fills to screen edges; content respects safe area
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Theaters")
                .font(.title2.bold())
            Button { openCityPicker() } label: {
                HStack(spacing: 6) {
                    Image(systemName: app.selectedCity.symbol)
                    Text(app.selectedCity.rawValue)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func theaterRow(_ entry: SourceCatalogEntry) -> some View {
        let selected = entry.id == app.selectedTheater
        let count = store.info(for: entry.id)?.count
        return Button {
            app.select(entry.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "theatermasks.fill")
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.body.weight(selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text(entry.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(selected ? Theme.accent.opacity(0.10) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
