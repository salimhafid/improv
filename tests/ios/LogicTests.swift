// Standalone logic tests for the pure Swift layer (models, date utils, section
// building). Compiled straight against the app sources — no Xcode test target:
//
//   xcrun swiftc -parse-as-library -o /tmp/improv_logic_tests \
//     ios/UCBShows/Support/DateUtils.swift ios/UCBShows/Support/AppSupport.swift \
//     ios/UCBShows/Models/*.swift ios/UCBShows/Services/FeedService.swift \
//     ios/UCBShows/Services/ShowsStore.swift ios/UCBShows/Services/ClassesStore.swift \
//     tests/ios/LogicTests.swift && /tmp/improv_logic_tests
//
// (run_tests.sh at the repo root does exactly this.)
import Foundation

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition { print("ok   \(label)") } else { failures += 1; print("FAIL \(label)") }
}

func checkEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("ok   \(label)") } else {
        failures += 1
        print("FAIL \(label): got \(got), want \(want)")
    }
}

// MARK: fixtures

func classItem(_ fields: [String: Any]) -> ClassItem {
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return try! JSONDecoder().decode(ClassItem.self, from: data)
}

func show(_ fields: [String: Any]) -> Show {
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return try! JSONDecoder().decode(Show.self, from: data)
}

func ucbClass(_ title: String, source: String = "ucb_ny", level: String = "",
              start: String? = nil) -> ClassItem {
    var f: [String: Any] = ["title": title, "source": source, "level": level,
                            "city": source == "ucb_la" ? "Los Angeles" : "New York",
                            "org": "UCB"]
    if let start { f["start"] = start }
    return classItem(f)
}

// MARK: tests

@MainActor
func testCoreRank() {
    checkEqual(ClassesStore.coreRank(ucbClass("Improv 101")), 0, "coreRank 101")
    checkEqual(ClassesStore.coreRank(ucbClass("Improv 401", source: "ucb_la")), 3, "coreRank 401 LA")
    checkEqual(ClassesStore.coreRank(ucbClass("Weird Title", level: "Improv 201: The Game of the Scene")), 1,
               "coreRank via level prefix")
    checkEqual(ClassesStore.coreRank(ucbClass("Musical Improv 101")), nil, "musical 101 is not core")
    checkEqual(ClassesStore.coreRank(ucbClass("Sketch 101")), nil, "sketch 101 is not core")
    checkEqual(ClassesStore.coreRank(classItem(["title": "Improv 101", "source": "magnet"])), nil,
               "non-UCB source is never core")
}

@MainActor
func testSubjectGroups() {
    // Core Curriculum pinned first, ordered 101→401 with a start-date tiebreak.
    let items = [
        ucbClass("Character 101", level: "Character", start: "2026-08-01T19:00:00"),
        ucbClass("Improv 201", level: "Improv 201: The Game of the Scene", start: "2026-08-05T19:00:00"),
        ucbClass("Improv 101", level: "Improv 101: Improv Basics", start: "2026-09-01T19:00:00"),
        ucbClass("Improv 101", level: "Improv 101: Improv Basics", start: "2026-08-01T19:00:00"),
    ]
    let groups = ClassesStore.subjectGroups(from: items, source: "ucb_ny")
    checkEqual(groups.map(\.id), ["ucb_ny/core", "ucb_ny/Acting & Character"],
               "core group pinned first, ids scoped to the school")
    let core = groups[0]
    checkEqual(core.title, "Core Curriculum", "core group title")
    checkEqual(core.classes.map(\.title), ["Improv 101", "Improv 101", "Improv 201"],
               "core ordered 101→401")
    check(core.classes[0].start == "2026-08-01T19:00:00", "same rank ordered by date")

    let nonUCB = [classItem(["title": "Improv 101", "source": "magnet", "level": "Improv",
                             "city": "New York"])]
    checkEqual(ClassesStore.subjectGroups(from: nonUCB, source: "magnet").map(\.id),
               ["magnet/Improv"], "no core group without UCB core classes")

    // Subject buckets come out in the catalog's fixed order, not input order.
    let mixed = [
        classItem(["title": "Clown One", "source": "brooklyn_cc", "level": "Clown", "city": "New York"]),
        classItem(["title": "Sketch Writing Intensive", "source": "brooklyn_cc", "level": "Sketch", "city": "New York"]),
        classItem(["title": "Musical Improv 101", "source": "brooklyn_cc", "level": "Musical", "city": "New York"]),
        classItem(["title": "House Team Improv", "source": "brooklyn_cc", "level": "Improv", "city": "New York"]),
    ]
    checkEqual(ClassesStore.subjectGroups(from: mixed, source: "brooklyn_cc").map(\.title),
               ["Improv", "Musical Improv", "Sketch & Writing", "Clowning"],
               "subject buckets in fixed order regardless of input order")

    // Within a non-core bucket: date ascending, undated last, title tiebreak.
    let dated = [
        classItem(["title": "Someday Workshop", "source": "magnet", "level": "Improv", "city": "New York"]),
        classItem(["title": "September Jam", "source": "magnet", "level": "Improv",
                   "city": "New York", "start": "2026-09-10T19:00:00"]),
        classItem(["title": "August Jam", "source": "magnet", "level": "Improv",
                   "city": "New York", "start": "2026-08-20T19:00:00"]),
    ]
    checkEqual(ClassesStore.subjectGroups(from: dated, source: "magnet").first?.classes.map(\.title),
               ["August Jam", "September Jam", "Someday Workshop"],
               "non-core bucket sorted by date, undated last")
}

