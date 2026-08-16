import SwiftUI

/// Left hamburger drawer listing every theater the app knows, grouped by city
/// (New York, Chicago, Los Angeles). Rows multi-select and the selection is
/// never empty — there is no "All Theaters" scope.
/// Toggling rows scopes the Shows and Classes tabs via `AppState`. Overlays the
/// whole TabView from `RootView` on iPhone; on iPad the inner `TheaterListPanel`
/// is shown as a persistent column instead.
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

/// The sidebar's content: header, then every theater in one list under city
/// sections, with live counts (shows or classes, matching the visible tab).
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
                    ForEach(SourceCatalog.byCity, id: \.city) { group in
                        cityHeader(group.city)
                        ForEach(group.entries) { entry in
                            theaterRow(entry)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        Text("Theaters")
            .font(.title2.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
    }

    private func cityHeader(_ city: City) -> some View {
        HStack(spacing: 6) {
            Image(systemName: city.symbol)
                .font(.caption.weight(.semibold))
            Text(city.rawValue)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    /// Count for a theater in whichever list the user is looking at: class
    /// counts on the Classes tab, show counts everywhere else.
    private func count(for id: String) -> Int? {
        if app.activeTab == 2 {
            return classesStore.sourcesInfo.first { $0.id == id }?.count
        }
        return store.info(for: id)?.count
    }

    private func theaterRow(_ entry: SourceCatalogEntry) -> some View {
        // Availability follows the active tab like count(for:) does — a failed
        // shows scraper must not dim a theater whose classes feed is healthy
        // (an absent classes entry just means "no classes source", not broken).
        let available: Bool
        if app.activeTab == 2 {
            available = classesStore.sourcesInfo.first { $0.id == entry.id }.map(\.ok) ?? true
        } else {
            available = store.isAvailable(entry.id)
        }
        return row(
            id: entry.id,
            title: entry.name,
            subtitle: available ? entry.blurb : "Temporarily unavailable",
            count: count(for: entry.id),
            selected: app.selectedTheaters.contains(entry.id),
            available: available
        ) {
            app.toggle(entry.id)
        }
    }

    private func row(id: String, title: String, subtitle: String, count: Int?,
                     selected: Bool, available: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                TheaterIcon(id: id)
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
