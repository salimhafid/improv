import SwiftUI

/// The pinned, date-sectioned list of show rows. Meant to be placed inside a
/// `LazyVStack(pinnedViews: [.sectionHeaders])` so headers stick. Shared by the
/// Shows feed and the Tickets tab's "I'm Going" list.
struct ShowSectionsList: View {
    let sections: [DaySection]
    let namespace: Namespace.ID
    var showsCityTags = false

    var body: some View {
        ForEach(sections) { section in
            Section {
                // Iterating the array directly, not `Array(enumerated())`: that
                // copied every section on each body evaluation purely to decide
                // whether to draw a divider (same reasoning as ClassesView).
                ForEach(section.shows) { show in
                    VStack(spacing: 0) {
                        NavigationLink(value: show) { ShowRow(show: show, showsCityTag: showsCityTags) }
                            .buttonStyle(.plain)
                            .zoomSource(id: show.id, in: namespace)
                        if show.id != section.shows.last?.id {
                            Divider().padding(.leading, 104)
                        }
                    }
                    .padding(.horizontal, Theme.Space.gutter)
                }
            } header: {
                SectionHeaderView(title: section.title)
            }
        }
    }
}
