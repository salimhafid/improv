import SwiftUI

/// Native class detail: header image (or tinted glyph banner), metadata,
/// the full scraped description, and a pinned Register bar that opens the
/// registration page in an in-app Safari sheet.
struct ClassDetailView: View {
    let item: ClassItem

    @Environment(\.dismiss) private var dismiss
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
                        if !item.instructor.isEmpty {
                            Label(item.instructor, systemImage: "person.fill")
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
