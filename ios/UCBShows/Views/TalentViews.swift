import SwiftUI

/// Navigation routes for the talent flow, pushed from a UCB NY show's cast
/// section (and from directory rows).
enum TalentRoute: Hashable {
    case person(TalentPerson)
    case directory(initialSearch: String)
}

// MARK: - Bio

/// A performer's page: headshot, name, group tags, and the full bio on
/// ucbcomedy.com in an in-app Safari sheet.
struct TalentBioView: View {
    let person: TalentPerson

    @State private var webLink: WebLink?

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

                HStack(spacing: 8) {
                    ForEach(person.groupLabels, id: \.self) { label in
                        MetaChip(text: label, systemImage: symbol(for: label), tint: Theme.accent)
                    }
                }

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

    private func symbol(for label: String) -> String {
        switch label {
        case "Teacher": return "graduationcap"
        case "DCM":     return "star"
        default:        return "theatermasks"
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
        ("All", nil), ("NY Cast", "ny"), ("LA Cast", "la"),
        ("DCM", "dcm"), ("Teachers", "teachers"),
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
                Text(person.groupLabels.joined(separator: " · "))
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
