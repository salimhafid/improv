import SwiftUI

/// The pinned, date-sectioned list of show rows. Meant to be placed inside a
/// `LazyVStack(pinnedViews: [.sectionHeaders])` so headers stick. Shared by the
/// Shows feed and Search.
struct ShowSectionsList: View {
    let sections: [DaySection]
    let namespace: Namespace.ID

    var body: some View {
        ForEach(sections) { section in
            Section {
                ForEach(Array(section.shows.enumerated()), id: \.element.id) { index, show in
                    VStack(spacing: 0) {
                        NavigationLink(value: show) { ShowRow(show: show) }
                            .buttonStyle(.plain)
                            .zoomSource(id: show.id, in: namespace)
                        if index < section.shows.count - 1 {
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
