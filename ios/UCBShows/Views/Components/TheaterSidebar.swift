import SwiftUI

/// Left hamburger drawer listing the selected city's theaters (plus an
/// "All Theaters" whole-city scope). Selecting one scopes the Shows and Classes
/// tabs via `AppState`. Overlays the whole TabView from `RootView` on iPhone;
/// on iPad the inner `TheaterListPanel` is shown as a persistent column instead.
struct TheaterSidebar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        ZStack(alignment: .leading) {
            if app.sidebarOpen {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { app.sidebarOpen = false }
                    .accessibilityLabel("Close theater list")
                    .accessibilityAddTraits(.isButton)

                TheaterListPanel()
                    .frame(width: 290)
                    .background(.regularMaterial)   // fills to screen edges; content respects safe area
                    .transition(.move(edge: .leading))
                    .accessibilityAction(.escape) { app.sidebarOpen = false }
            }
        }
        .animation(.snappy(duration: 0.28), value: app.sidebarOpen)
    }
}

/// The sidebar's content: header, All Theaters + per-theater rows with live
/// counts (shows or classes, matching the visible tab), and the city switcher.
/// Reused by the iPhone drawer and the persistent iPad column.
struct TheaterListPanel: View {
    @Environment(AppState.self) private var app
    @Environment(ShowsStore.self) private var store
    @Environment(ClassesStore.self) private var classesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    allTheatersRow
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
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Close the drawer, then present the city picker, so the sheet doesn't stack
    /// over the still-open drawer.
    private func openCityPicker() {
        app.sidebarOpen = false
        app.showCityPicker = true
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

    /// Count for a theater in whichever list the user is looking at (the I'm
    /// Going tab keeps showing show counts — it's a shows list too).
    private func count(for id: String) -> Int? {
        if app.activeTab == 2 {
            return classesStore.sourcesInfo.first { $0.id == id }?.count
        }
        return store.info(for: id)?.count
    }

    private var allTheatersRow: some View {
        let total = app.cityTheaters.compactMap { count(for: $0.id) }.reduce(0, +)
        return row(
            title: "All Theaters",
            subtitle: "Everything in \(app.selectedCity.short)",
            symbol: "square.grid.2x2.fill",
            count: total > 0 ? total : nil,
            selected: app.isAllTheaters,
            available: true
        ) {
            app.select(SourceCatalog.allTheatersID)
        }
    }

    private func theaterRow(_ entry: SourceCatalogEntry) -> some View {
        let available = store.isAvailable(entry.id)
        return row(
            title: entry.name,
            subtitle: available ? entry.blurb : "Temporarily unavailable",
            symbol: "theatermasks.fill",
            count: count(for: entry.id),
            selected: entry.id == app.selectedTheater,
            available: available
        ) {
            app.select(entry.id)
        }
    }

    private func row(title: String, subtitle: String, symbol: String, count: Int?,
                     selected: Bool, available: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text(subtitle)
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
            .opacity(available ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
