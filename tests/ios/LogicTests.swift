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
        print(failures == 0 ? "\nALL SWIFT LOGIC TESTS PASSED" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
