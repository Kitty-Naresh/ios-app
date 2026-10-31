import CryptoKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - The home screen's label chips

/// The labels you tapped, most recent first. Kept as a short list of names, so a label you open often is first the next time,
/// and as the day each was last opened, so a label you opened this week outranks one you opened long ago.
nonisolated enum RecentLabels {
    static let key = "kitty.recentLabels"
    static let datesKey = "kitty.recentLabelDates"
    static let maxCount = 12
    /// A tap counts as "recent" for this long.
    static let recentDays = 7

    static func list(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// When each label was last opened, by `TaskLabels.stemKey`. Lists saved before dates were kept simply have none.
    static func dates(_ defaults: UserDefaults = .standard) -> [String: Date] {
        let raw = defaults.dictionary(forKey: datesKey) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// `name` moved to the front of `list` (one spelling, "Househelp" and "house help" count as one), capped.
    static func merged(_ name: String, into list: [String]) -> [String] {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return list }
        var out = [clean] + list.filter { !TaskLabels.same($0, clean) }
        if out.count > maxCount { out = Array(out.prefix(maxCount)) }
        return out
    }

    /// `dates` with `name` opened at `at`, keeping only the newest few so the stored dictionary stays small.
    static func dated(_ name: String, at: Date, into dates: [String: Date]) -> [String: Date] {
        let k = TaskLabels.stemKey(name)
        guard !k.isEmpty else { return dates }
        var out = dates
        out[k] = at
        if out.count > maxCount * 3 {
            let keep = out.sorted { $0.value > $1.value }.prefix(maxCount * 3).map(\.key)
            out = out.filter { keep.contains($0.key) }
        }
        return out
    }

    static func note(_ name: String, at date: Date = .now, in defaults: UserDefaults = .standard) {
        defaults.set(merged(name, into: list(defaults)), forKey: key)
        let updated = dated(name, at: date, into: dates(defaults))
        defaults.set(updated.mapValues { $0.timeIntervalSince1970 }, forKey: datesKey)
    }
}

/// One chip on the home screen: a smart view (overdue, today, new, all) or a tag with open tasks.
nonisolated struct HomeChip: Equatable, Identifiable {
    enum Kind: String, Equatable { case overdue, today, new, all, label }

    var name: String
    var open: Int
    var overdue: Int
    var isPerson: Bool
    var kind: Kind = .label
    /// For a label: the kind of thing it mostly is (a list, a category), so the chip can carry the right icon. Nil for a person.
    var isList = false
    var isCategory = false
    /// For a label: the newest thing on it (a list's creation or its newest task's), used to rank it.
    var newest: Date? = nil

    var id: String { kind == .label ? TaskLabels.stemKey(name) : "view:" + kind.rawValue }
    var hasOverdue: Bool { kind == .label && overdue > 0 }

    /// What VoiceOver says: "Househelp, 7 open, 2 overdue", "Overdue, 3".
    var spoken: String {
        switch kind {
        case .all: return "All tasks"
        case .overdue, .today, .new: return "\(name), \(open)"
        case .label: return "\(name), \(open) open" + (overdue > 0 ? ", \(overdue) overdue" : "")
        }
    }
}

/// Which chips the home screen offers, and in what order. Everything is read from the tasks in memory: no model, no waiting.
nonisolated enum HomeLabels {
    /// How many labels the home row (and the switcher inside a label) holds. The row scrolls, so this is generous.
    static let limit = 14
    /// "New" means created within this many days.
    static let newDays = 7

    /// How many open tasks carry `name`, and how many of those are from an earlier day.
    static func stats(for name: String, in tasks: [TaskItem]) -> (open: Int, overdue: Int) {
        var open = 0, overdue = 0
        for t in tasks where !t.isDone && t.hasTag(name) {
            open += 1
            if t.isOverdue { overdue += 1 }
        }
        return (open, overdue)
    }

    /// The first moment a task counts as "new".
    static func newSince(now: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -newDays, to: now) ?? now
    }

    /// The whole row, left to right: Overdue and Today (only when something is there), New, then your labels, then All.
    /// A chip with nothing behind it is not in the row.
    static func row(index: [TagEntry], tasks: [TaskItem], profiles: [TaskProfile] = [], recentTaps: [String] = [],
                    tapDates: [String: Date] = [:], now: Date = .now, calendar: Calendar = .current,
                    limit: Int = HomeLabels.limit) -> [HomeChip] {
        let open = tasks.filter { !$0.isDone }
        let late = open.filter(\.isOverdue).count
        let today = open.filter { !$0.isListItem && calendar.isDate($0.effectiveDue, inSameDayAs: now) }.count
        let since = newSince(now: now, calendar: calendar)
        let fresh = open.filter { ($0.createdAt ?? .distantPast) >= since }.count

        var out: [HomeChip] = []
        func smart(_ kind: HomeChip.Kind, _ name: String, _ count: Int) {
            guard count > 0 else { return }
            out.append(HomeChip(name: name, open: count, overdue: 0, isPerson: false, kind: kind))
        }
        smart(.overdue, "Overdue", late)
        smart(.today, "Today", today)
        smart(.new, "New", fresh)
        out += chips(index: index, tasks: tasks, recentTaps: recentTaps, limit: limit, profiles: profiles, tapDates: tapDates, now: now)
        out.append(HomeChip(name: "All", open: open.count, overdue: 0, isPerson: false, kind: .all))
        return out
    }

    /// The labels: tags with at least one open task. Labels opened in the last week come first (latest first), then the rest by
    /// the newest thing on them (a list's creation or its newest task), then by how many open tasks, then by name.
    static func chips(index: [TagEntry], tasks: [TaskItem], recentTaps: [String], limit: Int = HomeLabels.limit,
                      profiles: [TaskProfile] = [], tapDates: [String: Date] = [:], now: Date = .now) -> [HomeChip] {
        struct Ranked { var chip: HomeChip; var tapped: Int?; var recentTap: Date?; var position: Int }
        let openTasks = tasks.enumerated().filter { !$0.element.isDone }
        let cutoff = now.addingTimeInterval(-Double(RecentLabels.recentDays) * 86_400)
        var seen = Set<String>()
        var ranked: [Ranked] = []
        for entry in index {
            let key = TaskLabels.stemKey(entry.name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            var open = 0, overdue = 0
            var position = Int.max
            var newest: Date?
            for (at, t) in openTasks where t.hasTag(entry.name) {
                open += 1
                if t.isOverdue { overdue += 1 }
                position = min(position, at)
                if let c = t.createdAt, newest.map({ c > $0 }) ?? true { newest = c }
            }
            guard open > 0 else { continue }
            for p in profiles where TaskLabels.same(p.name, entry.name) {
                if newest.map({ p.createdAt > $0 }) ?? true { newest = p.createdAt }
            }
            let tapped = recentTaps.firstIndex { TaskLabels.same($0, entry.name) }
            let tapDate = tapDates[key].flatMap { $0 >= cutoff ? $0 : nil }
            var chip = HomeChip(name: entry.name, open: open, overdue: overdue, isPerson: entry.kinds.contains(.person))
            chip.isList = !chip.isPerson && entry.kinds.contains(.list)
            chip.isCategory = !chip.isPerson && !chip.isList && entry.kinds.contains(.category)
            chip.newest = newest
            ranked.append(Ranked(chip: chip, tapped: tapped, recentTap: tapDate, position: position))
        }
        ranked.sort { a, b in
            switch (a.recentTap, b.recentTap) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            switch (a.chip.newest, b.chip.newest) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            switch (a.tapped, b.tapped) {            // taps saved before dates were kept: their order still counts
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            if a.position != b.position { return a.position < b.position }
            if a.chip.open != b.chip.open { return a.chip.open > b.chip.open }
            return a.chip.name.lowercased() < b.chip.name.lowercased()
        }
        return Array(ranked.prefix(limit).map(\.chip))
    }
}

/// The arithmetic behind the home chip tray. The tray packs the chips into a number of rows (two to start), scrolls sideways when they
/// do not fit, and you drag a handle to change the number of rows. At some number of rows everything fits and the sideways scroll goes
/// away. Pure functions over widths, so the packing is easy to check.
nonisolated enum ChipTrayLevels {
    static let rowHeight: CGFloat = 44
    static let gap: CGFloat = 8
    /// Extra room around the rows so a chip's shadow is not cut off.
    static let shadowRoom: CGFloat = 6
    /// The tray never grows past this many rows.
    static let rowLimit = 6
    /// Where the tray starts, until you drag it.
    static let startRows = 2

    /// How many rows a stack of chips `height` tall holds.
    static func rows(forHeight height: CGFloat) -> Int {
        guard height > 0 else { return 0 }
        return max(1, Int(((height + gap) / (rowHeight + gap)).rounded()))
    }

    /// The height of `rows` rows, with the room for a shadow.
    static func height(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * gap + shadowRoom
    }

    /// How wide one row of chips is.
    static func rowWidth(_ row: [Int], widths: [CGFloat], spacing: CGFloat = gap) -> CGFloat {
        guard !row.isEmpty else { return 0 }
        return row.reduce(0) { $0 + widths[$1] } + spacing * CGFloat(row.count - 1)
    }

    /// The chips dealt into `rows` rows, in order, each into the row that is shortest so far (the first of them when tied). The rows
    /// stay about as long as each other, and the first chips, the ones that matter most, are at the left of the top rows.
    static func pack(widths: [CGFloat], rows: Int, spacing: CGFloat = gap) -> [[Int]] {
        let count = max(rows, 1)
        var out = Array(repeating: [Int](), count: count)
        var used = Array(repeating: CGFloat(0), count: count)
        for (i, w) in widths.enumerated() {
            var best = 0
            for r in 1..<count where used[r] < used[best] { best = r }
            out[best].append(i)
            used[best] += w + spacing
        }
        return out
    }

    /// The width of the widest row.
    static func contentWidth(widths: [CGFloat], rows: Int, spacing: CGFloat = gap) -> CGFloat {
        pack(widths: widths, rows: rows, spacing: spacing).map { rowWidth($0, widths: widths, spacing: spacing) }.max() ?? 0
    }

    /// The fewest rows in which every chip fits across `available` without scrolling sideways. If even `limit` rows do not hold them,
    /// `limit` (or the number of chips, if fewer). 0 for no chips.
    static func rowsToFit(widths: [CGFloat], available: CGFloat, spacing: CGFloat = gap, limit: Int = rowLimit) -> Int {
        guard !widths.isEmpty else { return 0 }
        let most = max(1, min(limit, widths.count))
        for r in 1...most where contentWidth(widths: widths, rows: r, spacing: spacing) <= available { return r }
        return most
    }

    /// The rows the tray settles on when a drag ends with the tray `height` tall: whole rows, never more than fit or less than one.
    static func snap(height: CGFloat, maxRows: Int) -> Int {
        guard maxRows > 0 else { return 0 }
        return min(max(rows(forHeight: height - shadowRoom), 1), maxRows)
    }

    /// The rows to show while a finger drags: `current` stays until the height is `slack` points past the halfway point to the next row, so
    /// a finger resting near a boundary does not flip the chips between two arrangements. A big move still goes straight to the right row.
    static func snap(height: CGFloat, from current: Int, maxRows: Int, slack: CGFloat = 10) -> Int {
        guard maxRows > 0 else { return 0 }
        let held = min(max(current, 1), maxRows)
        let target = snap(height: height, maxRows: maxRows)
        guard target != held else { return held }
        return abs(height - self.height(rows: held)) >= (rowHeight + gap) / 2 + slack ? target : held
    }

    /// A tap on the handle: open all the way, or from there back to the start.
    static func tapped(rows: Int, maxRows: Int) -> Int {
        guard maxRows > 0 else { return 0 }
        return rows < maxRows ? maxRows : min(startRows, maxRows)
    }

    /// One row more or fewer (VoiceOver's adjust), kept between one and `maxRows`.
    static func adjusted(rows: Int, by step: Int, maxRows: Int) -> Int {
        guard maxRows > 0 else { return 0 }
        return min(max(rows + step, 1), maxRows)
    }
}

/// The groups in a label's task list, in the order shown: what is current first, the overdue backlog last (the same rule the
/// task panel follows after a question). Empty groups are dropped, so every heading has tasks under it.
nonisolated enum LabelSections {
    enum Kind: Equatable { case today, comingUp, overdue }

    struct Group {
        var kind: Kind
        var tasks: [TaskItem]
    }

    static func make(overdue: [TaskItem], due: [TaskItem], today: Date = Calendar.current.startOfDay(for: .now),
                     calendar: Calendar = .current) -> [Group] {
        let current = due.filter { calendar.isDate($0.effectiveDue, inSameDayAs: today) }
        let later = due.filter { !calendar.isDate($0.effectiveDue, inSameDayAs: today) }
        return [Group(kind: .today, tasks: current), Group(kind: .comingUp, tasks: later), Group(kind: .overdue, tasks: overdue)]
            .filter { !$0.tasks.isEmpty }
    }
}

// MARK: - How a task was made: kept with the task, shown by "See details"

/// The turns behind the tasks one reply created, kept in one JSON file (prompts are several KB, so not in UserDefaults) and
/// deleted with the tasks. Tasks made by the same reply share one bundle, so a prompt is stored once.
@MainActor
final class TaskDetailsStore {
    static let shared = TaskDetailsStore(url: TaskDetailsStore.defaultURL)

    fileprivate struct Payload: Codable {
        var bundles: [UUID: [TaskTurnRecord]] = [:]
        var index: [UUID: UUID] = [:]            // task id -> bundle id
        var instructions: [String: String] = [:] // one copy of each instruction text, by key (every call carries the same ~3.5 KB)

        init() {}

        /// Files saved before instruction texts were shared still load.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bundles = try c.decode([UUID: [TaskTurnRecord]].self, forKey: .bundles)
            index = try c.decode([UUID: UUID].self, forKey: .index)
            instructions = try c.decodeIfPresent([String: String].self, forKey: .instructions) ?? [:]
        }
    }

    private let url: URL?
    private var payload: Payload

    /// `url` nil keeps everything in memory (tests).
    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Payload.self, from: data) {
            payload = saved
        } else {
            payload = Payload()
        }
    }

    nonisolated static var defaultURL: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return dir.appendingPathComponent("task-details.json")
    }

    func has(_ id: UUID) -> Bool { payload.index[id] != nil }

    func records(for id: UUID) -> [TaskTurnRecord] {
        let saved = payload.index[id].flatMap { payload.bundles[$0] } ?? []
        // Put each call's instruction text back.
        return saved.map { record in
            var record = record
            record.calls = record.calls.map { call in
                var call = call
                if call.instructions.isEmpty, let key = call.instructionsKey { call.instructions = payload.instructions[key] ?? "" }
                return call
            }
            return record
        }
    }

    /// A short stable key for an instruction text.
    static func key(for text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    var isEmpty: Bool { payload.index.isEmpty }
    /// How many distinct instruction texts are on file (one copy each).
    var storedInstructionCount: Int { payload.instructions.count }

    /// Keep these turns with these tasks. Nothing is stored when there are no turns (the switch was off) or no tasks.
    func attach(_ records: [TaskTurnRecord], to ids: [UUID]) {
        guard !records.isEmpty, !ids.isEmpty else { return }
        let bundle = UUID()
        // Keep one copy of each instruction text and point the calls at it.
        payload.bundles[bundle] = records.map { record in
            var record = record
            record.calls = record.calls.map { call in
                var call = call
                if !call.instructions.isEmpty {
                    let key = Self.key(for: call.instructions)
                    payload.instructions[key] = call.instructions
                    call.instructionsKey = key
                    call.instructions = ""
                }
                return call
            }
            return record
        }
        for id in ids { payload.index[id] = bundle }
        write()
    }

    /// Forget the tasks that no longer exist, and any turns nobody points to.
    func prune(keeping alive: Set<UUID>) {
        guard !payload.index.isEmpty else { return }
        let gone = payload.index.keys.filter { !alive.contains($0) }
        guard !gone.isEmpty else { return }
        for id in gone { payload.index[id] = nil }
        let used = Set(payload.index.values)
        payload.bundles = payload.bundles.filter { used.contains($0.key) }
        let keys = Set(payload.bundles.values.flatMap { $0.flatMap { $0.calls.compactMap(\.instructionsKey) } })
        payload.instructions = payload.instructions.filter { keys.contains($0.key) }        // texts nobody points to
        write()
    }

    func clear() {
        payload = Payload()
        write()
    }

    private func write() {
        guard let url else { return }
        if payload.index.isEmpty { try? FileManager.default.removeItem(at: url); return }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true       // household names and tasks: keep them out of iCloud backups
        var target = url
        try? target.setResourceValues(values)
    }
}