func testClassScope() {
    checkEqual(SourceCatalog.classScope(for: ["ucb_ny"]).sorted(),
               ["brooklyn_cc", "magnet", "ucb_ny", "wgis_ny"],
               "one NY theater scopes classes to every NY school")
    let mixed = SourceCatalog.classScope(for: ["ucb_ny", "annoyance"])
    check(mixed.contains("magnet") && mixed.contains("second_city"),
          "a cross-city pick spans both cities")
    check(!mixed.contains("ucb_la"), "an unpicked city stays out of scope")
    check(SourceCatalog.classScope(for: []).isEmpty,
          "empty selection keeps its no-scoping meaning")
    checkEqual(SourceCatalog.classScope(for: ["nope"]), ["nope"],
               "an unknown id stays alone — it must never widen to everything")
}

func testClassItemDecoding() {
    let minimal = classItem([:])
    checkEqual(minimal.title, "Untitled class", "defensive title default")
    check(minimal.urlString == nil, "empty url -> nil")
    check(!minimal.isFull, "isFull defaults false")

    let c = classItem(["id": "44580", "source": "second_city", "city": "Chicago",
                       "start": "2026-08-29T12:00:00"])
    checkEqual(c.id, "second_city/44580", "id is source-prefixed")
    if let d = c.startDate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        checkEqual(cal.component(.hour, from: d), 12, "start parsed in the class's own city zone")
    } else { check(false, "startDate parsed") }

    let js = classItem(["url": "javascript:alert(1)", "image": "data:text/html,x"])
    check(js.url == nil && js.imageURL == nil, "non-http urls rejected")
}

func testShowDecodingAndDayKey() {
    let ny = show(["title": "Harold Night", "source": "ucb_ny", "city": "New York",
                   "start": "2026-08-01T23:30:00", "has_time": true])
    let chi = show(["title": "Late Jam", "source": "io_chicago", "city": "Chicago",
                    "start": "2026-08-01T23:30:00", "has_time": true])
    checkEqual(ny.dayKey, "2026-08-01", "NY late show buckets on its local day")
    checkEqual(chi.dayKey, "2026-08-01", "Chicago late show buckets on its local day")
    check(ny.startDate != chi.startDate, "same wall-clock in different cities is a different instant")
}

func testDaySectionGrouping() {
    let shows = [
        show(["title": "A", "source": "ucb_ny", "city": "New York",
              "start": "2026-08-01T20:00:00", "has_time": true]),
        show(["title": "B", "source": "ucb_ny", "city": "New York",
              "start": "2026-08-02T20:00:00", "has_time": true]),
        show(["title": "TBA", "source": "ucb_ny", "city": "New York"]),
    ]
    let sections = DaySection.group(shows)
    checkEqual(sections.map { $0.shows.map(\.title) }, [["A"], ["B"], ["TBA"]],
               "days sorted ascending, TBA last")
    checkEqual(sections.last!.title, "Dates to be announced", "TBA section title")
}

