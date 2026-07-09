import SwiftUI

/// The "I'm Going" tab — the user's saved shows across every city and theater,
/// grouped by date. Shows are added from the heart button on a show's page.
struct GoingView: View {
    @Environment(GoingStore.self) private var going
    @State private var path: [Show] = []
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if going.shows.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("I’m Going")
            .navigationDestination(for: Show.self) { show in
                ShowDetailView(show: show, namespace: zoom)
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.section,
                       pinnedViews: [.sectionHeaders]) {
                ShowSectionsList(sections: DaySection.group(going.shows), namespace: zoom)
            }
            .padding(.top, Theme.Space.gutter)
            .padding(.bottom, Theme.Space.section)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Shows Saved", systemImage: "heart")
        } description: {
            Text("Tap the heart on a show’s page and it’ll show up here, with a reminder before showtime.")
        }
    }
}
