import SwiftUI

/// Navigation routes for the talent flow, pushed from a UCB NY show's cast
/// section (and from directory rows).
enum TalentRoute: Hashable {
    case person(TalentPerson)
    case directory(initialSearch: String)
}

// MARK: - Bio

/// A performer's page: headshot, name, city tag, their scraped bio, their
/// upcoming shows from the feed (each links to the show page in-app), and the
/// full profile on ucbcomedy.com in an in-app Safari sheet.
struct TalentBioView: View {
    let person: TalentPerson

    @Environment(ShowsStore.self) private var shows
    @State private var webLink: WebLink?
    @Namespace private var zoom

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headshot
                    .frame(width: 180, height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .padding(.top, 24)

                Text(person.name)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                MetaChip(text: person.cityLabel, systemImage: "theatermasks", tint: Theme.accent)

                if !person.bio.isEmpty {
                    Text(person.bio)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }

                upcomingShows

                NavigationLink(value: TalentRoute.directory(initialSearch: "")) {
                    Label("Browse UCB Talent", systemImage: "person.3")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(Theme.Space.gutter)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(item: $webLink) { link in
            SafariView(url: link.url).ignoresSafeArea()
        }
    }

    /// Feed shows whose cast includes this person — exact slug match when the
    /// show has structured cast, name match otherwise — soonest first.
    private var matchingShows: [Show] {
        let key = TalentPerson.nameKey(person.name)
        return shows.allShows
            .filter { show in
                show.castEntries.contains {
                    $0.slug == person.slug || TalentPerson.nameKey($0.name) == key
                }
            }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    @ViewBuilder
    private var upcomingShows: some View {
        let upcoming = matchingShows
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("Upcoming Shows", systemImage: "calendar")
                    .font(.headline)
                    .padding(.bottom, 4)
                ForEach(upcoming.prefix(8)) { show in
                    NavigationLink(value: show) {
                        ShowRow(show: show)
                    }
                    .buttonStyle(.plain)
                    if show.id != upcoming.prefix(8).last?.id {
                        Divider().padding(.leading, 104)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var headshot: some View {
        if let url = person.imageURL {
            AsyncImage(url: url,
                       transaction: Transaction(animation: .easeInOut(duration: 0.25))) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Theme.accent.opacity(0.12)
            Image(systemName: "person.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent.opacity(0.6))
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let url = person.url {
            Button {
                webLink = WebLink(url: url)
            } label: {
                Label("View Full Bio", systemImage: "text.book.closed")
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

// MARK: - Directory

/// The searchable UCB talent directory (NY performers, DCM talent, teachers),
/// reached from a show's cast section.
struct TalentDirectoryView: View {
    var initialSearch = ""

    @Environment(TalentStore.self) private var talent
    @State private var query = ""
    @State private var group: String?

    private let filters: [(label: String, tag: String?)] = [
        ("All", nil), ("New York", "ny"), ("Los Angeles", "la"),
    ]

    var body: some View {
        Group {
            let people = talent.people(matching: query, group: group)
            if !talent.loaded {
                ContentUnavailableView("Loading Talent…", systemImage: "person.3")
            } else if people.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(people) { person in
                    NavigationLink(value: TalentRoute.person(person)) {
                        TalentRow(person: person)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("UCB Talent")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search performers & teachers")
        .safeAreaInset(edge: .top) { filterBar }
        .onAppear {
            if query.isEmpty { query = initialSearch }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.label) { f in
                    Button {
                        group = f.tag
                    } label: {
                        Text(f.label)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(group == f.tag ? Theme.accent.opacity(0.15) : Color(.secondarySystemBackground),
                                        in: Capsule())
                            .foregroundStyle(group == f.tag ? Theme.accent : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

private struct TalentRow: View {
    let person: TalentPerson

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let url = person.imageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        default: Rectangle().fill(.quaternary)
                        }
                    }
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay { Image(systemName: "person.fill").foregroundStyle(.tertiary) }
                }
            }
            .frame(width: 44, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(person.cityLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Flow layout for cast chips

/// Minimal left-aligned wrapping layout for the cast-name chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
