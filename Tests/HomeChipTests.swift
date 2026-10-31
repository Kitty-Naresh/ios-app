import XCTest
@testable import Kitty

/// The home screen's chip row: smart views (Overdue, Today, New), then labels, then All. SCRIPTED: pure functions over tasks in memory,
/// no model and no UI. The names are placeholders on purpose.
@MainActor
final class HomeChipTests: XCTestCase {
    private let now = Date()
    private let day: TimeInterval = 86_400

    private func task(_ title: String, due: Date? = nil, created: Date? = nil, assignee: String? = nil, name: String? = nil,
                      profile: UUID? = nil, group: String? = nil, done: Bool = false) -> TaskItem {
        var t = TaskItem(title: title)
        t.dueDate = due
        t.createdAt = created
        t.assignee = assignee
        t.categoryName = name
        t.profileID = profile
        t.group = group
        t.isDone = done
        return t
    }

    private func entry(_ name: String, _ kinds: Set<TaskTag.Kind> = [.category], count: Int = 1) -> TagEntry {
        TagEntry(name: name, kinds: kinds, count: count)
    }

    private func scratchDefaults() -> (UserDefaults, String) {
        let suite = "HomeChipTests-" + UUID().uuidString
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func labels(_ chips: [HomeChip]) -> [String] { chips.filter { $0.kind == .label }.map(\.name) }
    private func kinds(_ chips: [HomeChip]) -> [HomeChip.Kind] { chips.map(\.kind) }

    // MARK: The smart views

    func testSmartChipsAreLeftOutWhenNothingIsBehindThem() {
        let tasks = [task("a", due: Calendar.current.startOfDay(for: now), name: "Alpha")]       // today, no creation date
        let row = HomeLabels.row(index: [entry("Alpha")], tasks: tasks, now: now)
        XCTAssertEqual(kinds(row), [.today, .label, .all])
        XCTAssertEqual(row.first?.open, 1)
    }

    func testOverdueThenTodayThenNewThenLabelsThenAll() {
        let past = Calendar.current.startOfDay(for: now.addingTimeInterval(-3 * day))
        let tasks = [
            task("late", due: past, created: now.addingTimeInterval(-30 * day), name: "Alpha"),
            task("now", due: Calendar.current.startOfDay(for: now), created: now.addingTimeInterval(-60), name: "Alpha"),
        ]
        let row = HomeLabels.row(index: [entry("Alpha")], tasks: tasks, now: now)
        XCTAssertEqual(kinds(row), [.overdue, .today, .new, .label, .all])
        XCTAssertEqual(row.map(\.open).prefix(3), [1, 1, 1])
    }

    func testNewLeavesOutTasksWithNoCreationDateAndOldOnes() {
        let tasks = [task("a"), task("b", created: now.addingTimeInterval(-10 * day)), task("c", created: now.addingTimeInterval(-day))]
        let row = HomeLabels.row(index: [], tasks: tasks, now: now)
        XCTAssertEqual(row.first { $0.kind == .new }?.open, 1)
    }

    func testDoneTasksCountForNothing() {
        let tasks = [task("a", created: now, done: true)]
        let row = HomeLabels.row(index: [entry("Alpha")], tasks: tasks, now: now)
        XCTAssertEqual(kinds(row), [.all])
        XCTAssertEqual(row.last?.open, 0)
    }

    func testAListItemWithoutADateIsNotToday() {
        let list = UUID()
        let tasks = [task("a", profile: list, group: "Alpha list")]
        let row = HomeLabels.row(index: [], tasks: tasks, now: now)
        XCTAssertFalse(kinds(row).contains(.today))
        XCTAssertFalse(kinds(row).contains(.overdue))
    }

    // MARK: The labels

    func testALabelOpenedThisWeekBeatsOneWithNewerTasks() {
        let tasks = [task("a", created: now, name: "Fresh"), task("b", created: now.addingTimeInterval(-9 * day), name: "Older")]
        let index = [entry("Fresh"), entry("Older")]
        let key = TaskLabels.stemKey("Older")
        let row = HomeLabels.row(index: index, tasks: tasks, tapDates: [key: now.addingTimeInterval(-day)], now: now)
        XCTAssertEqual(labels(row).prefix(2), ["Older", "Fresh"])
    }

    func testATapOlderThanAWeekNoLongerCounts() {
        let tasks = [task("a", created: now, name: "Fresh"), task("b", created: now.addingTimeInterval(-9 * day), name: "Older")]
        let index = [entry("Fresh"), entry("Older")]
        let key = TaskLabels.stemKey("Older")
        let row = HomeLabels.row(index: index, tasks: tasks, tapDates: [key: now.addingTimeInterval(-8 * day)], now: now)
        XCTAssertEqual(labels(row).prefix(2), ["Fresh", "Older"])
    }

    func testTheLatestTapIsFirst() {
        let tasks = [task("a", name: "One"), task("b", name: "Two")]
        let index = [entry("One"), entry("Two")]
        let dates = [TaskLabels.stemKey("One"): now.addingTimeInterval(-3600), TaskLabels.stemKey("Two"): now.addingTimeInterval(-60)]
        XCTAssertEqual(labels(HomeLabels.row(index: index, tasks: tasks, tapDates: dates, now: now)).prefix(2), ["Two", "One"])
    }

    func testANewListOutranksAnOldBusyOne() {
        let busy = (0..<5).map { task("b\($0)", created: now.addingTimeInterval(-20 * day), name: "Busy") }
        let fresh = TaskProfile(name: "Fresh list")
        let tasks = busy + [task("f", created: nil, name: "Fresh list")]
        var p = fresh; p.createdAt = now.addingTimeInterval(-60)
        let index = [entry("Busy", count: 5), entry("Fresh list", [.list])]
        let row = HomeLabels.row(index: index, tasks: tasks, profiles: [p], now: now)
        XCTAssertEqual(labels(row).first, "Fresh list")
        XCTAssertTrue(row.first { $0.name == "Fresh list" }?.isList ?? false)
    }

    func testTheOrderIsTheSameForTheSameInput() {
        let tasks = [task("a", created: now, name: "One"), task("b", created: now, name: "Two"), task("c", created: now, name: "Three")]
        let index = [entry("One"), entry("Two"), entry("Three")]
        let a = HomeLabels.row(index: index, tasks: tasks, now: now)
        let b = HomeLabels.row(index: index.reversed(), tasks: tasks, now: now)
        XCTAssertEqual(a, HomeLabels.row(index: index, tasks: tasks, now: now))
        XCTAssertEqual(labels(a).sorted(), labels(b).sorted())
    }

    func testANameThatIsAPersonAndACategoryIsOneChip() {
        let tasks = [task("a", assignee: "Alpha", name: "Alpha")]
        let index = [entry("Alpha", [.person]), entry("alpha", [.category])]
        let row = HomeLabels.row(index: index, tasks: tasks, now: now)
        XCTAssertEqual(labels(row).count, 1)
        XCTAssertTrue(row.first { $0.kind == .label }?.isPerson ?? false)
        XCTAssertFalse(row.first { $0.kind == .label }?.isCategory ?? true)
    }

    func testALabelWithNothingOpenIsLeftOut() {
        let row = HomeLabels.row(index: [entry("Alpha")], tasks: [task("a", name: "Beta")], now: now)
        XCTAssertEqual(labels(row), [])
    }

    func testTheLabelsAreCappedButAllIsStillLast() {
        let names = (0..<30).map { "Label\($0)x" }
        let tasks = names.map { task($0, name: $0) }
        let row = HomeLabels.row(index: names.map { entry($0) }, tasks: tasks, now: now, limit: 14)
        XCTAssertEqual(labels(row).count, 14)
        XCTAssertEqual(row.last?.kind, .all)
    }

    func testChipIdsAreUnique() {
        let tasks = [task("a", due: Calendar.current.startOfDay(for: now), created: now, name: "Today")]     // a label named like a view
        let row = HomeLabels.row(index: [entry("Today")], tasks: tasks, now: now)
        XCTAssertEqual(Set(row.map(\.id)).count, row.count)
    }

    func testWhatVoiceOverSays() {
        let tasks = [task("a", due: Calendar.current.startOfDay(for: now.addingTimeInterval(-2 * day)), name: "Alpha")]
        let row = HomeLabels.row(index: [entry("Alpha")], tasks: tasks, now: now)
        XCTAssertEqual(row.first { $0.kind == .overdue }?.spoken, "Overdue, 1")
        XCTAssertEqual(row.first { $0.kind == .label }?.spoken, "Alpha, 1 open, 1 overdue")
        XCTAssertEqual(row.last?.spoken, "All tasks")
    }

    // MARK: Remembering what you opened

    func testOldTapDataWithoutDatesStillLoads() {
        let (defaults, suite) = scratchDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["Alpha", "Beta"], forKey: RecentLabels.key)
        XCTAssertEqual(RecentLabels.list(defaults), ["Alpha", "Beta"])
        XCTAssertTrue(RecentLabels.dates(defaults).isEmpty)
        let tasks = [task("b", name: "Beta"), task("a", name: "Alpha")]
        let row = HomeLabels.row(index: [entry("Beta"), entry("Alpha")], tasks: tasks, recentTaps: RecentLabels.list(defaults),
                                 tapDates: RecentLabels.dates(defaults), now: now)
        XCTAssertEqual(labels(row), ["Alpha", "Beta"])      // the old list order still breaks the tie
    }

