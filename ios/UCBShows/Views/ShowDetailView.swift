import SwiftUI

/// The show detail: stretchy poster header, metadata, blurb, and a pinned
/// bottom bar with an "I'm Going" heart and a Get Tickets button that opens the
/// ticket page in an in-app Safari sheet.
struct ShowDetailView: View {
    let show: Show
    let namespace: Namespace.ID

    @Environment(\.dismiss) private var dismiss
    @Environment(GoingStore.self) private var going
    @Environment(TalentStore.self) private var talent
    @State private var webLink: WebLink?
    @State private var calendarMessage: String?
    @State private var showCalendarAlert = false

    /// The talent directory only covers UCB New York.
    private var hasTalentDirectory: Bool { show.source == "ucb_ny" }

    var body: some View {
        ZStack(alignment: .top) {
            ambient.ignoresSafeArea()

            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    StretchyPoster(show: show)

                    VStack(alignment: .leading, spacing: 16) {
                        Text(show.title)
                            .font(.largeTitle.bold())
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 6) {
                            Label(show.dateRaw.isEmpty ? show.timeLabel : show.dateRaw,
                                  systemImage: "calendar")
                            // Only show a map-pin for a real physical venue; a
                            // venue-less livestream is already conveyed by the chip.
                            if !show.venue.isEmpty {
                                Label(show.shortVenue, systemImage: "mappin.and.ellipse")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                        chips

                        if !show.detailText.isEmpty {
                            Text(show.detailText)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .padding(.top, 2)
                                .textSelection(.enabled)
                        }

                        if show.hasCast {
                            castSection
                                .id("cast")
                        }
                    }
                    .padding(Theme.Space.gutter)
                }
            }
            .onAppear {
                // DEBUG-only: scroll the cast section into view for
                // verification screenshots (UITEST_SCROLL_CAST=1).
                guard ProcessInfo.processInfo.uiTestScrollCast else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { proxy.scrollTo("cast", anchor: .center) }
                }
            }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: TalentRoute.self) { route in
            switch route {
            case .person(let person):
                TalentBioView(person: person)
            case .directory(let initialSearch):
                TalentDirectoryView(initialSearch: initialSearch)
            }
        }
        .zoomDestination(id: show.id, in: namespace)
        .toolbar {
            if show.startDate != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addToCalendar()
                    } label: {
                        Image(systemName: "calendar.badge.plus")
                    }
                    .accessibilityLabel("Add to Calendar")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let url = show.url {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                } else {
                    ShareLink(item: show.title) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(item: $webLink) { link in
            SafariView(url: link.url).ignoresSafeArea()
        }
        .alert(calendarMessage ?? "", isPresented: $showCalendarAlert) {
            Button("OK", role: .cancel) {}
        }
        .onSwipeRight { dismiss() }   // swipe L→R anywhere goes back to the feed
    }

    private func addToCalendar() {
        Task {
            do {
                try await CalendarService.add(show)
                calendarMessage = "Added to your calendar."
            } catch {
                calendarMessage = error.localizedDescription
            }
            showCalendarAlert = true
        }
    }

    // MARK: Cast

    /// Cast section. For UCB New York, each name is tappable: matched names
    /// push the performer's bio; unmatched ones open the directory pre-searched.
    /// Other theaters keep the plain text line.
    private var castSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Cast", systemImage: "person.2.fill")
                .font(.headline)
                .foregroundStyle(.primary)

            if hasTalentDirectory, !show.castMembers.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(show.castMembers, id: \.self) { name in
                        castChip(name)
                    }
                }
                NavigationLink(value: TalentRoute.directory(initialSearch: "")) {
                    HStack(spacing: 4) {
                        Text("Browse UCB Talent Directory")
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                }
                .padding(.top, 2)
            } else {
                Text(show.castLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func castChip(_ name: String) -> some View {
        let match = talent.person(named: name)
        NavigationLink(value: match.map(TalentRoute.person)
                        ?? TalentRoute.directory(initialSearch: name)) {
            HStack(spacing: 4) {
                Text(name)
                if match != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(match != nil ? Theme.accent : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background((match != nil ? Theme.accent : Color.secondary).opacity(0.12),
                        in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Pieces

    private var chips: some View {
        ViewThatFits(in: .horizontal) {
            chipRow
            ScrollView(.horizontal, showsIndicators: false) { chipRow }
        }
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            MetaChip(text: show.sourceLabel, systemImage: "building.2", tint: Theme.accent)
            ForEach(show.comedyTypes, id: \.self) { type in
                MetaChip(text: type, systemImage: Theme.symbol(forType: type),
                         tint: Theme.tint(forType: type))
            }
            if show.isLivestream {
                MetaChip(text: "Livestream", systemImage: "dot.radiowaves.left.and.right",
                         tint: Theme.accent)
            }
            if show.isFree {
                MetaChip(text: "Free", systemImage: "tag", tint: .green)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            goingButton
            if let url = show.url {
                Button {
                    webLink = WebLink(url: url)
                } label: {
                    Label(show.isFree ? "Reserve · Free" : "Get Tickets", systemImage: "ticket.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// The "I'm Going" heart — saves the show to the I'm Going tab and schedules
    /// a pre-show reminder.
    private var goingButton: some View {
        let isGoing = going.isGoing(show)
        return Button {
            going.toggle(show)
        } label: {
            Image(systemName: isGoing ? "heart.fill" : "heart")
                .font(.headline)
                .symbolEffect(.bounce, value: isGoing)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .sensoryFeedback(.impact, trigger: isGoing)
        .accessibilityLabel(isGoing ? "Remove from I'm Going" : "I'm Going")
    }

    private var ambient: some View {
        LinearGradient(
            colors: [
                Color(hue: show.seedHue, saturation: 0.35, brightness: 0.62).opacity(0.20),
                Color(.systemBackground),
            ],
            startPoint: .top, endPoint: .center
        )
    }
}

/// Full-width ~2:1 poster that stretches on overscroll, mirroring Weather/Music.
private struct StretchyPoster: View {
    let show: Show
    private let baseHeight: CGFloat = 240

    var body: some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .global).minY
            let stretch = max(0, minY)
            Color.clear
                .overlay { PosterImage(show: show) }
                .frame(width: geo.size.width, height: baseHeight + stretch)
                .clipped()
                .offset(y: -stretch)
        }
        .frame(height: baseHeight)
        .accessibilityHidden(true)
    }
}
