// Standalone logic tests for the pure Swift layer (models, date utils, section
// building). Compiled straight against the app sources — no Xcode test target.
// The compile line (which app files are in, in what order) lives in
// run_tests.sh at the repo root; run that rather than copying it here.
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

/// The harness clock: 2026-07-31 12:00 in New York (11:00 Chicago, 09:00 LA).
/// Every dated fixture below is in August 2026, so it stays "upcoming" no
/// matter when the suite runs, and nothing here can straddle a real midnight.
let fixedNow = DateUtils.parseTimestamp("2026-07-31T16:00:00+00:00")!

func classItem(_ fields: [String: Any]) -> ClassItem {
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return try! JSONDecoder().decode(ClassItem.self, from: data)
}

func show(_ fields: [String: Any]) -> Show {
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return try! JSONDecoder().decode(Show.self, from: data)
}

func talentPerson(_ fields: [String: Any]) -> TalentPerson {
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return try! JSONDecoder().decode(TalentPerson.self, from: data)
}

func ucbClass(_ title: String, source: String = "ucb_ny", level: String = "",
              start: String? = nil) -> ClassItem {
    var f: [String: Any] = ["title": title, "source": source, "level": level,
                            "city": source == "ucb_la" ? "Los Angeles" : "New York",
                            "org": "UCB"]
    if let start { f["start"] = start }
    return classItem(f)
}

/// A shows store with the persisted filters ignored and the clock pinned.
@MainActor
func showsStore() -> ShowsStore {
    let store = ShowsStore()
    store.filters = Filters()   // ignore anything a previous run persisted
    store.now = { fixedNow }
    return store
}

// MARK: tests

func testClassCurriculum() {
    for source in ["ucb_ny", "ucb_la", "ucb_online"] {
        for (rank, number) in [101, 201, 301, 401].enumerated() {
            checkEqual(ClassCurriculum.course(source: source, title: "Improv \(number)"),
                       .init(curriculum: .improvCore, rank: rank), "\(source) improv \(number) rank")
        }
        for (rank, number) in [101, 201, 301].enumerated() {
            checkEqual(ClassCurriculum.course(source: source, title: "Sketch \(number)"),
                       .init(curriculum: .sketchCore, rank: rank), "\(source) sketch \(number) rank")
        }
    }
    for number in 1...4 {
        checkEqual(ClassCurriculum.course(source: "brooklyn_cc", title:
                   "[Sep-Oct] Improv Level \(number): Long Forms w/ Andy Junk (Tuesday)"),
                   .init(curriculum: .improvCore, rank: number - 1), "BCC season-tagged improv \(number)")
    }
    for number in 1...2 {
        checkEqual(ClassCurriculum.course(source: "brooklyn_cc", title:
                   "[Aug-Oct] [Virtual] Sketch: Level \(number) w/ Devin Bockrath (Monday)"),
                   .init(curriculum: .sketchCore, rank: number - 1), "BCC repeated tags sketch \(number)")
    }
    checkEqual(ClassCurriculum.course(source: "ucb_online", title: "ONLINE Sketch 101"),
               .init(curriculum: .sketchCore, rank: 0), "online title prefix without level fallback")
    checkEqual(ClassCurriculum.course(source: "ucb_ny", title: "  iMpRoV  201: Intensive"),
               .init(curriculum: .improvCore, rank: 1), "core prefix ignores case and spacing")
    checkEqual(ClassCurriculum.course(source: "ucb_ny", title: "Improv 101 Drop-In",
                                     level: "Improv Workshops & Drop-Ins"),
               .init(curriculum: .improvCore, rank: 0), "numbered drop-in stays with core course")
    checkEqual(ClassCurriculum.course(source: "ucb_ny", title: "Renamed course",
                                     level: "Improv 201: The Game of the Scene"),
               .init(curriculum: .improvCore, rank: 1), "canonical level supports renamed course")
    for title in ["Musical Improv 101", "ONLINE Musical Improv 101", "Advanced Study Improv",
                  "Advanced Sketch 101", "Sketch 999", "Sketch 401", "Improv 1010", "Improv 101A",
                  "Improv 0101"] {
        checkEqual(ClassCurriculum.course(source: "ucb_ny", title: title, level: "Improv 101"), nil,
                   "explicit non-core title defeats misleading level: \(title)")
    }
    for title in ["Musical Improv Level 1", "Sketch: Level 3", "Improv Level 5", "Improv Level 11",
                  "Improv 101", "Drop-In Intro to BCC Improv", "Workshop for Improv Level 1 graduates"] {
        checkEqual(ClassCurriculum.course(source: "brooklyn_cc", title: "[Aug-Oct] \(title)"), nil,
                   "BCC non-core course stays out: \(title)")
    }
    checkEqual(ClassCurriculum.course(source: "ucb_ny", title: "Improv Drop-In"), nil,
               "unnumbered drop-in stays outside core")
    for source in ["magnet", "second_city", "io_chicago", "ucb_unknown", ""] {
        checkEqual(ClassCurriculum.course(source: source, title: "Improv 101", level: "Sketch 101"), nil,
                   "core curriculum is source-scoped: \(source)")
    }
}