/// The five steps shown in the details sheet, in order.
nonisolated enum DetailSection: String, CaseIterable, Identifiable {
    case youSaid, sentToModel, modelReplied, swiftChecked, savedAs
    var id: String { rawValue }

    var title: String {
        switch self {
        case .youSaid: return "You said"
        case .sentToModel: return "Sent to the model"
        case .modelReplied: return "The model replied"
        case .swiftChecked: return "What Swift checked"
        case .savedAs: return "Saved as"
        }
    }

    var symbol: String {
        switch self {
        case .youSaid: return "mic.fill"
        case .sentToModel: return "arrow.up.circle.fill"
        case .modelReplied: return "arrow.down.circle.fill"
        case .swiftChecked: return "checkmark.shield.fill"
        case .savedAs: return "tray.and.arrow.down.fill"
        }
    }

    /// What is shown when nothing happened in this step, so no card is ever blank.
    var empty: String {
        switch self {
        case .youSaid: return "No words were recorded."
        case .sentToModel: return "Not sent: Swift's rules handled this without the model."
        case .modelReplied: return "The model gave no answer for this turn."
        case .swiftChecked: return "Swift made no changes."
        case .savedAs: return "Nothing was recorded."
        }
    }
}

/// How a check line reads: dropped, added or kept.
nonisolated enum CheckKind: Equatable {
    case dropped, added, kept, info
}