func testLossyPayloadDecoding() {
    let raw: [String: Any] = [
        "generated_at": "2026-07-22T12:00:00+00:00",
        "count": 3,
        "sources": [["id": "ucb_ny", "org": "UCB", "city": "New York",
                     "count": 2, "ok": true, "error": NSNull()],
                    ["id": 42]],  // malformed row: id is a number
        "shows": [["title": "Good A", "source": "ucb_ny", "city": "New York"],
                  ["title": ["not", "a", "string"]],  // malformed element
                  ["title": "Good B", "source": "ucb_ny", "city": "New York"]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: raw)
    let payload = try? JSONDecoder().decode(ShowsPayload.self, from: data)
    checkEqual(payload?.shows.map(\.title), ["Good A", "Good B"],
               "one malformed show drops, the rest decode")

    // Multi-paragraph description: the Cast section takes only the
    // "Featuring:" paragraph; later copy (ticket prices) stays out, and the
    // body ends cleanly before the lineup.
    let descRaw: [String: Any] = ["title": "T", "source": "ucb_ny", "city": "New York",
        "description": "Body para one.\n\nBody para two.\n\nFeaturing: Ana One, Ben Two\n\nIn-person tickets are $15."]
    let descData = try! JSONSerialization.data(withJSONObject: descRaw)
    if let show = try? JSONDecoder().decode(Show.self, from: descData) {
        checkEqual(show.detailText, "Body para one.\n\nBody para two.", "body keeps its paragraphs, ends before the lineup")
        checkEqual(show.castLine, "Ana One, Ben Two", "cast bounded at its own paragraph")
    } else {
        check(false, "description fixture decodes")
    }
    // The type-mismatched row drops (Lossy), the good row survives; the
    // payload as a whole must never abort.
    checkEqual(payload?.sources?.map(\.id), ["ucb_ny"],
               "malformed source row drops without aborting the payload")

    let hay = show(["title": "Pérez Presents", "source": "ucb_ny", "city": "New York"])
    check(hay.searchHay.contains("perez presents"), "searchHay folds diacritics + case")
}

func testDateUtils() {
    let chicago = TimeZone(identifier: "America/Chicago")!
    check(DateUtils.parse("2026-08-29T12:00:00", in: chicago) != nil, "timed parse")
    checkEqual(DateUtils.parse("2026-08-14T19:00", in: chicago),
               DateUtils.parse("2026-08-14T19:00:00", in: chicago),
               "minute-precision parse keeps the time (UCB account scrape)")
    check(DateUtils.parse("2026-08-29", in: chicago) != nil, "date-only parse")
    check(DateUtils.parse("garbage", in: chicago) == nil, "garbage -> nil")
    check(DateUtils.parseTimestamp("2026-07-22T14:22:17.189113+00:00") != nil,
          "python 6-digit microseconds timestamp accepted")
    check(DateUtils.parseTimestamp("2026-07-22T14:22:17+00:00") != nil, "plain ISO accepted")

    let noonUTC = DateUtils.parseTimestamp("2026-08-01T12:00:00+00:00")!
    checkEqual(DateUtils.dayKey(noonUTC, in: TimeZone(identifier: "America/Los_Angeles")!),
               "2026-08-01", "dayKey in LA")
    // 3am UTC on the 2nd is still the evening of the 1st in LA.
    let lateUTC = DateUtils.parseTimestamp("2026-08-02T03:00:00+00:00")!
    checkEqual(DateUtils.dayKey(lateUTC, in: TimeZone(identifier: "America/Los_Angeles")!),
               "2026-08-01", "dayKey respects venue zone across midnight UTC")
}

func testReminderPlan() {
    let ny = TimeZone(identifier: "America/New_York")!
    let start = DateUtils.parse("2026-08-14T19:00:00", in: ny)!

    // An hour before showtime, and nothing at all once that moment has passed.
    checkEqual(ReminderPlan.fireDate(forStart: start, now: start.addingTimeInterval(-7200)),
               start.addingTimeInterval(-3600), "reminder fires an hour before showtime")
    check(ReminderPlan.fireDate(forStart: start, now: start.addingTimeInterval(-1800)) == nil,
          "no reminder inside the last hour")
    check(ReminderPlan.fireDate(forStart: start, now: start.addingTimeInterval(3600)) == nil,
          "no reminder after the show started")

    // Ticket ↔ hearted-show dedup: same night out, allowing for the feed and
    // the account page rounding the showtime differently.
    check(ReminderPlan.sameEvent("The Prophecy", start,
                                 "the prophecy", start.addingTimeInterval(30)),
          "sameEvent matches case-insensitively within a minute")
    check(!ReminderPlan.sameEvent("The Prophecy", start,
                                  "The Prophecy", start.addingTimeInterval(86400)),
          "sameEvent rejects the same title a night later")
    check(!ReminderPlan.sameEvent("The Prophecy", start, "ASSSSCAT", start),
          "sameEvent rejects a different show at the same time")
    check(!ReminderPlan.sameEvent("The Prophecy", nil, "The Prophecy", start),
          "sameEvent needs both starts")

    // Reserve-time join: same title on the same venue-local night.
    let later = DateUtils.parse("2026-08-14T21:30:00", in: ny)!
    check(ReminderPlan.sameBooking(ticketTitle: "ASSSSCAT", ticketStart: start,
                                   showTitle: "asssscat", showStart: later, in: ny),
          "sameBooking matches a different showtime on the same night")
    check(!ReminderPlan.sameBooking(ticketTitle: "ASSSSCAT", ticketStart: start,
                                    showTitle: "ASSSSCAT",
                                    showStart: start.addingTimeInterval(7 * 86400), in: ny),
          "sameBooking rejects next week's run of the same show")
    check(ReminderPlan.sameBooking(ticketTitle: "ASSSSCAT", ticketStart: nil,
                                   showTitle: "ASSSSCAT", showStart: later, in: ny),
          "sameBooking falls back to the title when UCB's meta line didn't parse")
}

func testReminderCoverage() {
    let ny = TimeZone(identifier: "America/New_York")!
    let start = DateUtils.parse("2026-08-14T19:00:00", in: ny)!

    // In-app reserve stamps the join, so the id alone suppresses the heart.
    let joined = ReminderCoverage(showIDs: ["ucb_ny/the-prophecy"])
    check(joined.covers(showID: "ucb_ny/the-prophecy", title: "The Prophecy", start: start),
          "a ticket with the show id covers that show")
    check(!joined.covers(showID: "ucb_ny/asssscat", title: "ASSSSCAT", start: start),
          "coverage doesn't leak to other shows")

    // Website-reserved tickets carry no id — title + start still covers a show
    // hearted after the ticket was found.
    let scraped = ReminderCoverage(events: [.init(title: "The Prophecy", start: start)])
    check(scraped.covers(showID: "ucb_ny/the-prophecy", title: "the prophecy",
                         start: start.addingTimeInterval(30)),
          "a website-reserved ticket covers the matching show by title + start")
    check(!scraped.covers(showID: "ucb_ny/the-prophecy", title: "The Prophecy",
                          start: start.addingTimeInterval(86400)),
          "a website-reserved ticket doesn't cover another night of the same show")
    check(!scraped.covers(showID: "ucb_ny/the-prophecy", title: "The Prophecy", start: nil),
          "an undated show is never covered by title alone")

    // Releasing the ticket empties coverage, which is what restores the heart's
    // own reminder.
    check(!ReminderCoverage().covers(showID: "ucb_ny/the-prophecy",
                                     title: "The Prophecy", start: start),
          "empty coverage suppresses nothing")
}

@main
struct LogicTests {
    static func main() async {
        await testCoreRank()
        await testSubjectGroups()
        testClassScope()
        testClassItemDecoding()
        testShowDecodingAndDayKey()
        testDaySectionGrouping()
        testLossyPayloadDecoding()
        testDateUtils()
        testReminderPlan()
        testReminderCoverage()
        await testClassesLayoutMemo()
        await testSearchByteParity()
        await testSchoolFolderOrder()
        await testPickedTheaterWithNoClasses()
        print(failures == 0 ? "\nALL SWIFT LOGIC TESTS PASSED" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}

// MARK: Classes tab layout (memoization, search, folder order)

func classesPayload(_ items: [[String: Any]]) -> ClassesPayload {
    let data = try! JSONSerialization.data(withJSONObject: ["classes": items])
    return try! JSONDecoder().decode(ClassesPayload.self, from: data)
}

private let nyClasses: [[String: Any]] = [
    ["title": "Improv 101", "source": "ucb_ny", "level": "Improv 101",
     "city": "New York", "org": "UCB", "instructor": "Renée Márquez"],
    ["title": "Musical Improv 201", "source": "ucb_ny", "level": "Musical Improv 201",
     "city": "New York", "org": "UCB"],
    ["title": "Level One", "source": "magnet", "city": "New York", "org": "Magnet Theater",
     "description": "Clown work and play"],
    ["title": "Sketch Writing", "source": "brooklyn_cc", "city": "New York",
     "org": "Brooklyn Comedy Collective"],
]

@MainActor
func testClassesLayoutMemo() {
    let store = ClassesStore()
    store.apply(classesPayload(nyClasses))

    let first = store.schoolFolders(theaters: ["magnet"])
    let builds = store.layoutBuildCount
    let second = store.schoolFolders(theaters: ["magnet"])
    checkEqual(store.layoutBuildCount, builds, "repeating a layout call is a memo hit")
    check(first == second, "the memoized layout is identical")

    _ = store.schoolFolders(theaters: ["magnet"], searchText: "improv")
    check(store.layoutBuildCount > builds, "a new query misses the memo")

    _ = store.schoolFolders(theaters: ["magnet"])
    let beforeApply = store.layoutBuildCount
    store.apply(classesPayload([nyClasses[0]]))
    let afterApply = store.schoolFolders(theaters: ["magnet"])
    check(store.layoutBuildCount > beforeApply, "a feed apply invalidates the memo")
    check(afterApply != first, "the rebuilt layout reflects the new feed")
}

@MainActor
func testSearchByteParity() {
    let items = nyClasses.map { classItem($0) }
    for raw in ["improv", "musical", "clown", "Renée", "renee", "perez presents", "", "  "] {
        let query = ClassesStore.normalizedQuery(raw)
        let needle = Array(query.utf8)
        for item in items {
            // Both sides are already diacritic-folded and lowercased, so the
            // byte scan has to agree with String.contains on every item.
            let want = query.isEmpty ? true : item.searchHay.contains(query)
            checkEqual(ClassesStore.containsBytes(item.searchBytes, needle), want,
                       "byte scan matches String.contains for \"\(raw)\" in \(item.title)")
        }
    }
}

@MainActor
func testSchoolFolderOrder() {
    let store = ClassesStore()
    store.apply(classesPayload(nyClasses))

    let magnet = store.schoolFolders(theaters: ["magnet"])
    checkEqual(magnet.selected.map(\.id).first, "magnet", "a picked non-UCB theater leads its city")
    let ucb = store.schoolFolders(theaters: ["ucb_ny"])
    checkEqual(ucb.selected.map(\.id).first, "ucb_ny", "the default theater still leads")
    // The reorder animation is keyed on orderKey, so it has to move with order.
    check(magnet.orderKey != ucb.orderKey, "orderKey changes when the folder order does")
    checkEqual(magnet.orderKey, magnet.selected.map(\.id).joined(separator: "|"),
               "orderKey is the folder id sequence")
}

@MainActor
func testPickedTheaterWithNoClasses() {
    let store = ClassesStore()
    store.apply(classesPayload([
        ["title": "Improv Level 1", "source": "second_city", "city": "Chicago", "org": "The Second City"],
        ["title": "Art of Slack", "source": "annoyance", "city": "Chicago", "org": "The Annoyance"],
    ]))

    // Logan Square has shows but no classes in the feed; picking it used to
    // make the chosen theater silently vanish from the list.
    let picked = store.schoolFolders(theaters: ["logan_square"])
    let ids = picked.selected.map(\.id)
    check(ids.contains("logan_square"), "a picked theater with no classes still gets a folder")
    checkEqual(ids.first, "logan_square", "...and it still leads its city")
    checkEqual(picked.selected.first { $0.id == "logan_square" }?.count, 0, "...reporting zero classes")
    check(picked.selected.first { $0.id == "logan_square" }?.subjects.isEmpty == true,
          "...with no subject groups, so the card renders inert")

    let searching = store.schoolFolders(theaters: ["logan_square"], searchText: "improv")
    check(!searching.selected.contains { $0.id == "logan_square" },
          "an empty picked folder is suppressed during a search")

    // An unpicked empty theater is still dropped.
    check(!picked.selected.contains { $0.id == "playground" },
          "an unpicked theater with no classes stays out of the list")
}