@MainActor
func testSubjectGroups() {
    // Both core curricula lead, ordered by level with a start-date tiebreak.
    let items = [
        ucbClass("Character 101", level: "Character", start: "2026-08-01T19:00:00"),
        ucbClass("Improv 201", level: "Improv 201: The Game of the Scene", start: "2026-08-05T19:00:00"),
        ucbClass("Improv 101", level: "Improv 101: Improv Basics", start: "2026-09-01T19:00:00"),
        ucbClass("Improv 101", level: "Improv 101: Improv Basics", start: "2026-08-01T19:00:00"),
        ucbClass("Sketch 301", level: "Sketch 301", start: "2026-08-01T19:00:00"),
        ucbClass("Sketch 101", level: "Sketch 101", start: "2026-09-01T19:00:00"),
        ucbClass("Sketch from Improv", level: "Featured Programs"),
    ]
    let groups = ClassesStore.subjectGroups(from: items, source: "ucb_ny")
    checkEqual(groups.map(\.id), ["ucb_ny/improv_core", "ucb_ny/sketch_core",
                                  "ucb_ny/Sketch & Writing", "ucb_ny/Acting & Character"],
               "both core groups pinned first, ids scoped to the school")
    let core = groups[0]
    checkEqual(core.title, "Improv Core", "improv core group title")
    checkEqual(core.classes.map(\.title), ["Improv 101", "Improv 101", "Improv 201"],
               "core ordered 101→401")
    check(core.classes[0].start == "2026-08-01T19:00:00", "same rank ordered by date")
    checkEqual(groups[1].title, "Sketch Core", "sketch core group title")
    checkEqual(groups[1].classes.map(\.title), ["Sketch 101", "Sketch 301"],
               "sketch core rank takes precedence over date")
    checkEqual(groups.flatMap(\.classes).count, items.count, "every UCB class appears in exactly one group")
    checkEqual(groups[2].classes.map(\.title), ["Sketch from Improv"],
               "core sketches are removed from the ordinary sketch bucket")

    let nonUCB = [classItem(["title": "Improv 101", "source": "magnet", "level": "Improv",
                             "city": "New York"])]
    checkEqual(ClassesStore.subjectGroups(from: nonUCB, source: "magnet").map(\.id),
               ["magnet/Improv"], "other schools retain their existing subject groups")

    let bccTitles = ["[Aug-Oct] Sketch: Level 2 w/ Teacher", "[Aug-Oct] Improv Level 4: Long Forms",
                     "[Aug-Oct] Musical Improv Level 1: Structure", "[Aug-Oct] Improv Level 1: Intro",
                     "[Aug-Oct] Sketch: Level 1 w/ Teacher", "Drop-In Intro to BCC Improv"]
    let bcc = bccTitles.enumerated().map { index, title in
        classItem(["id": String(index), "source": "brooklyn_cc", "title": title, "city": "New York"])
    }
    let bccGroups = ClassesStore.subjectGroups(from: bcc, source: "brooklyn_cc")
    checkEqual(bccGroups.map(\.title), ["Improv Core", "Sketch Core", "Musical Improv", "Workshops & Drop-Ins"],
               "BCC splits improv and sketch core ahead of remaining subjects")
    checkEqual(bccGroups[0].classes.map(\.title), [bccTitles[3], bccTitles[1]], "BCC improv level order")
    checkEqual(bccGroups[1].classes.map(\.title), [bccTitles[4], bccTitles[0]], "BCC sketch level order")
    checkEqual(bccGroups.flatMap(\.classes).map(\.id).sorted(), bcc.map(\.id).sorted(),
               "BCC core and remaining buckets neither duplicate nor lose any class")

    let prerequisites = classItem(["source": "ucb_ny", "title": "Advanced Scene Workshop",
                                  "description": "Prerequisites: Improv 101 and Sketch 101."])
    checkEqual(ClassesStore.subjectGroups(from: [prerequisites], source: "ucb_ny").map(\.title),
               ["Workshops & Drop-Ins"], "description prerequisites cannot promote a course to core")

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

func testSubjectClassification() {
    let subject = { (title: String) in ClassItem.classifySubject(level: "", title: title) }
    // Whole-word matching: "jam" used to match "James" and file iO's core
    // classes under Workshops (real titles from the live feed).
    checkEqual(subject("iO Improv Level 4 with James Dugan"), "Improv", "\"jam\" does not match James")
    checkEqual(subject("iO Improv Level 5 with Dani James"), "Improv", "…nor a James surname")
    checkEqual(classItem(["title": "Improv Level 4 with James Dugan", "source": "io_chicago",
                          "level": "Improv", "city": "Chicago"]).subject, "Improv",
               "the decoded item files the same way")
    checkEqual(subject("Thursday Night Jam"), "Workshops & Drop-Ins", "a real jam still lands in workshops")
    checkEqual(subject("Drop-In Improv"), "Workshops & Drop-Ins", "hyphenated drop-in")
    checkEqual(subject("Drop In Improv"), "Workshops & Drop-Ins", "spaced drop in")
    checkEqual(subject("Stand-Up 101"), "Stand-Up", "hyphenated stand-up")
    checkEqual(subject("Standup Basics"), "Stand-Up", "one-word standup")
    checkEqual(subject("On-Camera Acting"), "Acting & Character", "on-camera")
    checkEqual(subject("Clowning Intensive"), "Clowning", "stem match, and rule order beats 'intensive'")
    checkEqual(subject("Storytellers Lab"), "Storytelling", "stem match on storytell*")
    checkEqual(subject("Improv for Teens"), "Teens & Youth", "plural keyword")
    checkEqual(subject("Youngblood Sketch Show"), "Sketch & Writing", "'young' does not match Youngblood")
    checkEqual(subject("Podcasting Workshop"), "Workshops & Drop-Ins", "a whole-word keyword still matches")
}

func testClassScope() {
    checkEqual(SourceCatalog.classScope(for: ["ucb_ny"]).sorted(),
               ["brooklyn_cc", "magnet", "ucb_ny", "ucb_online", "wgis_ny"],
               "one NY theater scopes classes to every NY school, plus UCB Online for a UCB pick")
    check(SourceCatalog.classScope(for: ["ucb_la"]).contains("ucb_online"),
          "UCB LA brings UCB Online along too")
    check(!SourceCatalog.classScope(for: ["magnet"]).contains("ucb_online"),
          "a non-UCB pick in the same city does not")
    let mixed = SourceCatalog.classScope(for: ["ucb_ny", "annoyance"])
    check(mixed.contains("magnet") && mixed.contains("second_city"),
          "a cross-city pick spans both cities")
    check(!mixed.contains("ucb_la"), "an unpicked city stays out of scope")
    check(SourceCatalog.classScope(for: []).isEmpty,
          "empty selection keeps its no-scoping meaning")
    checkEqual(SourceCatalog.classScope(for: ["nope"]), ["nope"],
               "an unknown id stays alone — it must never widen to everything")
}

@MainActor
func testOnlinePseudoCity() {
    checkEqual(City.allCases.last, .online, "Online sorts after every real city")
    check(!SourceCatalog.byCity.contains { $0.city == .online },
          "the theater sidebar has no Online section")
    check(!SourceCatalog.showIDs.contains("ucb_online"), "UCB Online is never a shows theater")
    checkEqual(SourceCatalog.entry("ucb_online")?.city, .online, "the catalog knows UCB Online")
    check(SourceCatalog.isUCB("ucb_ny") && SourceCatalog.isUCB("ucb_la") && SourceCatalog.isUCB("ucb_online"),
          "isUCB covers all three UCB schools")
    check(!SourceCatalog.isUCB("magnet") && !SourceCatalog.isUCB(""), "…and nothing else")

    // Online classes are scheduled by the New York office: Eastern wall clock.
    let online = classItem(["title": "Improv 201", "source": "ucb_online", "city": "Online",
                            "org": "UCB", "start": "2026-08-14T19:00:00"])
    if let d = online.startDate {
        checkEqual(DateUtils.calendar(in: City.newYork.timeZone).component(.hour, from: d), 19,
                   "an Online class reads in Eastern time")
    } else { check(false, "online startDate parsed") }

    // Picking a UCB campus surfaces the Online folder — last, after the
    // city's schools; a non-UCB pick in the same city does not.
    let store = ClassesStore()
    store.apply(classesPayload([
        ["title": "Improv 101", "source": "ucb_ny", "city": "New York", "org": "UCB"],
        ["title": "Level One", "source": "magnet", "city": "New York", "org": "Magnet Theater"],
        ["title": "Improv 201", "source": "ucb_online", "city": "Online", "org": "UCB"],
    ]))
    let ucb = store.schoolFolders(theaters: ["ucb_ny"]).selected.map(\.id)
    checkEqual(ucb.first, "ucb_ny", "the picked campus leads")
    checkEqual(ucb.last, "ucb_online", "UCB Online folders last, under its own pseudo-city")
    check(!store.schoolFolders(theaters: ["magnet"]).selected.contains { $0.id == "ucb_online" },
          "a Magnet pick does not surface UCB Online")
    checkEqual(store.filtered(theaters: ["ucb_la"]).map(\.title), ["Improv 201"],
               "UCB LA scopes in the Online classes and nothing from New York")
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

    // Field-lenient: a wrong-typed value drops that field, not the row.
    let odd = classItem(["title": "Odd", "source": "magnet", "id": 44580, "is_full": "yes",
                         "instructor": NSNull()])
    checkEqual(odd.rawID, "", "a numeric id drops to the default")
    check(!odd.isFull, "a string is_full drops to false")
    checkEqual(odd.instructor, "", "a null instructor drops to empty")
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

func testFieldLenientShowDecoding() {
    // One wrong-typed value or one bad array element used to throw out of
    // init(from:) and the payload's Lossy silently dropped the whole show.
    let odd = show(["title": "Odd Row", "source": "ucb_ny", "city": "New York",
                    "post_id": "abc",
                    "comedy_types": ["Improv", NSNull(), 7],
                    "cast_members": [["name": "Ana One", "slug": "ana-one"], "junk", ["slug": "nameless"]],
                    "venues": NSNull(),
                    "is_free": "yes",
                    "start": "2026-08-01T20:00:00", "has_time": true])
    checkEqual(odd.title, "Odd Row", "the row survives")
    check(odd.postID == nil, "a string post_id drops the field")
    checkEqual(odd.comedyTypes, ["Improv"], "a null inside comedy_types drops that element only")
    checkEqual(odd.castList.map(\.name), ["Ana One"], "a bad cast element drops; a nameless one is filtered")
    check(odd.venues.isEmpty, "a null venues list is empty")
    check(!odd.isFree, "a string is_free falls back to false")
    checkEqual(odd.dayKey, "2026-08-01", "…and the good fields still decode")

    // The scrapers' own "unset" is an empty string, which must take the same
    // fallback as an absent key — otherwise the id loses its source prefix
    // and the row matches no theater scope.
    let blank = show(["title": "Blank Source", "source": "", "org": "", "city": ""])
    checkEqual(blank.source, "ucb_ny", "empty source falls back like a missing one")
    checkEqual(blank.id, "ucb_ny/Blank Source", "…so the id keeps its source prefix")
    checkEqual(blank.org, "UCB", "empty org falls back")
    checkEqual(blank.city, "New York", "empty city falls back")

    let person = talentPerson(["name": "Ann Teacher", "slug": "ann", "groups": ["ny", 3, NSNull()], "bio": 12])
    checkEqual(person.groups, ["ny"], "a bad group element drops, the person stays")
    checkEqual(person.bio, "", "a wrong-typed bio drops to empty")
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
                  "not an object",  // malformed element: not even a show
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

func testNameKeyFolding() {
    // `diacriticInsensitive` folds é/ñ but not ø/ł/ß/æ/œ — letters without a
    // combining mark. Before the fold those were stripped, so "Søren" → "sren".
    checkEqual(TalentPerson.nameKey("Søren Kierkegaard"), "soren kierkegaard", "ø folds to o")
    checkEqual(TalentPerson.nameKey("Łukasz Nowak"), "lukasz nowak", "ł folds to l")
    checkEqual(TalentPerson.nameKey("Straße"), "strasse", "ß folds to ss")
    checkEqual(TalentPerson.nameKey("Ærø Œuvre"), "aero oeuvre", "æ/œ fold to ae/oe")
    checkEqual(TalentPerson.nameKey("José Peña (LA)"), "jose pena", "combining-mark diacritics still fold")
    checkEqual(TalentPerson.nameKey("Søren"), TalentPerson.nameKey("Soren"), "a cast line typed plain matches")
}

// MARK: Tickets (Foundation-only model logic)

func testTicketBasics() {
    // cleanVenue strips city + building boilerplate, NY and LA alike.
    checkEqual(Ticket.cleanVenue("NY - 14TH ST. MAINSTAGE"), "MAINSTAGE", "NY hyphen + 14TH ST.")
    checkEqual(Ticket.cleanVenue("NY – 14th St. Mainstage"), "Mainstage", "NY en dash + 14th St.")
    checkEqual(Ticket.cleanVenue("NY - SUBCULTURE"), "SUBCULTURE", "NY without building")
    checkEqual(Ticket.cleanVenue("LA - FRANKLIN"), "FRANKLIN", "LA hyphen")
    checkEqual(Ticket.cleanVenue("LA – Annex"), "Annex", "LA en dash")
    checkEqual(Ticket.cleanVenue("Livestream"), "Livestream", "no prefix untouched")
    checkEqual(Ticket.cleanVenue(""), "", "empty")

    // whenLabel: empty (never the venue) when the start didn't parse.
    let undated = Ticket(kind: .reserved, orderID: "1", title: "Show", venueLabel: "NY - 14TH ST. MAINSTAGE",
                         source: "ucb_ny", start: nil, qrSVG: "<svg/>", releaseNonce: "n")
    checkEqual(undated.whenLabel, "", "undated whenLabel is empty, not the venue")
    let dated = Ticket(kind: .reserved, orderID: "2", title: "Show", venueLabel: "LA - FRANKLIN",
                       source: "ucb_la", start: "2026-06-26T19:00:00", qrSVG: "<svg/>", releaseNonce: "n")
    check(dated.whenLabel.contains("·"), "dated whenLabel has date · time, got \(dated.whenLabel)")
    check(dated.whenLabel.contains("7:00"), "dated whenLabel carries the venue-local time, got \(dated.whenLabel)")

    // isReleasable: false when undated; honours the one-hour cutoff via `now`.
    check(!undated.isReleasable(), "undated never releasable")
    let start = dated.startDate!
    check(dated.isReleasable(now: start.addingTimeInterval(-2 * 3600)), "2h out is releasable")
    check(!dated.isReleasable(now: start.addingTimeInterval(-3600 + 1)), "inside the hour is not")
    check(dated.isReleasable(now: start.addingTimeInterval(-3600 - 1)), "just outside the hour is")
    let noNonce = Ticket(kind: .reserved, orderID: "3", title: "Show", source: "ucb_ny",
                         start: "2026-06-26T19:00:00", qrSVG: "<svg/>")
    check(!noNonce.isReleasable(now: start.addingTimeInterval(-2 * 3600)), "no nonce -> not releasable")
    let sid = Ticket(kind: .studentID, title: "UCB Student ID", source: "ucb_ny", qrSVG: "<svg/>", releaseNonce: "n")
    check(!sid.isReleasable(now: .distantPast), "student ID never releasable")

    // isPast: reserved only, three hours after showtime.
    check(!dated.isPast(now: start.addingTimeInterval(2 * 3600)), "two hours in is not past yet")
    check(dated.isPast(now: start.addingTimeInterval(3 * 3600 + 1)), "past three hours it is")
    check(!sid.isPast(now: .distantFuture), "the student ID never expires")
    check(!undated.isPast(now: .distantFuture), "an undated ticket is never auto-expired")
    check(dated.venue?.id == "ucb_la" && undated.venue?.id == "ucb_ny", "venue resolves by source")
}

func testShowTextAnchors() {
    // The cast label is word-anchored: "podcast:" is not "cast:".
    let pod = show(["title": "P", "source": "ucb_ny", "city": "New York",
                    "description": "Our weekly podcast: live and unedited."])
    check(!pod.hasCast, "\"podcast:\" does not split off a cast section")
    checkEqual(pod.detailText, "Our weekly podcast: live and unedited.", "…and the body stays whole")
    let cast = show(["title": "C", "source": "ucb_ny", "city": "New York",
                     "description": "A show.\n\nCast: Ana One & Ben Two"])
    checkEqual(cast.castMembers, ["Ana One", "Ben Two"], "a real Cast: label still splits")

    // The time regex needs a trailing boundary: "10:00 amazing" is no time.
    let amazing = show(["title": "A", "source": "ucb_ny", "city": "New York",
                        "date_raw": "Sat 10:00 amazing hours", "start": "2026-08-01T20:00:00", "has_time": true])
    checkEqual(amazing.timeLabel, "8:00 PM", "\"10:00 amazing\" falls through to the parsed start")
    let pm = show(["title": "B", "source": "ucb_ny", "city": "New York", "date_raw": "Sat, Aug 1 at 7:30pm."])
    checkEqual(pm.timeLabel, "7:30PM", "a real time in date_raw is lifted verbatim")

    // Venue prefixes: anchored, and every UCB campus form.
    checkEqual(Show.cleanVenueName("NY - 14TH ST. Mainstage"), "Mainstage", "NY street tag stripped")
    checkEqual(Show.cleanVenueName("NY - Annex"), "Annex", "bare NY prefix stripped")
    checkEqual(Show.cleanVenueName("NY – Annex"), "Annex", "en-dash NY prefix stripped")
    checkEqual(Show.cleanVenueName("NY – 14th St. Mainstage"), "Mainstage",
               "the account page's mixed-case en-dash form strips the same way")
    checkEqual(Show.cleanVenueName("LA - FRANKLIN"), "FRANKLIN", "LA prefix stripped")
    checkEqual(Show.cleanVenueName("The NY - Room"), "The NY - Room", "a tag mid-name is left alone")
    checkEqual(Show.cleanVenueName("Mainstage"), "Mainstage", "a clean name passes through")
    checkEqual(show(["title": "V", "source": "ucb_la", "city": "Los Angeles", "venue": "LA - ANNEX"]).shortVenue,
               "ANNEX", "shortVenue uses the shared helper")
}

func testDateUtils() {
    let chicago = TimeZone(identifier: "America/Chicago")!
    check(DateUtils.parse("2026-08-29T12:00:00", in: chicago) != nil, "timed parse")
    checkEqual(DateUtils.parse("2026-08-14T19:00", in: chicago),
               DateUtils.parse("2026-08-14T19:00:00", in: chicago),
               "minute-precision parse keeps the time (UCB account scrape)")
    check(DateUtils.parse("2026-08-29", in: chicago) != nil, "date-only parse")
    check(DateUtils.parse("garbage", in: chicago) == nil, "garbage -> nil")
    // Unexpected shapes fail rather than guess midnight from the date prefix.
    check(DateUtils.parse("2026-08-29T12:00:00Z", in: chicago) == nil, "a zone suffix -> nil, not midnight")
    check(DateUtils.parse("2026-08-29T12:00:00+00:00", in: chicago) == nil, "an offset -> nil")
    check(DateUtils.parse("2026-08-29T12:00:00.500", in: chicago) == nil, "fractional seconds -> nil")
    check(DateUtils.parse("2026-08-29T12:00:00", in: City.online.timeZone) != nil, "the Online zone parses")
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

func testFiltersDecoding() {
    func decode(_ json: String) -> Filters? {
        try? JSONDecoder().decode(Filters.self, from: Data(json.utf8))
    }
    // Persisted filters survive a schema change field by field: an unknown
    // DateWindow case or key resets that field alone.
    let drifted = decode(#"{"venue":"Mainstage","comedyTypes":["Improv"],"dateWindow":"nextMonth","brandNewKey":1}"#)
    checkEqual(drifted?.venue, "Mainstage", "known fields decode")
    checkEqual(drifted?.comedyTypes, ["Improv"], "…all of them")
    checkEqual(drifted?.dateWindow, .all, "an unknown DateWindow case resets that field only")
    let mistyped = decode(#"{"freeOnly":"yes","comedyTypes":"Improv","livestreamOnly":true}"#)
    check(mistyped?.freeOnly == false && mistyped?.comedyTypes.isEmpty == true, "wrong-typed fields reset")
    check(mistyped?.livestreamOnly == true, "…without touching the rest")
    checkEqual(decode("{}"), Filters(), "an empty object is the default set")
    // Round trip through the encoder the store uses.
    var f = Filters(); f.venue = "Upstairs"; f.dateWindow = .weekend; f.freeOnly = true
    let data = try! JSONEncoder().encode(f)
    checkEqual(try? JSONDecoder().decode(Filters.self, from: data), f, "encode/decode round-trips")
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
    @MainActor
    static func main() async {
        testClassCurriculum()
        runClassAlertPreferenceTests()
        testSubjectGroups()
        testSubjectClassification()
        testClassScope()
        testOnlinePseudoCity()
        testClassItemDecoding()
        testShowDecodingAndDayKey()
        testFieldLenientShowDecoding()
        testDaySectionGrouping()
        testLossyPayloadDecoding()
        testShowTextAnchors()
        testNameKeyFolding()
        testTicketBasics()
        testDateUtils()
        testFiltersDecoding()
        testReminderPlan()
        testReminderCoverage()
        testClassesLayoutMemo()
        testSearchByteParity()
        testSchoolFolderOrder()
        testPickedTheaterWithNoClasses()
        testShowSearchByteParity()
        testShowsSectionMemo()
        testShowsSearchFiltering()
        testPastShowsPruned()
        testReconcileFilters()
        await testTalentDirectory()
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

// MARK: Shows tab feed (search byte parity, section memoization, pruning)

func showsPayload(_ items: [[String: Any]]) -> ShowsPayload {
    let data = try! JSONSerialization.data(withJSONObject: ["shows": items])
    return try! JSONDecoder().decode(ShowsPayload.self, from: data)
}

private let nyShows: [[String: Any]] = [
    ["title": "Harold Night", "source": "ucb_ny", "city": "New York",
     "start": "2026-08-01T20:00:00", "has_time": true,
     "excerpt": "The Harold, every night", "comedy_types": ["Improv"]],
    ["title": "Pérez Presents", "source": "ucb_ny", "city": "New York",
     "start": "2026-08-02T20:00:00", "has_time": true,
     "excerpt": "A showcase", "comedy_types": ["Stand-Up"]],
    ["title": "Magnet Megawatt", "source": "magnet", "city": "New York",
     "start": "2026-08-02T21:00:00", "has_time": true,
     "comedy_types": ["Improv"]],
    ["title": "Dates TBA Sketch Hour", "source": "ucb_ny", "city": "New York",
     "excerpt": "Sketch comedy"],
]

@MainActor
func testShowSearchByteParity() {
    let items = nyShows.map { show($0) }
    for raw in ["harold", "improv", "stand-up", "Pérez", "perez", "sketch comedy",
                "zzzznope", "", "  "] {
        let query = SearchText.normalized(raw)
        let needle = Array(query.utf8)
        for item in items {
            // Both sides are already diacritic-folded and lowercased, so the
            // byte scan has to agree with String.contains on every show.
            let want = query.isEmpty ? true : item.searchHay.contains(query)
            checkEqual(SearchText.contains(item.searchBytes, needle), want,
                       "byte scan matches String.contains for \"\(raw)\" in \(item.title)")
        }
    }
}

@MainActor
func testShowsSearchFiltering() {
    let store = showsStore()
    store.apply(showsPayload(nyShows))

    checkEqual(store.filtered(theaters: [], searchText: "harold").map(\.title),
               ["Harold Night"], "search matches the title")
    checkEqual(store.filtered(theaters: [], searchText: "sketch comedy").map(\.title),
               ["Dates TBA Sketch Hour"], "search matches the excerpt")
    checkEqual(store.filtered(theaters: [], searchText: "improv").map(\.title),
               ["Harold Night", "Magnet Megawatt"], "search matches comedy types")
    checkEqual(store.filtered(theaters: [], searchText: "perez").map(\.title),
               ["Pérez Presents"], "a folded query matches an accented title")
    checkEqual(store.filtered(theaters: [], searchText: "Pérez").map(\.title),
               ["Pérez Presents"], "...and so does an accented query")
    check(store.filtered(theaters: [], searchText: "zzzznope").isEmpty,
          "a miss returns nothing — the case the byte scan made fast")
    checkEqual(store.filtered(theaters: [], searchText: "   ").count, nyShows.count,
               "a whitespace-only query filters nothing")
    checkEqual(store.filtered(theaters: ["magnet"], searchText: "improv").map(\.title),
               ["Magnet Megawatt"], "theater scope still applies alongside search")
}

@MainActor
func testShowsSectionMemo() {
    let store = showsStore()   // clock pinned, so the day stamp can't move mid-test
    store.apply(showsPayload(nyShows))

    let first = store.sections(theaters: ["ucb_ny"])
    let builds = store.sectionBuildCount
    let second = store.sections(theaters: ["ucb_ny"])
    checkEqual(store.sectionBuildCount, builds, "repeating a sections call is a memo hit")
    checkEqual(second.map(\.id), first.map(\.id), "the memoized sections are identical")

    _ = store.sections(theaters: ["ucb_ny"], searchText: "harold")
    check(store.sectionBuildCount > builds, "a new query misses the memo")

    _ = store.sections(theaters: ["magnet"])
    let beforeFilter = store.sectionBuildCount
    _ = store.sections(theaters: ["magnet"])
    checkEqual(store.sectionBuildCount, beforeFilter, "...and the new key memoizes in turn")
    store.filters.freeOnly = true
    _ = store.sections(theaters: ["magnet"])
    check(store.sectionBuildCount > beforeFilter, "a filter change misses the memo")
    store.filters = Filters()

    // The day stamp is part of the key: a new day rebuilds even with the
    // same feed, so a feed left on screen across midnight relabels "Today".
    _ = store.sections(theaters: ["ucb_ny"])
    let beforeDay = store.sectionBuildCount
    store.now = { fixedNow.addingTimeInterval(86400) }
    _ = store.sections(theaters: ["ucb_ny"])
    check(store.sectionBuildCount > beforeDay, "a new day misses the memo")
    store.now = { fixedNow }

    _ = store.sections(theaters: ["ucb_ny"])
    let beforeApply = store.sectionBuildCount
    store.apply(showsPayload([nyShows[0]]))
    let afterApply = store.sections(theaters: ["ucb_ny"])
    check(store.sectionBuildCount > beforeApply, "a feed apply invalidates the memo")
    checkEqual(afterApply.flatMap { $0.shows.map(\.title) }, ["Harold Night"],
               "the rebuilt sections reflect the new feed")
}

@MainActor
func testPastShowsPruned() {
    // The backend prunes daily; a device serving its cache offline for days
    // did not. Clock: 2026-07-31 12:00 New York / 09:00 Los Angeles.
    let store = showsStore()
    store.apply(showsPayload([
        ["title": "Last Night", "source": "ucb_ny", "city": "New York",
         "start": "2026-07-30T23:00:00", "has_time": true],
        ["title": "Small Hours", "source": "ucb_ny", "city": "New York",
         "start": "2026-07-31T01:00:00", "has_time": true],
        ["title": "Tonight", "source": "ucb_ny", "city": "New York",
         "start": "2026-07-31T20:00:00", "has_time": true],
        ["title": "LA Last Night", "source": "ucb_la", "city": "Los Angeles",
         "start": "2026-07-30T23:30:00", "has_time": true],
        ["title": "Undated", "source": "ucb_ny", "city": "New York"],
    ]))
    checkEqual(store.filtered(theaters: []).map(\.title), ["Small Hours", "Tonight", "Undated"],
               "shows before the venue's start of today are pruned; today's and undated stay")
    checkEqual(store.sections(theaters: []).map(\.id), ["2026-07-31", "tba"],
               "no past-date section reaches the feed")
    checkEqual(store.availableVenues(theaters: []).count, 0,
               "the raw scope is untouched — pruning is a display rule")

    // Just past midnight, the 6 h grace GoingStore uses keeps last night's
    // late show on the feed a little longer.
    store.now = { DateUtils.parse("2026-08-01T01:00:00", in: City.newYork.timeZone)! }
    store.apply(showsPayload([
        ["title": "Early Evening", "source": "ucb_ny", "city": "New York",
         "start": "2026-07-31T18:00:00", "has_time": true],
        ["title": "Late Show", "source": "ucb_ny", "city": "New York",
         "start": "2026-07-31T23:00:00", "has_time": true],
    ]))
    checkEqual(store.filtered(theaters: []).map(\.title), ["Late Show"],
               "within the grace a late show lingers past midnight; an earlier one does not")
}

@MainActor
func testReconcileFilters() {
    let store = showsStore()
    store.apply(showsPayload([
        ["title": "Mainstage Show", "source": "second_city", "city": "Chicago", "venue": "Mainstage",
         "start": "2026-08-05T20:00:00", "has_time": true, "comedy_types": ["Sketch"]],
        ["title": "No Venue Show", "source": "second_city", "city": "Chicago",
         "start": "2026-08-06T20:00:00", "has_time": true, "comedy_types": ["Sketch"]],
        ["title": "Harold Night", "source": "ucb_ny", "city": "New York", "venue": "NY - 14TH ST. Mainstage",
         "start": "2026-08-05T20:00:00", "has_time": true, "comedy_types": ["Improv"]],
    ]))

    store.filters.venue = "Mainstage"
    store.reconcileFilters(theaters: ["second_city", "ucb_ny"])
    checkEqual(store.filters.venue, "Mainstage", "a venue stays while the scope offers a choice")
    store.reconcileFilters(theaters: ["second_city"])
    check(store.filters.venue == nil,
          "a lone venue is cleared — the picker would be hidden and the filter invisible")
    store.filters.venue = "Mainstage"
    store.reconcileFilters(theaters: ["ucb_ny"])
    check(store.filters.venue == nil, "a venue the scope lacks is cleared")

    // A scope with no shows at all offers nothing to reconcile against and
    // must not wipe filters that are still valid once the source is back.
    store.filters.comedyTypes = ["Improv"]
    store.filters.venue = "Mainstage"
    store.reconcileFilters(theaters: ["annoyance"])
    checkEqual(store.filters.comedyTypes, ["Improv"], "an empty scope leaves persisted types alone")
    checkEqual(store.filters.venue, "Mainstage", "…and the venue")
    store.reconcileFilters(theaters: ["second_city"])
    check(store.filters.comedyTypes.isEmpty && store.filters.venue == nil,
          "a populated scope still drops what it lacks")
    store.filters = Filters()
}

// MARK: Talent directory (phase, city chips)

func talentPayload(_ items: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["people": items])
}

@MainActor
func testTalentDirectory() async {
    // A file:// feed drives the store's phases without a network: a missing
    // file is a failed fetch, a present one a successful refresh.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("improv_logic_tests_\(ProcessInfo.processInfo.processIdentifier)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let feed = dir.appendingPathComponent("talent.json")
    let cacheName = "logic_tests.talent.cache.json"
    defer {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: AppSupport.file(cacheName))
    }
    let store = TalentStore(service: FeedService(feed: feed, cacheName: cacheName))
    checkEqual(store.phase, .loading, "the directory starts loading, like the other stores")
    check(!store.loaded, "…with nothing loaded")

    await store.refresh()
    if case .failed = store.phase { check(true, "a failed first fetch is a failed phase") }
    else { check(false, "a failed first fetch is a failed phase: got \(store.phase)") }
    check(!store.loaded, "…and still nothing loaded, so the view can offer a retry")

    try! talentPayload([
        ["name": "Ana NY", "slug": "ana-ny", "groups": ["ny"]],
        ["name": "Dee DCM", "slug": "dee-dcm", "groups": ["dcm"]],
        ["name": "Tia Teacher", "slug": "tia-teacher", "groups": ["teachers"]],
        ["name": "Bi Coastal", "slug": "bi-coastal", "groups": ["ny", "la"]],
        ["name": "Lou LA", "slug": "lou-la", "groups": ["la"]],
        ["name": "", "slug": "nameless", "groups": ["ny"]],
    ]).write(to: feed)
    await store.refresh()
    checkEqual(store.phase, .loaded, "a retry that succeeds is loaded")
    check(store.loaded, "…with people on hand")
    checkEqual(store.people(matching: "").count, 5, "a nameless row is dropped")

    // City chips: everyone `cityLabel` tags New York — roster, DCM, teachers —
    // appears under the New York chip; LA membership wins for bicoastals.
    checkEqual(store.people(matching: "", group: "ny").map(\.slug), ["ana-ny", "dee-dcm", "tia-teacher"],
               "the New York chip includes teachers and excludes LA members")
    checkEqual(store.people(matching: "", group: "la").map(\.slug), ["bi-coastal", "lou-la"],
               "the LA chip is plain membership")
    let nyChip = Set(store.people(matching: "", group: "ny").map(\.slug))
    let laChip = Set(store.people(matching: "", group: "la").map(\.slug))
    check(store.people(matching: "").allSatisfy { nyChip.contains($0.slug) || laChip.contains($0.slug) },
          "nobody vanishes under both city chips")
    checkEqual(store.people(matching: "tia", group: "ny").map(\.slug), ["tia-teacher"],
               "search composes with the chip")
    checkEqual(store.person(for: CastMember(name: "Ana NY", slug: nil))?.slug, "ana-ny",
               "cast names still resolve by normalized name")

    try! FileManager.default.removeItem(at: feed)
    await store.refresh()
    checkEqual(store.phase, .offline, "a later failure keeps the data and reports offline")
    check(store.loaded, "…so cast chips keep working")
}
