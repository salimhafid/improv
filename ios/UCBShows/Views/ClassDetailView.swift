import SwiftUI

/// Native class detail: header image (or tinted glyph banner), metadata,
/// the full scraped description, and a pinned Register bar that opens the
/// registration page in an in-app Safari sheet. Each instructor's name is a
/// link: their UCB bio page when the talent directory knows them, otherwise
/// a Google search for "<name> + <theater>".
struct ClassDetailView: View {
    let item: ClassItem

    @Environment(\.dismiss) private var dismiss
    @Environment(TalentStore.self) private var talent
    @State private var webLink: WebLink?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                VStack(alignment: .leading, spacing: 16) {
                    Text(item.title)
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        if !item.instructorNames.isEmpty {
                            Label {
                                instructorLinks
                            } icon: {
                                Image(systemName: "person.fill")
                            }
                        }
                        if !item.schedule.isEmpty {
                            Label(item.schedule, systemImage: "calendar")
                        }
                        if !item.price.isEmpty {
                            Label(item.price, systemImage: "tag")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    chips

                    if !item.classDescription.isEmpty {
                        Text(item.classDescription)
                            .font(.body)
                            .padding(.top, 2)
                            .textSelection(.enabled)
                    }
                }
                .padding(Theme.Space.gutter)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(item: $webLink) { link in
            SafariView(url: link.url).ignoresSafeArea()
        }
        .onSwipeRight { dismiss() }   // swipe L→R anywhere goes back to the list
    }

    // MARK: Pieces

    @ViewBuilder
    private var header: some View {
        if let url = item.imageURL {
            AsyncImage(url: url,
                       transaction: Transaction(animation: .easeInOut(duration: 0.25))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    glyphBanner
                }
            }
            .frame(height: 200)
            .clipped()
            .accessibilityHidden(true)
        } else {
            glyphBanner
                .frame(height: 140)
                .accessibilityHidden(true)
        }
    }

    private var glyphBanner: some View {
        ZStack {
            Theme.accent.opacity(0.14)
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
    }

    /// One link per teacher, wrapping like the cast chips on a show page.
    private var instructorLinks: some View {
        let names = item.instructorNames
        return FlowLayout(spacing: 4) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                instructorLink(name, comma: index < names.count - 1)
            }
        }
    }

    /// The same bio page a show's cast chip opens (headshot, UCB bio, their
    /// shows, the full ucbcomedy.com profile) when the directory has this
    /// name; a Google search in the in-app Safari sheet when it doesn't. The
    /// directory is UCB's, so a teacher at another school who also performs
    /// at UCB opens that UCB bio too.
    @ViewBuilder
    private func instructorLink(_ name: String, comma: Bool) -> some View {
        let label = HStack(spacing: 0) {
            Text(name).foregroundStyle(ClassItem.isPlaceholderInstructor(name) ? Color.secondary : Theme.accent)
            if comma { Text(",") }
        }
        if ClassItem.isPlaceholderInstructor(name) {
            label.foregroundStyle(.secondary)   // "Teacher TBD": nobody to look up
        } else if let person = talent.instructor(named: name) {
            NavigationLink(value: TalentRoute.person(person)) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityHint("Opens their UCB bio")
        } else if let url = ClassItem.instructorSearchURL(name: name, theater: item.org) {
            Button { webLink = WebLink(url: url) } label: { label }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityHint("Searches Google for \(name) and \(item.org)")
        } else {
            label
        }
    }

    private var chips: some View {
        ViewThatFits(in: .horizontal) {
            chipRow
            ScrollView(.horizontal, showsIndicators: false) { chipRow }
        }
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            MetaChip(text: item.sourceLabel, systemImage: "building.2", tint: Theme.accent)
            if !item.level.isEmpty {
                MetaChip(text: item.level, systemImage: "graduationcap", tint: Theme.accent)
            }
            if item.isFull {
                MetaChip(text: "Full", systemImage: "person.2.slash", tint: .secondary)
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let url = item.url {
            Button {
                webLink = WebLink(url: url)
            } label: {
                Label(item.isFull ? "View Class · Full" : "Register",
                      systemImage: item.isFull ? "person.2.slash" : "graduationcap.fill")
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