nonisolated enum TaskDetailsFormat {
    static func section(of stage: String) -> DetailSection {
        switch stage {
        case "HEARD", "CLEANED": return .youSaid
        case "TO MODEL": return .sentToModel
        case "FROM MODEL": return .modelReplied
        case "RESULT", "SAVED": return .savedAs
        default: return .swiftChecked              // SWIFT, CHECKS, WARNING, CLARIFY, RULES, GATES, STRIP, ROUTE
        }
    }

    /// The four steps of one turn, always all present and in order, each with its stages (possibly none).
    static func sections(for record: TaskTurnRecord) -> [(section: DetailSection, stages: [TraceStage])] {
        DetailSection.allCases.map { s in (s, record.stages.filter { section(of: $0.stage) == s }) }
    }

    /// "Model call 1, ..." on the first line; the prompt or the reply after it.
    static func split(_ text: String) -> (summary: String, body: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return (lines.first ?? "", lines.dropFirst().joined(separator: "\n"))
    }

    /// `title "Buy milk" | category home` into rows. A line without " | " is one row with the text before its first colon as the key.
    static func fields(of line: String) -> [(key: String, value: String)] {
        let parts = line.components(separatedBy: " | ")
        if parts.count == 1 {
            if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 14 {
                return [(String(line[..<colon]), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))]
            }
            return [("", line)]
        }
        return parts.map { part in
            if let space = part.firstIndex(of: " ") {
                return (String(part[..<space]), String(part[part.index(after: space)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"")))
            }
            return ("", part)
        }
    }

    static func checkKind(_ text: String) -> CheckKind {
        let t = text.lowercased()
        if t.contains("dropped") || t.contains("refused") { return .dropped }
        if t.contains("added by swift") || t.contains("swift saw") { return .added }
        if t.hasPrefix("task kept") || t.contains("(unchanged)") { return .kept }
        return .info
    }

    /// The whole thing as text, for sharing in a bug report.
    static func plainText(task: TaskItem, records: [TaskTurnRecord]) -> String {
        var out = ["How Kitty made \"\(task.title)\""]
        for (n, record) in records.enumerated() {
            out.append("")
            out.append("=== Turn \(n + 1) of \(records.count): \"\(record.utterance)\" (\(record.route)) ===")
            for (section, stages) in sections(for: record) where section != .savedAs {
                out.append("")
                out.append("-- \(section.title) --")
                if stages.isEmpty { out.append(section.empty) }
                for s in stages { out.append("[\(s.stage)] \(s.text)") }
            }
            if !record.result.isEmpty { out.append(""); out.append("-- Kitty said --"); out.append(record.result) }
        }
        out.append("")
        out.append("-- Saved as --")
        out.append(contentsOf: savedRows(task).map { "\($0.key): \($0.value)" })
        return out.joined(separator: "\n")
    }

    // MARK: The complete trace

    /// The turns, plus one more record for the model calls made while saving (nothing extra when there were none).
    static func withSavingCalls(_ records: [TaskTurnRecord], calls: [ModelCallRecord]) -> [TaskTurnRecord] {
        calls.isEmpty ? records : records + [TaskTurnRecord(route: "saving", calls: calls)]
    }

    struct TimelineItem: Identifiable {
        enum Kind {
            case header(String)
            case step(TraceStage)
            case call(ModelCallRecord, number: Int)
        }
        let id: Int
        let kind: Kind
    }

    /// Everything in the order it happened: each turn's header, then its Swift steps and its model calls merged by time, then
    /// the calls made while saving. A turn that has recorded calls shows them, not the shorter `TO MODEL` / `FROM MODEL` lines.
    static func timeline(for records: [TaskTurnRecord]) -> [TimelineItem] {
        var kinds: [TimelineItem.Kind] = []
        var callNumber = 0
        let turns = records.filter { $0.route != "saving" }.count
        var turn = 0
        for record in records {
            if record.route == "saving" {
                kinds.append(.header("While saving"))
            } else {
                turn += 1
                let words = record.utterance.isEmpty ? "" : ": “\(record.utterance)”"
                kinds.append(.header((turns > 1 ? "Turn \(turn) of \(turns)" : "The turn") + words))
            }
            let hasCalls = !record.calls.isEmpty
            var merged: [(at: Date, rank: Int, index: Int, kind: TimelineItem.Kind)] = []
            for (i, st) in record.stages.enumerated() where !(hasCalls && (st.stage == "TO MODEL" || st.stage == "FROM MODEL")) {
                merged.append((st.at, 0, i, .step(st)))
            }
            for (i, call) in record.calls.enumerated() { merged.append((call.started, 1, i, .call(call, number: 0))) }
            merged.sort { ($0.at, $0.rank, $0.index) < ($1.at, $1.rank, $1.index) }
            for item in merged {
                if case .call(let call, _) = item.kind {
                    callNumber += 1
                    kinds.append(.call(call, number: callNumber))
                } else {
                    kinds.append(item.kind)
                }
            }
        }
        return kinds.enumerated().map { TimelineItem(id: $0.offset, kind: $0.element) }
    }

    /// One model call as plain text, word for word: instructions, schema, tools, history, prompt, token counts, the writing log,
    /// the reply (or what was written before it stopped) and how it ended.
    static func text(of call: ModelCallRecord, number: Int) -> String {
        let d = call.detail
        var out = ["MODEL CALL \(number): \(call.kind) | \(call.mode) | schema \(call.schema.isEmpty ? "none" : call.schema) | "
                   + String(format: "%.1f s", call.seconds)]
        out.append("--- INSTRUCTIONS (\(call.instructions.count) chars) ---")
        out.append(call.instructions.isEmpty ? "(none recorded)" : call.instructions)
        if let d, !d.schemaJSON.isEmpty {
            out.append("--- SCHEMA (\(d.schemaJSON.count) chars; as the model is held to it) ---")
            out.append(d.schemaJSON)
        }
        if let d {
            out.append("--- TOOLS (\(d.tools.count)) ---")
            if d.tools.isEmpty { out.append("(none: this call had no tools)") }
            for t in d.tools {
                out.append("\(t.name): \(t.description)")
                out.append(t.parameters)
            }
        }
        out.append("--- SESSION HISTORY (\(call.history.count) entries) ---")
        if call.history.isEmpty { out.append("(empty: a new session)") }
        for entry in call.history { out.append("[\(entry.role)]"); out.append(entry.text) }
        out.append("--- PROMPT (\(call.prompt.count) chars) ---")
        out.append(call.prompt)
        if let d {
            let t = d.tokens
            func n(_ v: Int?) -> String { v.map { $0.formatted() } ?? "not counted yet" }
            let how = t.exact ? "counted by the model" : "estimated at 3.5 characters a token"
            out.append("--- TOKEN COUNTS (each line says whether it was counted or estimated) ---")
            out.append("instructions \(n(t.instructions)) (\(how))")
            out.append("schema \(n(t.schema)) (\(how))")
            out.append("tools \(n(t.tools)) (\(how))")
            out.append("prompt \(n(t.prompt)) (\(how))")
            out.append("answer \(n(t.reply)) (\(t.replyExact == true ? "counted by the model" : "estimated at 3.5 characters a token"))")
            out.append("sent in total \(t.sent.formatted()) | window \(t.window.formatted()) | left after what was sent and written \(t.left.formatted())")
            out.append("output cap: \(d.limit.isEmpty ? "none" : d.limit)")
            out.append("--- GENERATION ---")
            out.append("settings: \(d.settings ?? "not recorded")")
            out.append("schema version: \(d.schemaVersion ?? "not recorded")")
            out.append("completion: \(d.completion ?? "not recorded")")
            if let by = d.cancelledBy { out.append("ended by: \(by)") }
            out.append("--- WRITING LOG (\(d.writing.count) snapshots, at most one every \(LiveFeed.writingInterval) s) ---")
            if d.writing.isEmpty { out.append("(nothing was written)") }
            for p in d.writing {
                out.append(String(format: "+%.1f s | %@ chars | ~%@ tokens | %d items", p.at, p.characters.formatted(), p.tokens.formatted(), p.items))
            }
        }
        let finished = call.error == nil && !call.rawReply.isEmpty
        out.append(finished ? "--- RAW REPLY ---" : "--- PARTIAL REPLY (written before it stopped) ---")
        if finished { out.append(call.rawReply) }
        else { out.append((d?.partialReply.isEmpty == false ? d?.partialReply : nil) ?? "(none)") }
        if let error = call.error { out.append("--- ERROR ---"); out.append(error) }
        if let d { out.append("--- OUTCOME ---"); out.append(d.outcome) }
        return out.joined(separator: "\n")
    }

    /// The whole trace, exact and in order, for sharing.
    static func fullTrace(task: TaskItem, records: [TaskTurnRecord]) -> String {
        var out = ["Complete trace for \"\(task.title)\""]
        for item in timeline(for: records) {
            out.append("")
            switch item.kind {
            case .header(let title): out.append("=== \(title) ===")
            case .step(let st): out.append("[\(st.stage)] \(st.text)")
            case .call(let call, let number): out.append(text(of: call, number: number))
            }
        }
        out.append("")
        out.append("=== Saved as ===")
        out.append(contentsOf: savedRows(task).map { "\($0.key): \($0.value)" })
        return out.joined(separator: "\n")
    }

    /// The task as stored, one row per field that has a value.
    static func savedRows(_ t: TaskItem) -> [(key: String, value: String)] {
        var rows: [(String, String)] = [("Title", t.title)]
        if !t.categoryLabel.isEmpty { rows.append(("Category", t.categoryLabel)) }
        if !t.effectiveAssignee.isEmpty { rows.append(("For", t.effectiveAssignee)) }
        rows.append(("Due", t.dueLabel))
        if let r = t.reason, !r.isEmpty { rows.append(("Reason", r)) }
        if let n = t.notes, !n.isEmpty { rows.append(("Notes", n)) }
        if let said = UtteranceStore.shared.utterance(t.utteranceID)?.rawText ?? t.said, !said.isEmpty { rows.append(("What you said", said)) }
        return rows
    }
}