    func testOpeningALabelKeepsTheNameAndTheDay() {
        let (defaults, suite) = scratchDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        RecentLabels.note("Alpha", at: now, in: defaults)
        RecentLabels.note("Betas", at: now.addingTimeInterval(5), in: defaults)
        RecentLabels.note("Beta", at: now.addingTimeInterval(10), in: defaults)        // one spelling, the latest
        XCTAssertEqual(RecentLabels.list(defaults), ["Beta", "Alpha"])
        let dates = RecentLabels.dates(defaults)
        XCTAssertEqual(dates[TaskLabels.stemKey("Alpha")]?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(dates[TaskLabels.stemKey("Beta")]?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970 + 10, accuracy: 0.01)
    }

    func testTheStoredDatesStaySmall() {
        var dates: [String: Date] = [:]
        for i in 0..<100 { dates = RecentLabels.dated("Label\(i)x", at: now.addingTimeInterval(Double(i)), into: dates) }
        XCTAssertLessThanOrEqual(dates.count, RecentLabels.maxCount * 3)
        XCTAssertNotNil(dates[TaskLabels.stemKey("Label99x")])
    }

    // MARK: What New shows

    func testTheNewFilterKeepsOnlyRecentTasksAndLeavesOutUndated() {
        let suite = "HomeChipTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let store = TaskStore(defaults: defaults)
        _ = store.addMany(["one", "two"])
        func shown(_ since: Date) -> Int {
            let d = store.panel(PanelFilter(who: .all, category: nil, day: .all, status: .open, addedSince: since))
            return d.overdue.count + d.due.count
        }
        XCTAssertEqual(shown(Date().addingTimeInterval(-3600)), 2)
        XCTAssertEqual(shown(Date().addingTimeInterval(3600)), 0)
    }

    // MARK: Editing a saved task

    func testUpdatingATaskChangesItInPlaceAndFollowsTheListAndDoneState() {
        let suite = "HomeChipTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let store = TaskStore(defaults: defaults)
        let made = store.addMany(["one"])[0]
        var edited = made
        edited.title = "  Call mom  "
        edited.priority = "high"
        edited.isDone = true
        XCTAssertTrue(store.update(edited))
        XCTAssertEqual(store.tasks.first { $0.id == made.id }?.title, "Call mom")
        XCTAssertEqual(store.tasks.first { $0.id == made.id }?.priority, "high")
        XCTAssertNotNil(store.tasks.first { $0.id == made.id }?.completedAt)
        let list = store.ensureProfile("Alpha").profile
        edited = store.tasks.first { $0.id == made.id }!
        edited.profileID = list.id
        edited.dueDate = nil
        store.update(edited)
        XCTAssertEqual(store.tasks.first { $0.id == made.id }?.group, "Alpha")
        edited = store.tasks.first { $0.id == made.id }!
        edited.profileID = nil
        store.update(edited)
        XCTAssertNil(store.tasks.first { $0.id == made.id }?.group)
        XCTAssertNotNil(store.tasks.first { $0.id == made.id }?.dueDate, "off its list it has a day again")
        XCTAssertFalse(store.update(TaskItem(title: "not saved")))
        XCTAssertEqual(store.tasks.count, 1)
    }

    func testTheRoutesAreOnePerChip() {
        let ids = [TasksRoute.all, .overdue, .today, .new, .label("Alpha")].map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(TasksRoute(HomeChip(name: "Today", open: 1, overdue: 0, isPerson: false, kind: .today)), .today)
        XCTAssertEqual(TasksRoute(HomeChip(name: "Alpha", open: 1, overdue: 0, isPerson: false)), .label("Alpha"))
    }

    // MARK: The tray's rows

    func testRowsAreCountedFromTheHeightOfTheChips() {
        let r = ChipTrayLevels.rowHeight, g = ChipTrayLevels.gap
        XCTAssertEqual(ChipTrayLevels.rows(forHeight: 0), 0)
        XCTAssertEqual(ChipTrayLevels.rows(forHeight: r), 1)
        XCTAssertEqual(ChipTrayLevels.rows(forHeight: 2 * r + g), 2)
        XCTAssertEqual(ChipTrayLevels.rows(forHeight: 5 * r + 4 * g), 5)
    }

    func testAHeightForRowsMatchesTheRowsCountedBack() {
        for n in 1...8 {
            XCTAssertEqual(ChipTrayLevels.rows(forHeight: ChipTrayLevels.height(rows: n) - ChipTrayLevels.shadowRoom), n)
        }
        XCTAssertEqual(ChipTrayLevels.height(rows: 0), 0)
    }

    func testChipsAreDealtIntoTheShortestRowInOrder() {
        let packed = ChipTrayLevels.pack(widths: [100, 100, 100, 100, 100], rows: 2, spacing: 8)
        XCTAssertEqual(packed, [[0, 2, 4], [1, 3]])
        XCTAssertEqual(ChipTrayLevels.pack(widths: [200, 50, 50, 50], rows: 2, spacing: 8), [[0], [1, 2, 3]])      // the long one stays alone
        XCTAssertEqual(ChipTrayLevels.pack(widths: [10, 10], rows: 4, spacing: 8), [[0], [1], [], []])
        XCTAssertEqual(ChipTrayLevels.pack(widths: [], rows: 2, spacing: 8), [[], []])
    }

    func testEveryChipIsInExactlyOneRow() {
        let widths: [CGFloat] = (0..<17).map { CGFloat(60 + ($0 * 37) % 140) }
        for rows in 1...6 {
            let packed = ChipTrayLevels.pack(widths: widths, rows: rows)
            XCTAssertEqual(packed.flatMap { $0 }.sorted(), Array(0..<widths.count))
        }
    }

    func testMoreRowsMakeTheContentNarrower() {
        let widths: [CGFloat] = Array(repeating: 100, count: 12)
        let w = (1...6).map { ChipTrayLevels.contentWidth(widths: widths, rows: $0) }
        XCTAssertEqual(w, w.sorted(by: >))
        XCTAssertEqual(w[0], 12 * 100 + 11 * 8)
    }

    func testTheFewestRowsThatFit() {
        let widths: [CGFloat] = Array(repeating: 100, count: 8)          // one row is 856 wide
        XCTAssertEqual(ChipTrayLevels.rowsToFit(widths: widths, available: 900), 1)
        XCTAssertEqual(ChipTrayLevels.rowsToFit(widths: widths, available: 430), 2)       // two rows of four are 424 wide
        XCTAssertEqual(ChipTrayLevels.rowsToFit(widths: widths, available: 400), 3)       // too narrow for that: three rows of 316
        XCTAssertEqual(ChipTrayLevels.rowsToFit(widths: widths, available: 210), 4)
        XCTAssertEqual(ChipTrayLevels.rowsToFit(widths: widths, available: 10), 6)        // never past the limit
        XCTAssertEqual(ChipTrayLevels.rowsToFit(widths: [100, 100], available: 10), 2)    // nor past the number of chips
        XCTAssertEqual(ChipTrayLevels.rowsToFit(widths: [], available: 300), 0)
    }

    func testADragSettlesOnWholeRowsWithinTheLimits() {
        let h = ChipTrayLevels.height(rows:)
        XCTAssertEqual(ChipTrayLevels.snap(height: h(3), maxRows: 5), 3)
        XCTAssertEqual(ChipTrayLevels.snap(height: h(3) + 10, maxRows: 5), 3)
        XCTAssertEqual(ChipTrayLevels.snap(height: h(3) + 40, maxRows: 5), 4)
        XCTAssertEqual(ChipTrayLevels.snap(height: h(9), maxRows: 5), 5)
        XCTAssertEqual(ChipTrayLevels.snap(height: 1, maxRows: 5), 1)
        XCTAssertEqual(ChipTrayLevels.snap(height: h(2), maxRows: 0), 0)
    }

    func testASnapDuringADragHoldsUntilWellPastTheBoundary() {
        let h = ChipTrayLevels.height(rows:)
        XCTAssertEqual(ChipTrayLevels.snap(height: h(3) + 30, from: 3, maxRows: 5), 3)      // past the midpoint, inside the slack
        XCTAssertEqual(ChipTrayLevels.snap(height: h(3) + 40, from: 3, maxRows: 5), 4)
        XCTAssertEqual(ChipTrayLevels.snap(height: h(3) - 30, from: 3, maxRows: 5), 3)
        XCTAssertEqual(ChipTrayLevels.snap(height: h(3) - 40, from: 3, maxRows: 5), 2)
        XCTAssertEqual(ChipTrayLevels.snap(height: h(5), from: 1, maxRows: 5), 5)           // a fast drag goes straight there
        XCTAssertEqual(ChipTrayLevels.snap(height: h(2), from: 2, maxRows: 0), 0)
    }

    func testTappingTheDashOpensAllTheWayAndBack() {
        XCTAssertEqual(ChipTrayLevels.tapped(rows: 2, maxRows: 5), 5)
        XCTAssertEqual(ChipTrayLevels.tapped(rows: 4, maxRows: 5), 5)
        XCTAssertEqual(ChipTrayLevels.tapped(rows: 5, maxRows: 5), 2)
        XCTAssertEqual(ChipTrayLevels.tapped(rows: 1, maxRows: 1), 1)
        XCTAssertEqual(ChipTrayLevels.tapped(rows: 1, maxRows: 0), 0)
    }

    func testAdjustingAddsOrRemovesOneRow() {
        XCTAssertEqual(ChipTrayLevels.adjusted(rows: 2, by: 1, maxRows: 4), 3)
        XCTAssertEqual(ChipTrayLevels.adjusted(rows: 4, by: 1, maxRows: 4), 4)
        XCTAssertEqual(ChipTrayLevels.adjusted(rows: 1, by: -1, maxRows: 4), 1)
    }

    // MARK: Multi-line messages keep their line breaks in the conversation

    private func shown(_ text: String) -> String {
        SpokenText.pieces(text).map { $0.separator + $0.word }.joined()
    }

    func testTypedLineBreaksSurviveDisplay() {
        let typed = "Pharmacy list\nDo this that\nAnd this"
        XCTAssertEqual(shown(typed), typed)
        XCTAssertEqual(shown(typed).filter { $0 == "\n" }.count, 2)
    }

    func testSpacesCollapseButBreaksStay() {
        XCTAssertEqual(shown("buy   milk \n\n  and  eggs  "), "buy milk\n\nand eggs")
        XCTAssertEqual(shown("  one two"), "one two")
    }

    func testTailKeepsBreaksAfterCommittedWords() {
        let typed = "one two\nthree four\nfive"
        XCTAssertEqual(SpokenText.tail(of: typed, droppingWords: 0), typed)
        XCTAssertEqual(SpokenText.tail(of: typed, droppingWords: 2), "three four\nfive")
        XCTAssertEqual(SpokenText.tail(of: typed, droppingWords: 4), "five")
        XCTAssertEqual(SpokenText.tail(of: typed, droppingWords: 9), "")
    }
}