// MARK: - The turn that is on screen, as one document to share

nonisolated enum TurnTraceFormat {
    /// The header: what build, what device, what the model's state was, and which limits and switches applied.
    static func header(began: Date?, turn: Int, now: Date = Date()) -> [String] {
        var out = ["KITTY TRACE", "Captured \(now.formatted(date: .abbreviated, time: .standard))" + (began.map { ", \(Int(now.timeIntervalSince($0))) s after turn \(turn) began" } ?? "")]
        out.append(contentsOf: TurnEnvironment.lines())
        return out
    }

    private static func offset(_ date: Date, from began: Date?) -> String {
        guard let began, date != .distantPast else { return "     " }
        return String(format: "+%.1f s", max(0, date.timeIntervalSince(began)))
    }

    /// The whole turn: header, the timeline (Swift's steps and the model calls merged by time), then each call in full.
    /// Built when it is asked for, so it can be taken while a call is still in progress.
    static func text(snapshot: TurnCapture.Snapshot = TurnCapture.shared.snapshot, now: Date = Date()) -> String {
        var out = header(began: snapshot.began, turn: snapshot.turn, now: now)
        out.append("")
        out.append("=== TIMELINE ===")
        if snapshot.stages.isEmpty && snapshot.calls.isEmpty { out.append("(nothing has happened yet)") }
        var merged: [(at: Date, rank: Int, index: Int, line: String)] = []
        for (i, st) in snapshot.stages.enumerated() {
            let body: String
            if st.stage == "TO MODEL" || st.stage == "FROM MODEL" {
                body = TaskDetailsFormat.split(st.text).summary + (st.text.contains("\n") ? " (full text under the model call)" : "")
            } else { body = st.text }
            merged.append((st.at, 0, i, "[\(offset(st.at, from: snapshot.began))] \(st.stage) \(body)"))
        }
        for (i, call) in snapshot.calls.enumerated() {
            // Two lines, each at its own time: a call's outcome belongs to the moment it ended, not the moment it began.
            merged.append((call.started, 1, i, "[\(offset(call.started, from: snapshot.began))] MODEL CALL \(i + 1) begins: \(call.kind)"))
            let outcome = call.detail?.outcome ?? "in progress"
            if outcome == "in progress" {
                merged.append((call.started, 2, i, "[     ] MODEL CALL \(i + 1) is still running"))
            } else {
                let end = call.started.addingTimeInterval(call.seconds)
                merged.append((end, 2, i, "[\(offset(end, from: snapshot.began))] MODEL CALL \(i + 1) ended after \(String(format: "%.1f", call.seconds)) s: \(outcome)"))
            }
        }
        merged.sort { ($0.at, $0.rank, $0.index) < ($1.at, $1.rank, $1.index) }
        out.append(contentsOf: merged.map(\.line))
        out.append("")
        if snapshot.calls.isEmpty { out.append("No model call was made in this turn.") }
        for (i, call) in snapshot.calls.enumerated() {
            out.append("")
            out.append("=== MODEL CALL \(i + 1) of \(snapshot.calls.count) ===")
            out.append(TaskDetailsFormat.text(of: call, number: i + 1))
        }
        return out.joined(separator: "\n")
    }
}
