import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Results

struct PlanResult {
    var tasks: [PlannedTask]
    var usedAI: Bool
}

struct AgentReply {
    var message: String
    var didAdd: Bool
    var didChange: Bool = false
    var expectsReply: Bool = false     // Kitty asked a yes/no question
    var spec: TaskLookupSpec? = nil    // set for questions: the lookup used, so the screen can show the same view
    var created: [UUID] = []           // tasks this reply created, shown as cards in the conversation
    var hint: String? = nil            // an optional, one-time suggestion to narrow a long list (already part of `message`)
}

enum AgentAction { case add, ask, chat, complete, reopen, rename, delete, clear, teach, assign, reschedule, profile }

/// A playbook as understood from what the user said.
struct PlaybookResult {
    var name: String
    var category: TaskCategory
    var steps: [PlaybookStep]
}

/// Kitty asked "add these tasks?" and is waiting for yes or no.
struct PendingPlaybook {
    var playbookID: UUID
    var due: Date
    var created: Date = .now
}

/// What the user wants done to existing tasks.
struct TaskCommand {
    var target: String = ""          // words naming the task(s), e.g. "dusting and mopping"
    var newTitle: String = ""        // rename only
    var category: TaskCategory?
    var day: DayFilter = .anytime
    var all = false                  // "all", "every", "everything"
    var newAssignee: String = ""     // assign only
    var newDue: Date?                // reschedule only
    var profileID: UUID? = nil       // the command is about items on one list
    var dropWords: Set<String> = []  // words that name that list, not an item
}

// MARK: - Planner: understands what the user said

enum TaskPlanner {
    private static let categoryNames = ["househelp", "work", "personal", "family", "errands", "health", "finance", "other"]

    nonisolated static func todayString() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, yyyy-MM-dd"
        return f.string(from: .now)
    }

    nonisolated static func parseDay(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Decide whether the user is adding tasks or asking about existing ones.
    static func route(_ text: String) async -> AgentAction {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            if let action = await aiRoute(text) { return action }
        }
        #endif
        return ruleRoute(text)
    }

    /// Is a list or order named in the sentence? ("Blinkit" when you have a "Blinkit order")
    static func mentionsList(_ text: String) -> Bool {
        let words = TaskMatcher.tokens(text)
        return KittyGuideStore.profileNames.contains { name in
            var k = TaskMatcher.tokens(name, dropping: ["order", "list", "cart", "basket", "shopping", "checklist", "wishlist", "profile"])
            if k.isEmpty { k = TaskMatcher.tokens(name) }
            return !k.isEmpty && k.allSatisfy { w in words.contains { TaskMatcher.same(w, $0) } }
        }
    }

    /// "Create a new Goa trip list", "rename my Blinkit order", "I placed the order", "clear my list", "move milk to ...".
    static func isListCommand(_ t: String) -> Bool {
        if t.contains("new list") || t.contains("new order") || t.contains("new profile") || t.contains("list called") || t.contains("list named") {
            return true
        }
        let named = ["list", "order", "cart", "basket", "checklist", "profile"].contains { t.contains($0) }
        if named, ["create ", "start ", "make ", "set up "].contains(where: { t.hasPrefix($0) }), !t.contains("task") { return true }
        guard mentionsList(t) else { return false }
        if t.hasPrefix("rename") { return true }
        if ["clear ", "empty ", "reset "].contains(where: { t.hasPrefix($0) }) { return true }
        if t.hasPrefix("move ") || t.hasPrefix("put ") { return true }
        let finished = ["placed", "ordered", "got everything", "bought everything", "have everything", "done with", "finished with"]
        return finished.contains { t.contains($0) }
    }

    static func ruleRoute(_ text: String) -> AgentAction {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = t.filter { $0.isLetter || $0.isWhitespace }
        let greetings = ["hi", "hello", "hey", "thanks", "thank you", "good morning", "good evening", "how are you", "who are you"]
        if plain.split(separator: " ").count <= 4,
           greetings.contains(where: { plain == $0 || plain.hasPrefix($0 + " ") }) {
            return .chat
        }

        // Teaching Kitty a procedure
        let teachPhrases = ["how i make", "how i cook", "how i prepare", "how we make", "how we cook", "how we prepare",
                            "playbook for", "playbook called", "playbook named", "create a playbook", "new playbook",
                            "save this as a playbook", "here's how", "heres how", "here is how", "this is how i", "this is how we"]
        let tt = t.replacingOccurrences(of: "’", with: "'")
        if teachPhrases.contains(where: { tt.contains($0) }) && !t.contains("?") { return .teach }

        // Clear completed
        if (t.hasPrefix("clear") || t.hasPrefix("remove") || t.hasPrefix("delete") || t.hasPrefix("empty"))
            && (t.contains("completed") || t.contains("finished") || t.contains("done"))
            && !plain.split(separator: " ").contains("task")
            && TaskCategory.mentioned(in: t) == nil && plain.split(separator: " ").count <= 5 {
            return .clear
        }

        // Questions
        let starters = ["what", "which", "show", "list", "tell me", "read", "do i", "how many", "anything", "any ", "who", "when", "did i"]
        if t.contains("?") || starters.contains(where: { t.hasPrefix($0) }) || t.contains("what's on") {
            return .ask
        }

        func starts(_ words: [String]) -> Bool { words.contains { t.hasPrefix($0) } }

        // Lists (profiles): create, rename, finish, empty, move
        if isListCommand(t) { return .profile }

        // Rename
        if starts(["rename"]) || (starts(["change", "edit", "update", "replace"]) && t.contains(" to ")) { return .rename }

        // Assign / reschedule
        if starts(["assign", "reassign"]) { return .assign }
        if starts(["reschedule", "postpone", "push ", "move ", "delay "]),
           t.contains(" to ") || t.contains("tomorrow") || t.contains("today") || dayNames.contains(where: { t.contains($0) }) {
            return .reschedule
        }

        // Reopen (before complete: "mark X as not done")
        if starts(["reopen", "re-open", "undo", "uncomplete", "unmark", "restore"])
            || t.contains("not done") || t.contains("not finished") || t.contains("incomplete")
            || t.contains("as pending") || t.contains("undone") {
            return .reopen
        }

        // Complete
        let doneSuffix = [" done", " completed", " finished", " complete"].contains { t.hasSuffix($0) || t.contains($0 + " ") }
        if starts(["mark", "complete", "finish", "tick", "check off", "cross off", "done with", "i finished",
                   "i completed", "i did", "i've finished", "i have finished", "i've done", "i have done"])
            || (doneSuffix && !starts(["add", "remind", "create", "schedule", "make"])) {
            return .complete
        }

        // Delete
        if starts(["delete", "remove", "cancel", "drop ", "get rid of", "discard", "erase", "scrap", "forget"]) { return .delete }

        // "househelp tasks for today" with no question word is still a lookup.
        if TaskCategory.mentioned(in: t) != nil,
           t.contains(" tasks") || t.hasSuffix("tasks") || t.contains("list") || t.contains("to do") || t.contains("todo"),
           !starts(["add", "remind", "create", "make", "schedule"]) {
            return .ask
        }
        return .add
    }

    /// Why the on-device model wasn't used, in plain words.
    static func fallbackReason() -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "the on-device model couldn't handle that request"
            case .unavailable(.deviceNotEligible):
                return "this iPhone doesn't support Apple Intelligence"
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Apple Intelligence is turned off in Settings"
            case .unavailable(.modelNotReady):
                return "the Apple Intelligence model is still downloading"
            case .unavailable:
                return "the on-device model is unavailable"
            }
        }
        return "this iPhone needs iOS 26 or later for Apple Intelligence"
        #else
        return "this build doesn't include Apple's on-device model"
        #endif
    }

    /// Friendly small talk, so "hello" doesn't become a task.
    static func chat(_ text: String) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            if let reply = await aiChat(text) { return reply }
        }
        #endif
        return "Hi! I'm Kitty. I can add tasks, read your lists by category, mark things done, rename or delete them."
    }

    /// Turn a request into categorised tasks (with due dates when implied).
    static func plan(_ prompt: String) async -> PlanResult {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            if let tasks = await aiPlan(prompt), !tasks.isEmpty {
                return PlanResult(tasks: tasks, usedAI: true)
            }
        }
        #endif
        return PlanResult(tasks: ruleTasks(prompt, known: KittyGuideStore.profileNames), usedAI: false)
    }

    // MARK: Rule-based planning (no Apple Intelligence)

    private static let dayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// "saturday" -> 7, "weekdays" -> [2...6], "weekend" -> [1, 7]
    static func weekdayNumbers(_ names: [String]) -> [Int] {
        var out = Set<Int>()
        for raw in names {
            let n = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if n.contains("weekday") { out.formUnion([2, 3, 4, 5, 6]); continue }
            if n.contains("weekend") { out.formUnion([1, 7]); continue }
            if let i = dayNames.firstIndex(where: { n.hasPrefix(String($0.prefix(3))) }) { out.insert(i + 1) }
        }
        return out.sorted()
    }

    /// Every weekday named in the text ("saturday", "sundays") as numbers, 1 = Sunday.
    static func weekdaysMentioned(_ t: String) -> [Int] {
        let lower = t.lowercased()
        return dayNames.enumerated().filter { lower.contains($0.element) }.map { $0.offset + 1 }
    }

    /// Finds how a sentence repeats: "every day", "every Saturday and Sunday", "every other day",
    /// "alternate days", "every 3 days", "every other week", "monthly on the 5th" ...
    /// Returns the schedule and the sentence with the schedule words removed.
    static func ruleRecurrence(in sentence: String) -> (spec: RecurrenceSpec, cleaned: String)? {
        let t = sentence.lowercased()
        var cleaned = sentence
        let todayWeekday = Calendar.current.component(.weekday, from: .now)

        func strip(_ phrases: [String]) {
            for ph in phrases { cleaned = cleaned.replacingOccurrences(of: ph, with: " ", options: .caseInsensitive) }
        }
        func stripRegex(_ pattern: String) {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        let numberWords: [String: Int] = ["other": 2, "alternate": 2, "second": 2, "two": 2, "third": 3, "three": 3,
                                          "fourth": 4, "four": 4, "fifth": 5, "five": 5]

        // "every other day", "every 3 days", "every other week", "every 2 weeks", "every other saturday"
        let dayAlt = dayNames.joined(separator: "|")
        let everyN = "every\\s+(other|alternate|second|third|fourth|fifth|two|three|four|five|\\d+)\\s+(days?|weeks?|\(dayAlt))"
        if let r = t.range(of: everyN, options: .regularExpression) {
            let words = t[r].split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if words.count >= 3, let n = Int(words[1]) ?? numberWords[words[1]] {
                stripRegex(everyN)
                let unit = words[2]
                if unit.hasPrefix("day") {
                    return n > 1 ? (RecurrenceSpec(intervalDays: n), cleaned) : (RecurrenceSpec(), cleaned)
                }
                var days = unit.hasPrefix("week") ? weekdaysMentioned(t) : []
                if let i = dayNames.firstIndex(of: unit) { days = [i + 1] }
                if days.isEmpty { days = [todayWeekday] }
                return (RecurrenceSpec(weekdays: days, everyNWeeks: max(n, 1)), cleaned)
            }
        }
        if t.range(of: "alternate[\\s-]+days?", options: .regularExpression) != nil {
            stripRegex("alternate[\\s-]+days?")
            return (RecurrenceSpec(intervalDays: 2), cleaned)
        }
        if ["biweekly", "bi-weekly", "fortnightly", "every fortnight"].contains(where: { t.contains($0) }) {
            strip(["biweekly", "bi-weekly", "fortnightly", "every fortnight"])
            let days = weekdaysMentioned(t)
            return (RecurrenceSpec(weekdays: days.isEmpty ? [todayWeekday] : days, everyNWeeks: 2), cleaned)
        }

        // Monthly: "monthly", "every month", "on the 5th of every month"
        if ["monthly", "every month", "once a month", "each month"].contains(where: { t.contains($0) }) {
            var dom = Calendar.current.component(.day, from: .now)
            let ord = "\\b\\d{1,2}(st|nd|rd|th)\\b"
            if let r = t.range(of: ord, options: .regularExpression), let n = Int(t[r].filter(\.isNumber)) {
                dom = n
                stripRegex(ord)
            }
            strip(["monthly", "every month", "once a month", "each month", "of the month", "on the "])
            return (RecurrenceSpec(dayOfMonth: min(max(dom, 1), 31)), cleaned)
        }

        let daily = ["every single day", "every day", "everyday", "each day", "daily", "every morning", "every evening", "every night"]
        if daily.contains(where: { t.contains($0) }) { strip(daily); return (RecurrenceSpec(), cleaned) }

        if t.contains("every weekday") || t.contains("on weekdays") || t.contains("weekdays") {
            strip(["every weekday", "on weekdays", "weekdays"])
            return (RecurrenceSpec(weekdays: [2, 3, 4, 5, 6]), cleaned)
        }
        if t.contains("every weekend") || t.contains("on weekends") {
            strip(["every weekend", "on weekends"])
            return (RecurrenceSpec(weekdays: [1, 7]), cleaned)
        }

        var days = Set<Int>()
        var phrases: [String] = []
        let weekly = t.contains("weekly") || t.contains("every week") || t.contains("once a week")
        for (i, d) in dayNames.enumerated() {
            for ph in ["every \(d)", "each \(d)", "on \(d)s", "\(d)s", "weekly on \(d)"] where t.contains(ph) {
                days.insert(i + 1); phrases.append(ph)
            }
            if weekly && t.contains(d) { days.insert(i + 1); phrases.append("on \(d)"); phrases.append(d) }
        }
        if !days.isEmpty {
            // "every Saturday or Sunday" / "every Saturday and Sunday": the second day has no "every" of its own.
            if t.contains("every") || t.contains("each") || weekly {
                for (i, d) in dayNames.enumerated() where t.contains(d) && !days.contains(i + 1) {
                    days.insert(i + 1); phrases.append(d)
                }
            }
            strip(phrases + ["weekly", "every week", "once a week"])
            return (RecurrenceSpec(weekdays: days.sorted()), cleaned)
        }
        if weekly {
            strip(["weekly", "every week", "once a week"])
            return (RecurrenceSpec(weekdays: [todayWeekday]), cleaned)
        }
        return nil
    }

    static func ruleDue(_ text: String) -> Date? {
        let t = text.lowercased()
        let cal = Calendar.current
        if t.contains("tomorrow") { return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now)) }
        if t.contains("today") || t.contains("tonight") || t.contains("this morning") || t.contains("this evening") {
            return cal.startOfDay(for: .now)
        }
        // "on Sunday" -> the next Sunday (today if it is Sunday)
        let today = cal.startOfDay(for: .now)
        let todayN = cal.component(.weekday, from: today)
        for (i, d) in dayNames.enumerated() where t.contains(d) {
            return cal.date(byAdding: .day, value: (i + 1 - todayN + 7) % 7, to: today)
        }
        return nil
    }

    /// "the maid should ", "ask the cook to ", "my househelp needs to ", "I will " ... stripped from task titles.
    private static let leadPrefixes: [String] = {
        let roles = ["maid", "househelp", "house help", "house helper", "helper", "housekeeper", "cook", "driver", "gardener", "nanny"]
        let dets = ["the ", "my ", "our ", ""]
        let leaders = ["", "ask ", "tell ", "have ", "get ", "remind "]
        let conns = ["should ", "needs to ", "need to ", "has to ", "must ", "will ", "to ", "can ", "please "]
        var out = ["i will ", "i'll ", "i need to ", "i should ", "i have to ", "please ", "make sure to ", "needs to ", "need to ",
                   "she should ", "he should ", "we should ", "everyone should "]
        for l in leaders {
            for d in dets {
                for r in roles {
                    let base = l + d + r + " "
                    for c in conns { out.append(base + c) }
                    if !l.isEmpty { out.append(base) }
                }
            }
        }
        return out.sorted { $0.count > $1.count }
    }()

    static func tidyTitle(_ raw: String, removingDay: Bool) -> String {
        var s = raw
        if removingDay {
            for w in [" today", " tomorrow", "today ", "tomorrow ", " tonight"] {
                s = s.replacingOccurrences(of: w, with: " ", options: .caseInsensitive)
            }
        }
        var lower = s.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for l in leadPrefixes where lower.hasPrefix(l) { s = String(s.dropFirst(l.count)); lower = s.lowercased(); break }
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,.-:"))
        // Leftovers from removed schedule words ("wash restrooms or", "sweep on").
        var trimmed = true
        while trimmed {
            trimmed = false
            for w in [" and", " or", " on", " every", " each"] where s.lowercased().hasSuffix(w) {
                s = String(s.dropLast(w.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,.-:")); trimmed = true
            }
        }
        if let f = s.first { s = f.uppercased() + s.dropFirst() }
        return s
    }

    static func ruleTasks(_ prompt: String, known: [String] = []) -> [PlannedTask] {
        let sentences = prompt
            .components(separatedBy: CharacterSet(charactersIn: ".;!\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var out: [PlannedTask] = []
        for sentence in sentences {
            // "Make that tomorrow", "actually the maid should do it": refine what was said before.
            let lowered = sentence.lowercased()
            let refinements = ["make that", "make it", "make them", "change that", "change it", "change them", "actually", "i mean", "no wait", "instead"]
            if !out.isEmpty, refinements.contains(where: { lowered.hasPrefix($0) }) {
                let newDue = ruleDue(sentence)
                let who = Assignee.detect(in: sentence)
                let clock = DaySlot.parseClock(in: sentence)
                if newDue != nil || who != nil || clock != nil {
                    for i in out.indices {
                        if let d = newDue, out[i].recurrence == nil { out[i].due = d }
                        if let w = who { out[i].assignee = w }
                        if let c = clock { out[i].timeMinutes = c }
                    }
                    continue
                }
            }
            // "...to my Blinkit order": the items belong to a list.
            var listName: String? = nil
            var sentenceText = sentence
            if let found = ruleProfile(in: sentence, known: known) {
                listName = found.name
                sentenceText = found.cleaned
            }
            // A schedule phrase applies to every task in its sentence.
            let rec = listName == nil ? ruleRecurrence(in: sentenceText) : nil
            let due = rec == nil ? ruleDue(sentenceText) : nil
            for piece in TaskStore.splitCompound(rec?.cleaned ?? sentenceText) {
                let title = tidyTitle(piece, removingDay: due != nil)
                guard !title.isEmpty else { continue }
                let guess = DaySlot.guess(from: title)
                out.append(PlannedTask(title: title, category: .guess(from: title), due: due, recurrence: rec?.spec,
                                       assignee: Assignee.detect(in: sentence),
                                       slot: guess == .anytime ? nil : guess,
                                       timeMinutes: DaySlot.parseClock(in: piece),
                                       profile: listName))
            }
        }
        return out
    }

    /// "add milk to my Blinkit order" -> the list "Blinkit order", and the sentence without that part.
    static func ruleProfile(in sentence: String, known: [String]) -> (name: String, cleaned: String)? {
        let preps = [" to my ", " to the ", " to our ", " in my ", " in the ", " on my ", " into my ", " into the ", " for my ", " for the "]
        let nouns: Set<String> = ["order", "list", "cart", "basket", "checklist", "wishlist", "trip", "party"]
        let connectors: Set<String> = ["and", "then", "also", "because", "tomorrow", "today", "tonight", "please", "by", "at"]
        let tooGeneric: Set<String> = ["list", "to do list", "todo list", "task list", "tasks", "task", "to-do list", "day", "morning"]
        for prep in preps {
            guard let r = sentence.range(of: prep, options: [.caseInsensitive, .backwards]) else { continue }
            let tail = sentence[r.upperBound...]
            var taken: [String] = []
            var endedOnNoun = false
            var lastEnd = r.upperBound
            for raw in tail.split(whereSeparator: { $0.isWhitespace }) {
                let word = raw.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if connectors.contains(word) || taken.count >= 4 { break }
                taken.append(String(raw).trimmingCharacters(in: .punctuationCharacters))
                lastEnd = raw.endIndex
                if nouns.contains(word) { endedOnNoun = true; break }
                if raw.last?.isPunctuation == true { break }
            }
            guard !taken.isEmpty else { continue }
            let name = taken.joined(separator: " ")
            if tooGeneric.contains(name.lowercased()) { continue }
            let nameWords = TaskMatcher.tokens(name)
            let isKnown = known.contains { k in
                let kw = TaskMatcher.tokens(k)
                guard !kw.isEmpty, !nameWords.isEmpty else { return false }
                return kw.allSatisfy { w in nameWords.contains { TaskMatcher.same(w, $0) } }
                    || nameWords.allSatisfy { w in kw.contains { TaskMatcher.same(w, $0) } }
            }
            guard endedOnNoun || isKnown else { continue }
            return (name, String(sentence[..<r.lowerBound]) + " " + String(sentence[lastEnd...]))
        }
        return nil
    }

    /// When in the day each task is normally done. Nil if Apple Intelligence is unavailable.
    static func classifyTimes(_ titles: [String]) async -> [String: (slot: DaySlot, minutes: Int?)]? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return await aiTimes(titles)
        }
        #endif
        return nil
    }

    static func speakableSummary(question: String, facts: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return await aiSummary(question: question, facts: facts)
        }
        #endif
        return nil
    }

    // MARK: Playbooks: understand a procedure the user explains

    private static let roleWords: Set<String> = ["cook", "maid", "househelp", "helper", "driver", "gardener", "nanny", "wife",
                                                 "husband", "mom", "dad", "mother", "father", "son", "daughter", "kids",
                                                 "chef", "i", "me", "we"]

    /// "the cook should marinate the chicken" -> (Marinate the chicken, Cook)
    static func ruleStep(_ piece: String) -> PlaybookStep? {
        var words = piece.replacingOccurrences(of: "’", with: "'").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let filler: Set<String> = ["then", "next", "first", "finally", "after", "that", "and", "the", "my", "so", "also", "now", "afterwards"]
        while let w = words.first?.lowercased(), filler.contains(w) { words.removeFirst() }

        func label(_ w: String) -> String { Assignee.normalize(w) }
        var assignee: String? = nil

        if let first = words.first {
            let base = (first.lowercased().components(separatedBy: "'").first ?? "").trimmingCharacters(in: .punctuationCharacters)
            if roleWords.contains(base) {
                assignee = label(base)
                words.removeFirst()
                let modals: Set<String> = ["should", "will", "would", "can", "does", "do", "has", "have", "needs", "need", "to", "must", "is", "gonna", "going"]
                while let m = words.first?.lowercased(), modals.contains(m) { words.removeFirst() }
            }
        }
        if assignee == nil, let i = words.firstIndex(where: { $0.lowercased() == "by" }), i + 1 < words.count {
            let base = words[i + 1].lowercased().trimmingCharacters(in: .punctuationCharacters)
            if roleWords.contains(base) { assignee = label(base); words.removeSubrange(i...(i + 1)) }
        }
        let title = tidyTitle(words.joined(separator: " "), removingDay: false)
        return title.isEmpty ? nil : PlaybookStep(title: title, assignee: assignee)
    }

    /// Splits "how I make biryani: the cook marinates chicken. The maid washes rice" into a name and the rest.
    static func rulePlaybookParts(_ text: String) -> (name: String, body: String)? {
        let markers = ["how i make ", "how i cook ", "how i prepare ", "how we make ", "how we cook ", "how we prepare ",
                       "playbook for ", "playbook called ", "playbook named ", "recipe for ", "steps for "]
        for m in markers {
            guard let r = text.range(of: m, options: .caseInsensitive) else { continue }
            let after = text[r.upperBound...]
            let delims: [Character] = [":", ",", ".", "-", "\n", "—"]
            let nameEnd = after.firstIndex(where: { delims.contains($0) }) ?? after.endIndex
            var words = String(after[..<nameEnd]).split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let cut: Set<String> = ["is", "are", "like", "so", "first", "then", "where", "and", "the"]
            if let i = words.firstIndex(where: { cut.contains($0.lowercased()) }) { words = Array(words[..<i]) }
            words = Array(words.prefix(4))
            let name = tidyTitle(words.joined(separator: " "), removingDay: false)
            guard !name.isEmpty else { continue }

            var rest = after[...]
            if let rr = after.range(of: words.joined(separator: " "), options: .caseInsensitive) { rest = after[rr.upperBound...] }
            let body = String(rest).trimmingCharacters(in: CharacterSet(charactersIn: " :,.-—\n"))
            guard !body.isEmpty else { continue }
            return (name, body)
        }
        return nil
    }

    static func ruleSteps(_ body: String) -> [PlaybookStep] {
        var s = body
        for sep in [" and then ", " after that ", " afterwards ", " then ", " next ", ";", "\n"] {
            s = s.replacingOccurrences(of: sep, with: ".", options: .caseInsensitive)
        }
        return s.components(separatedBy: CharacterSet(charactersIn: ".!"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap(ruleStep)
    }

    /// Turn what the user said into a playbook. Uses only the user's own steps; never invents any.
    static func planPlaybook(_ text: String) async -> (result: PlaybookResult?, usedAI: Bool) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            if let r = await aiPlaybook(text) { return (r, true) }
        }
        #endif
        guard let parts = rulePlaybookParts(text) else { return (nil, false) }
        let steps = ruleSteps(parts.body)
        guard !steps.isEmpty else { return (nil, false) }
        return (PlaybookResult(name: parts.name, category: .guess(from: parts.name + " " + parts.body), steps: steps), false)
    }

    /// Turn a question into a category / day / status filter.
    static func interpretQuery(_ question: String) async -> TaskLookupSpec {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            if let spec = await aiQuery(question) { return spec }
        }
        #endif
        return ruleQuery(question)
    }

    /// The same, from the words alone (no model call).
    static func ruleQuery(_ question: String) -> TaskLookupSpec {
        let t = question.lowercased()
        var spec = TaskLookupSpec()
        spec.category = TaskCategory.mentioned(in: t)
        if t.contains("tomorrow") { spec.day = .tomorrow }
        else if t.contains("today") || t.contains("this morning") || t.contains("tonight") { spec.day = .today }
        if t.contains("done") || t.contains("completed") || t.contains("finished") { spec.status = .done }
        return spec
    }

    /// Work out which task(s) the user means for complete / reopen / rename / delete.
    static func interpretCommand(_ text: String, action: AgentAction) async -> TaskCommand {
        if action == .assign || action == .reschedule { return ruleCommand(text, action: action) }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            if let cmd = await aiCommand(text, action: action) { return cmd }
        }
        #endif
        return ruleCommand(text, action: action)
    }

    static func ruleCommand(_ text: String, action: AgentAction) -> TaskCommand {
        let t = text.lowercased()
        var cmd = TaskCommand()
        if action != .reschedule {       // for reschedule, "tomorrow" is the new day, not a filter
            if t.contains("tomorrow") { cmd.day = .tomorrow } else if t.contains("today") { cmd.day = .today }
        }
        cmd.all = t.contains("all ") || t.contains("every") || t.contains("everything")

        func split(_ seps: [String]) -> (before: String, after: String)? {
            for sep in seps {
                if let r = text.range(of: sep, options: [.caseInsensitive, .backwards]) {
                    return (String(text[..<r.lowerBound]), String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            return nil
        }

        var body = text
        switch action {
        case .rename:      // "rename dusting to dust the shelves"
            if let p = split([" to ", " into "]) { body = p.before; cmd.newTitle = p.after }
        case .assign:      // "assign sweeping to the maid"
            if let p = split([" to "]) { body = p.before; cmd.newAssignee = Assignee.normalize(p.after) }
        case .reschedule:  // "move mopping to tomorrow"
            if let p = split([" to ", " until ", " till ", " for "]) {
                body = p.before
                cmd.newDue = ruleDue(p.after)
            } else {
                cmd.newDue = ruleDue(text)
            }
        default: break
        }
        let scope = (action == .assign || action == .reschedule || action == .rename) ? body : text
        cmd.category = TaskCategory.mentioned(in: scope.lowercased())
        cmd.target = body
        return cmd
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct PlannedTaskDraft {
    @Guide(description: "Short actionable title that starts with a verb, under 8 words")
    var title: String
    @Guide(description: "Best category for the task", .anyOf(["househelp", "work", "personal", "family", "errands", "health", "finance", "other"]))
    var category: String
    @Guide(description: "Due date as yyyy-MM-dd if the user implied a day (today, tomorrow, a weekday). Empty string if none or if the task repeats.")
    var dueDate: String
    @Guide(description: "'none' for a one-off task. 'daily' if it repeats every day. 'weekly' if it repeats on certain weekdays or every N weeks. 'everyNDays' for alternate days or every N days. 'monthly' for once a month.",
           .anyOf(["none", "daily", "weekly", "everyNDays", "monthly"]))
    var repeats: String
    @Guide(description: "For weekly tasks only: all the weekday names it repeats on, lowercase, for example [\"saturday\", \"sunday\"]. Empty array otherwise.")
    var weekdays: [String]
    @Guide(description: "For everyNDays: the number of days (alternate days = 2). For weekly: 1, or 2 for every other week. Otherwise 1.")
    var every: Int
    @Guide(description: "For monthly tasks: the day of the month, 1 to 31. Otherwise 0.")
    var dayOfMonth: Int
    @Guide(description: "Who should do it: 'Househelp' for the house helper or maid, 'Me' for the user, 'Family' for the whole family or everyone, or the role or name the user states such as 'Cook' or 'Driver'. Empty string if the user did not say.")
    var assignee: String
    @Guide(description: "When in the day it is normally done: 'morning' (morning walk, breakfast, wake-up), 'afternoon' (lunch, school pickup), 'evening' (evening walk, dinner, tea), 'night' (bedtime, locking up), or 'anytime' if nothing in the task points to a time of day.",
           .anyOf(["morning", "afternoon", "evening", "night", "anytime"]))
    var timeOfDay: String
    @Guide(description: "Clock time as HH:mm in 24-hour format only if the user states one (6 am is 06:00, 7:30 pm is 19:30). Otherwise an empty string.")
    var time: String
    @Guide(description: "The list, order or collection this item belongs to, if the user names one: 'add milk to my Blinkit order' gives listName 'Blinkit order'. Use an existing list name from the guide when one fits. Empty string if the item is not for a named list.")
    var listName: String
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct TimeOfDayItem {
    @Guide(description: "The task title exactly as given")
    var title: String
    @Guide(description: "When in the day it is normally done. 'morning walk' is morning, 'evening walk' is evening, 'lunch' is afternoon, 'bedtime' is night. 'anytime' if nothing points to a time of day.",
           .anyOf(["morning", "afternoon", "evening", "night", "anytime"]))
    var timeOfDay: String
    @Guide(description: "Clock time as HH:mm (24-hour) only if the title states one, otherwise an empty string.")
    var time: String
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct TimeOfDayBatch {
    @Guide(description: "One entry per task title, in the same order")
    var items: [TimeOfDayItem]
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct PlaybookStepDraft {
    @Guide(description: "The task, starting with a verb, under 10 words, in the user's own words. Do not include who does it.")
    var title: String
    @Guide(description: "Who does this task, exactly as the user named them, for example 'Cook' or 'Maid'. 'I' means 'Me'. Empty string if the user did not say.")
    var assignee: String
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct TaughtPlaybookDraft {     // a procedure the user taught Kitty. (The bulk-creation PlaybookDraft is in BulkAgent.swift.)
    @Guide(description: "Name of the job, for example 'Cook biryani'. Under 5 words.")
    var name: String
    @Guide(description: "Best category for the job", .anyOf(["househelp", "work", "personal", "family", "errands", "health", "finance", "other"]))
    var category: String
    @Guide(description: "The steps in the order the user described them. Only steps the user actually said.")
    var steps: [PlaybookStepDraft]
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct TaskPlan {
    var tasks: [PlannedTaskDraft]
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct TaskLookup {
    @Guide(description: "Category the question is about, or 'any'. 'my househelp', 'maid' or 'house help' means househelp.",
           .anyOf(["any", "househelp", "work", "personal", "family", "errands", "health", "finance", "other"]))
    var category: String
    @Guide(description: "'today' or 'tomorrow' if the question names that day, otherwise 'anytime'",
           .anyOf(["anytime", "today", "tomorrow"]))
    var day: String
    @Guide(description: "'open' by default, 'done' if asking about completed tasks, 'all' if asking for everything",
           .anyOf(["open", "done", "all"]))
    var status: String
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct TaskRoute {
    @Guide(description: """
           'ask' if the user asks about or wants to see existing tasks.
           'add' if they tell the app about new things to do.
           'complete' if they say something is finished or ask to mark it done.
           'reopen' if they want a finished task back on the list or marked not done.
           'rename' if they want to change a task's wording.
           'delete' if they want a task removed or cancelled.
           'clear' if they want all completed tasks cleared.
           'assign' if they want to give an existing task to someone else, like 'assign sweeping to the maid'.
           'profile' if they want to create a new list, rename a list, empty a list, mark a whole list done like 'I placed the order', or move an item to another list. Adding items to a list is 'add'.
           'reschedule' if they want to move an existing task to another day, like 'move mopping to tomorrow'.
           'teach' if they are explaining how they do a job, step by step or who does what, so Kitty can remember it, like 'here is how I make biryani: the cook marinates the chicken'.
           'chat' only for greetings, thanks, or questions about Kitty itself.
           """,
           .anyOf(["add", "ask", "chat", "complete", "reopen", "rename", "delete", "clear", "teach", "assign", "reschedule", "profile"]))
    var action: String
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct TaskCommandDraft {
    @Guide(description: "The words from the user's message that name the task or tasks they mean, e.g. 'dust the shelves'. Join several tasks with ' and '. Leave empty if they mean every task in a category or day.")
    var target: String
    @Guide(description: "Only for rename: the new task title. Otherwise an empty string.")
    var newTitle: String
    @Guide(description: "Category the user mentions, or 'any'. 'my househelp', 'maid' or 'house help' means househelp.",
           .anyOf(["any", "househelp", "work", "personal", "family", "errands", "health", "finance", "other"]))
    var category: String
    @Guide(description: "'today' or 'tomorrow' if the user names that day, otherwise 'anytime'",
           .anyOf(["anytime", "today", "tomorrow"]))
    var day: String
    @Guide(description: "True only if the user says all, every or everything.")
    var everything: Bool
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
extension TaskPlanner {
    private static var isModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        Breadcrumb.log("AI unavailable: \(fallbackReason())")
        return false
    }

    static func aiRoute(_ text: String) async -> AgentAction? {
        guard isModelAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You classify messages sent to a to-do app called Kitty.
            If the user asks what is on a list, what they need to do, or wants to see tasks, the action is 'ask'.
            If the user describes things to do or tells Kitty to remember or add something, the action is 'add'.
            Chores that repeat, like 'every day the maid sweeps' or 'wash restrooms every Saturday', are 'add' too.
            If the user is explaining how they do a job, step by step or who does what, so Kitty can remember it, the action is 'teach'.
            Saying they are planning, starting or about to do a job, like 'I am planning to cook biryani today', is 'add', not 'teach'.
            If the user says a task is finished, done or completed, or asks to mark it done, the action is 'complete'.
            Words like delete, remove or cancel a task mean 'delete'. Rename or change the wording of a task means 'rename'.
            Marking a task not done, or reopening it, means 'reopen'. Clearing all finished tasks means 'clear'.
            """ + KittyGuideStore.block(.understand))
        do {
            let r = try await session.respond(to: text, generating: TaskRoute.self)
            switch r.content.action {
            case "ask": return .ask
            case "chat": return .chat
            case "complete": return .complete
            case "reopen": return .reopen
            case "rename": return .rename
            case "delete": return .delete
            case "clear": return .clear
            case "teach": return .teach
            case "assign": return .assign
            case "reschedule": return .reschedule
            case "profile": return .profile
            default: return .add
            }
        } catch { Breadcrumb.log("AI 'route' failed: \(String(describing: error).prefix(140))"); return nil }
    }

    static func aiChat(_ text: String) async -> String? {
        guard isModelAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You are Kitty, a friendly, upbeat assistant inside a to-do app.
            Reply in one or two short sentences. You can add tasks and tell the user what is on their lists.
            Never claim to have added or changed any task in this reply.
            """ + KittyGuideStore.block(.reply))
        do {
            return try await session.respond(to: text).content
        } catch { Breadcrumb.log("AI 'chat' failed: \(String(describing: error).prefix(140))"); return nil }
    }

    static func aiPlan(_ prompt: String) async -> [PlannedTask]? {
        guard isModelAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You are the task agent inside a to-do app called Kitty. Today is \(todayString()).
            Turn the user's request into concrete to-do items. For each item set:
            - title: short, starts with a verb, under 8 words.
            - category: one of househelp, work, personal, family, errands, health, finance, other.
              'househelp' means domestic chores done by a house helper or maid: dusting, washing dishes,
              chopping vegetables, cooking, laundry, mopping, cleaning. Anything the user delegates to
              their househelp, maid or cook is 'househelp'.
            - dueDate: yyyy-MM-dd if the user implied a day (today, tomorrow, a weekday), otherwise an empty string.
            - repeats: 'daily' for chores that happen every day; 'weekly' for chores on certain weekdays
              ('every Saturday', 'every Saturday and Sunday', 'weekly', 'every other week'); 'everyNDays' for
              'every other day', 'alternate days' or 'every 3 days'; 'monthly' for once a month; otherwise 'none'.
              For weekly, list every weekday name mentioned. For everyNDays or every other week, set every.
              A schedule phrase applies to every task in the same sentence. Never put schedule words in the title.
              Repeating tasks get an empty dueDate.
            - assignee: who should do it, if the user says ('the maid should sweep' -> Househelp, 'I will call the bank' -> Me,
              'everyone should pack' -> Family, 'the cook' -> Cook). Empty if not said. Never put the assignee in the title.
            - timeOfDay: when in the day it is normally done ('morning walk' -> morning, 'evening walk' -> evening,
              'lunch' -> afternoon, 'bedtime' -> night), otherwise anytime. time: HH:mm only if the user says a clock time.
            - listName: the list, order or collection the item belongs to, if the user names one ('add milk to my Blinkit order' -> title 'milk',
              listName 'Blinkit order'). Never put the list name in the title. Empty if there is none.
            Keep separate items separate. Keep the user's own wording; do not break a task into sub-steps.
            Return at most 10 tasks and do not invent unrelated tasks.
            """ + KittyGuideStore.block(.understand))
        do {
            let r = try await session.respond(to: prompt, generating: TaskPlan.self)
            return r.content.tasks.compactMap { draft in
                let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                var rec: RecurrenceSpec? = nil
                let today = Calendar.current.component(.weekday, from: .now)
                switch draft.repeats {
                case "daily": rec = RecurrenceSpec()
                case "weekly":
                    let n = weekdayNumbers(draft.weekdays)
                    rec = RecurrenceSpec(weekdays: n.isEmpty ? [today] : n, everyNWeeks: max(draft.every, 1))
                case "everyNDays": rec = draft.every > 1 ? RecurrenceSpec(intervalDays: draft.every) : RecurrenceSpec()
                case "monthly":
                    rec = RecurrenceSpec(dayOfMonth: (1...31).contains(draft.dayOfMonth) ? draft.dayOfMonth : Calendar.current.component(.day, from: .now))
                default: break
                }
                return PlannedTask(
                    title: title,
                    category: TaskCategory(rawValue: draft.category) ?? .guess(from: title),
                    due: rec == nil ? parseDay(draft.dueDate) : nil,
                    recurrence: rec,
                    assignee: { let w = Assignee.normalize(draft.assignee); return w.isEmpty ? nil : w }(),
                    slot: DaySlot(rawValue: draft.timeOfDay),
                    timeMinutes: DaySlot.parseHHmm(draft.time),
                    profile: { let n = draft.listName.trimmingCharacters(in: .whitespacesAndNewlines); return n.isEmpty ? nil : n }()
                )
            }
        } catch { Breadcrumb.log("AI 'plan' failed: \(String(describing: error).prefix(140))"); return nil }
    }

    /// Puts the facts into a short, natural, spoken reply following the Kitty guide.
    /// Returns nil if any number in the reply is not in the facts, so a wrong figure is never shown.
    static func aiSummary(question: String, facts: String) async -> String? {
        guard isModelAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You are Kitty, a warm and brief household task assistant, speaking out loud.
            Write the reply to the user's question using only the facts provided. Do not add facts, tasks, people, dates or numbers that are not in the facts.
            """ + KittyGuideStore.block(.reply))
        do {
            let r = try await session.respond(to: "Question: \(question)\n\nFacts:\n\(String(facts.prefix(1500)))")
            let text = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            func numbers(_ s: String) -> Set<String> { Set(s.split(whereSeparator: { !$0.isNumber }).map(String.init)) }
            guard numbers(text).isSubset(of: numbers(facts)) else {
                Breadcrumb.log("AI 'summary' used a number that is not in the facts; using the plain answer")
                return nil
            }
            return text
        } catch { Breadcrumb.log("AI 'summary' failed: \(String(describing: error).prefix(140))"); return nil }
    }

    /// Asks the on-device model when in the day each task is normally done.
    static func aiTimes(_ titles: [String]) async -> [String: (slot: DaySlot, minutes: Int?)]? {
        guard isModelAvailable, !titles.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: """
            You decide when in the day household tasks are normally done, so a to-do list can be ordered through the day.
            Morning: morning walk, breakfast, wake-up chores. Afternoon: lunch, school pickup. Evening: evening walk, dinner, tea.
            Night: bedtime, locking up. Use anytime when nothing in the title points to a time of day.
            Return one entry per title, in the same order, copying each title exactly.
            """ + KittyGuideStore.block(.understand))
        do {
            let r = try await session.respond(to: titles.joined(separator: "\n"), generating: TimeOfDayBatch.self)
            var out: [String: (slot: DaySlot, minutes: Int?)] = [:]
            for item in r.content.items {
                guard let slot = DaySlot(rawValue: item.timeOfDay) else { continue }
                out[item.title.lowercased()] = (slot, DaySlot.parseHHmm(item.time))
            }
            return out
        } catch { Breadcrumb.log("AI 'times' failed: \(String(describing: error).prefix(140))"); return nil }
    }

    static func aiPlaybook(_ text: String) async -> PlaybookResult? {
        guard isModelAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You record a household's own procedure for a job so it can be reused later.
            Copy only what the user said. Never add, merge, split or reorder steps, and never invent steps.
            Keep each step short and starting with a verb. Record who does each step exactly as the user named them.
            """ + KittyGuideStore.block(.understand))
        do {
            let r = try await session.respond(to: text, generating: TaughtPlaybookDraft.self)
            let steps: [PlaybookStep] = r.content.steps.compactMap { d in
                let title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                let who = Assignee.normalize(d.assignee)
                return PlaybookStep(title: title, assignee: who.isEmpty ? nil : who)
            }
            let name = r.content.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, steps.count >= 2 else { return nil }
            return PlaybookResult(name: name, category: TaskCategory(rawValue: r.content.category) ?? .guess(from: name), steps: steps)
        } catch { Breadcrumb.log("AI 'playbook' failed: \(String(describing: error).prefix(140))"); return nil }
    }

    static func aiCommand(_ text: String, action: AgentAction) async -> TaskCommand? {
        guard isModelAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You pull details out of requests to change an existing to-do list. Today is \(todayString()).
            Copy the task words from the user's message; do not invent or expand them.
            Categories: househelp (chores for a house helper or maid), work, personal, family, errands, health, finance, other.
            """ + KittyGuideStore.block(.understand))
        do {
            let r = try await session.respond(to: text, generating: TaskCommandDraft.self)
            var cmd = TaskCommand()
            cmd.target = r.content.target.trimmingCharacters(in: .whitespacesAndNewlines)
            cmd.newTitle = r.content.newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            cmd.category = TaskCategory(rawValue: r.content.category)
            cmd.day = DayFilter(rawValue: r.content.day) ?? .anytime
            cmd.all = r.content.everything
            return cmd
        } catch { Breadcrumb.log("AI 'command' failed: \(String(describing: error).prefix(140))"); return nil }
    }

    static func aiQuery(_ question: String) async -> TaskLookupSpec? {
        guard isModelAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You turn questions about a to-do list into filters. Today is \(todayString()).
            Categories: househelp (chores for a house helper or maid), work, personal, family, errands, health, finance, other.
            """ + KittyGuideStore.block(.understand))
        do {
            let r = try await session.respond(to: question, generating: TaskLookup.self)
            var spec = TaskLookupSpec()
            spec.category = TaskCategory(rawValue: r.content.category)
            spec.day = DayFilter(rawValue: r.content.day) ?? .anytime
            switch r.content.status {
            case "done": spec.status = .done
            case "all": spec.status = .all
            default: spec.status = .open
            }
            return spec
        } catch { Breadcrumb.log("AI 'query' failed: \(String(describing: error).prefix(140))"); return nil }
    }
}
#endif

// MARK: - The agent: one entry point for adding and asking

enum TaskAgent {
    @MainActor
    static func handle(_ text: String) async -> AgentReply {
        TaskStore.shared.refreshRoutines()
        if let reply = resolvePending(text) { return reply }
        let routed = await TaskPlanner.route(text)
        switch routed {
        case .ask:
            return await askReply(text)

        case .teach:
            return await teach(text)

        case .chat:
            return AgentReply(message: await TaskPlanner.chat(text), didAdd: false)

        case .clear:
            let n = TaskStore.shared.clearCompleted()
            let msg = n == 0 ? "There are no completed tasks to clear."
                             : "Cleared \(n) completed \(n == 1 ? "task" : "tasks")."
            return AgentReply(message: msg, didAdd: false, didChange: n > 0)

        case .complete, .reopen, .rename, .delete, .assign, .reschedule:
            return await change(routed, text: text)

        case .profile:
            return AgentReply(message: "Open Talk to Kitty to manage your lists.", didAdd: false)

        case .add:
            return await add(text)
        }
    }

    // MARK: Add (one-off tasks, routines, saved plans)

    @MainActor
    static func add(_ text: String, extraNote: String = "") async -> AgentReply {
        let store = TaskStore.shared
        let result = await TaskPlanner.plan(text)

        var oneOffs: [PlannedTask] = []
        var newRoutines: [Routine] = []
        var existingRoutines: [String] = []
        var candidate: (pb: Playbook, due: Date?)? = nil

        for p in result.tasks {
            if let rec = p.recurrence {
                if let r = store.addRoutine(title: p.title, category: p.category, recurrence: rec, assignee: p.assignee,
                                       slot: p.slot, timeMinutes: p.timeMinutes) {
                    newRoutines.append(r)
                } else {
                    existingRoutines.append(p.title)
                }
            } else if candidate == nil, let pb = store.playbook(matching: p.title) {
                candidate = (pb, p.due)      // ask before adding a whole playbook
            } else {
                oneOffs.append(p)
            }
        }

        let added = store.addMany(oneOffs)
        store.refreshRoutines()      // today's copy of a new routine appears right away

        var parts: [String] = []
        if !newRoutines.isEmpty {
            let list = newRoutines.map { "\($0.title) (\($0.scheduleText), \($0.effectiveAssignee))" }.joined(separator: ", ")
            parts.append("Saved \(newRoutines.count) \(newRoutines.count == 1 ? "routine" : "routines"): \(list).")
        }
        if !existingRoutines.isEmpty {
            parts.append("You already had: " + existingRoutines.joined(separator: ", ") + ".")
        }
        if !added.isEmpty {
            // Every task shows who it is for and when it is due.
            var order: [String] = []
            for t in added where !order.contains(t.effectiveAssignee) { order.append(t.effectiveAssignee) }
            let byWho = order.map { who -> String in
                let titles = added.filter { $0.effectiveAssignee == who }
                    .map { t in "\(t.title) (\(t.dueLabel.lowercased())\(t.timeLabel.map { ", " + $0.lowercased() } ?? ""))" }
                    .joined(separator: ", ")
                return "\(who): \(titles)"
            }
            parts.append("Added \(added.count) \(added.count == 1 ? "task" : "tasks"). " + byWho.joined(separator: ". ") + ".")
        }
        var asked = false
        if let c = candidate {
            let due = c.due ?? TaskPlanner.ruleDue(text) ?? Calendar.current.startOfDay(for: .now)
            pending = PendingPlaybook(playbookID: c.pb.id, due: due)
            parts.append("I have your \(c.pb.name) playbook with \(c.pb.steps.count) tasks. Add them for \(dueWord(due))? Say yes or no.")
            asked = true
        }
        guard !parts.isEmpty else {
            return AgentReply(message: "I couldn't find any tasks in that.", didAdd: false)
        }
        let note = result.usedAI ? "" : " (I used simple rules because \(TaskPlanner.fallbackReason()).)"
        await classifyUntimed()
        return AgentReply(message: parts.joined(separator: " ") + extraNote + note,
                          didAdd: !added.isEmpty || !newRoutines.isEmpty,
                          didChange: !added.isEmpty || !newRoutines.isEmpty,
                          expectsReply: asked)
    }

    // MARK: Playbooks: teach once, confirm, then create

    /// Waiting for a yes/no after Kitty offered to add a playbook.
    @MainActor static var pending: PendingPlaybook?

    private static func dueWord(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "today" }
        if cal.isDateInTomorrow(d) { return "tomorrow" }
        return d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    /// Handles "yes" / "no" after Kitty asked. Returns nil if the message is something else.
    @MainActor
    static func resolvePending(_ text: String) -> AgentReply? {
        guard let p = pending else { return nil }
        if Date.now.timeIntervalSince(p.created) > 600 { pending = nil; return nil }

        let plain = text.lowercased().filter { $0.isLetter || $0.isWhitespace || $0 == "'" }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = plain.split(separator: " ").map(String.init)
        guard let first = words.first, words.count <= 6 else { pending = nil; return nil }

        let noFirst: Set<String> = ["no", "nope", "nah", "cancel", "skip", "nevermind"]
        let yesFirst: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "absolutely", "definitely", "correct"]
        let yesPhrases = ["do it", "go ahead", "sounds good", "add them", "add it", "please do", "please"]
        let isNo = noFirst.contains(first) || plain.hasPrefix("not now") || plain.hasPrefix("never mind")
            || plain.hasPrefix("don't") || plain.hasPrefix("dont") || plain.hasPrefix("do not")
        let isYes = !isNo && (yesFirst.contains(first) || yesPhrases.contains(plain))

        if isNo {
            pending = nil
            return AgentReply(message: "Okay, I won't add them.", didAdd: false)
        }
        if isYes {
            pending = nil
            guard let pb = TaskStore.shared.playbooks.first(where: { $0.id == p.playbookID }) else {
                return AgentReply(message: "That playbook is gone, so I didn't add anything.", didAdd: false)
            }
            let items = TaskStore.shared.addPlaybookTasks(pb, due: p.due)
            return AgentReply(message: "Added \(items.count) tasks for \(pb.name), \(dueWord(p.due)): \(numbered(items)).",
                              didAdd: true, didChange: true)
        }
        pending = nil      // they said something else; drop the question and handle it normally
        return nil
    }

    private static func describe(_ step: PlaybookStep) -> String {
        step.assignee.map { "\(step.title) (\($0))" } ?? step.title
    }

    /// The user explains how they do a job; save it as a playbook.
    @MainActor
    static func teach(_ text: String) async -> AgentReply {
        let planned = await TaskPlanner.planPlaybook(text)
        guard let pb = planned.result, pb.steps.count >= 2 else {
            return AgentReply(
                message: "I couldn't pick out the steps. Try: here's how I make biryani. The cook marinates the chicken. The maid washes the rice. I fry the onions.",
                didAdd: false)
        }
        let replaced = TaskStore.shared.savePlaybook(name: pb.name, category: pb.category, steps: pb.steps)
        let list = pb.steps.enumerated().map { "\($0.offset + 1). \(describe($0.element))" }.joined(separator: "; ")
        let note = planned.usedAI ? "" : " (I used simple rules because \(TaskPlanner.fallbackReason()), so please check the steps.)"
        return AgentReply(
            message: "\(replaced ? "Updated" : "Saved") your \(pb.name) playbook, \(pb.steps.count) tasks: \(list). "
                + "Next time you say you're planning it, I'll ask before adding them. To change it, just teach me again." + note,
            didAdd: false, didChange: true)
    }

    /// "what playbooks do I have" / "show my biryani playbook"
    @MainActor
    static func playbookReply(_ text: String) -> AgentReply {
        let store = TaskStore.shared
        guard !store.playbooks.isEmpty else {
            return AgentReply(message: "You don't have any playbooks yet. Tell me how you do a job, like: here's how I make biryani, then each step and who does it.", didAdd: false)
        }
        let ignore: Set<String> = ["playbook", "playbooks", "show", "read", "tell", "what", "whats", "my", "me", "do", "i", "have", "list", "all", "steps", "of"]
        if let pb = store.playbook(matching: text, ignoring: ignore, minWords: 1) {
            let list = pb.steps.enumerated().map { "\($0.offset + 1). \(describe($0.element))" }.joined(separator: "; ")
            return AgentReply(message: "\(pb.name), \(pb.steps.count) tasks: \(list).", didAdd: false)
        }
        let names = store.playbooks.map { "\($0.name) (\($0.steps.count) tasks)" }.joined(separator: ", ")
        return AgentReply(message: "Your playbooks: \(names).", didAdd: false)
    }

    private static func isMyTasksQuestion(_ t: String) -> Bool {
        ["my task", "my to do", "my to-do", "my todo", "my list", "my day", "my agenda", "what do i have", "what do i need",
         "what should i do", "what i have to do", "what's on my", "whats on my"].contains { t.contains($0) }
    }

    /// Who a question is about: "for the house help", "what does the cook have".
    @MainActor
    static func mentionedAssignee(in text: String) -> String? {
        if let a = Assignee.detect(in: text, forQuery: true) { return a }
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        return TaskStore.shared.assignees.first {
            !["family", "househelp"].contains($0.lowercased()) && words.contains($0.lowercased())
        }
    }

    private static func numbered(_ items: [TaskItem], showWho: Bool = true) -> String {
        items.enumerated().map { i, t in
            "\(i + 1). \(t.title)" + (showWho ? " (\(t.effectiveAssignee))" : "")
        }.joined(separator: "; ")
    }

    // MARK: Time of day

    @MainActor private static var classifying = false

    /// Asks Apple Intelligence when in the day tasks without a time are normally done, and saves it.
    @MainActor
    static func classifyUntimed() async {
        guard !classifying else { return }
        let store = TaskStore.shared
        let pending = store.tasks.filter { $0.slot == nil && $0.timeMinutes == nil && $0.group == nil && !$0.isDone }.prefix(25)
        guard !pending.isEmpty else { return }
        classifying = true
        defer { classifying = false }
        guard let result = await TaskPlanner.classifyTimes(Array(Set(pending.map(\.title)))) else { return }
        var updates: [UUID: (slot: DaySlot, minutes: Int?)] = [:]
        for t in pending {
            if let r = result[t.title.lowercased()] { updates[t.id] = r }
        }
        store.applyTimes(updates)
    }

    // MARK: Routines

    private static func isRoutineQuestion(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["routine", "recurring", "repeating", "daily", "weekly", "every day", "alternate", "every other", "monthly"].contains { t.contains($0) }
    }

    @MainActor
    static func routinesSummary() -> String {
        let routines = TaskStore.shared.routines
        guard !routines.isEmpty else {
            return "You don't have any routines yet. Try saying: every day the maid sweeps and mops, and wash restrooms every Saturday."
        }
        var order: [String] = []
        for r in routines where !order.contains(r.scheduleText) { order.append(r.scheduleText) }
        let parts = order.map { sched -> String in
            let titles = routines.filter { $0.scheduleText == sched }.map(\.title).joined(separator: ", ")
            return sched.prefix(1).uppercased() + sched.dropFirst() + ": " + titles
        }
        return "You have \(routines.count) \(routines.count == 1 ? "routine" : "routines"). " + parts.joined(separator: ". ") + "."
    }

    /// "stop the weekly restroom routine" / "forget the biryani plan". Returns nil if this isn't about those.
    @MainActor
    static func forgetRoutineOrPlan(_ text: String) -> AgentReply? {
        guard let target = findForgetTarget(text) else { return nil }
        let store = TaskStore.shared
        switch target {
        case .problem(let message):
            return AgentReply(message: message, didAdd: false)
        case .playbook(let pb):
            store.removePlaybook(pb.id)
            return AgentReply(message: "Forgot your \(pb.name) playbook.", didAdd: false, didChange: true)
        case .profile(let p):
            let n = store.items(in: p).count
            store.removeProfile(p.id, deleteItems: true)
            return AgentReply(message: "Deleted the \(p.name) list and its \(n) \(n == 1 ? "item" : "items").", didAdd: false, didChange: true)
        case .routine(let r):
            store.removeRoutine(r.id)
            return AgentReply(message: "Removed the routine \(r.title). It won't come back on future days.", didAdd: false, didChange: true)
        }
    }

    // MARK: Change existing tasks (complete / reopen / rename / delete)

    @MainActor
    static func change(_ action: AgentAction, text: String) async -> AgentReply {
        if action == .delete, let reply = forgetRoutineOrPlan(text) { return reply }
        switch await planChange(action, text: text) {
        case .problem(let message): return AgentReply(message: message, didAdd: false)
        case .plan(let plan): return applyChange(plan)
        }
    }

    private static func lateNote(_ t: TaskItem) -> String {
        switch t.daysOverdue {
        case 0: return "due today"
        case 1: return "1 day overdue"
        default: return "\(t.daysOverdue) days overdue"
        }
    }

    /// Routines, then each playbook with numbered steps, then everything else.
    private static func detail(_ items: [TaskItem], flat: Bool, showWho: Bool) -> [String] {
        func name(_ t: TaskItem) -> String { showWho ? "\(t.title) (\(t.effectiveAssignee))" : t.title }
        var out: [String] = []

        // The same chore more than once is said once with a count: "Clean dishes +2".
        func stacked(_ list: [TaskItem], timed: ((TaskItem) -> String)? = nil) -> [String] {
            TaskStacking.stacks(list).map { stack in
                (timed?(stack.lead) ?? name(stack.lead)) + (stack.extra > 0 ? " +\(stack.extra)" : "")
            }
        }

        let routineItems = items.filter { $0.routineID != nil }
        if !routineItems.isEmpty { out.append("Routine: " + stacked(routineItems).joined(separator: ", ") + ".") }

        var groups: [String] = []
        for g in items.compactMap(\.group) where !groups.contains(g) { groups.append(g) }
        for g in groups {
            let steps = items.filter { $0.group == g }
            if steps.first?.profileID != nil {
                out.append("\(g), \(steps.count) \(steps.count == 1 ? "item" : "items"): " + stacked(steps).joined(separator: ", ") + ".")
            } else {
                out.append("\(g), \(steps.count) \(steps.count == 1 ? "step" : "steps"): " + numbered(steps, showWho: showWho) + ".")
            }
        }

        let rest = items.filter { $0.routineID == nil && $0.group == nil }
        if !rest.isEmpty {
            let slotsPresent = DaySlot.allCases.filter { s in rest.contains { $0.sortSlot == s } }
            let timeAware = slotsPresent.count > 1 || (slotsPresent.first.map { $0 != .anytime } ?? false)
            if timeAware {
                // Chronological: "Morning: walk, breakfast. Evening: walk, dinner."
                func timed(_ t: TaskItem) -> String {
                    let exact = (t.timeMinutes != nil && DaySlot.parseClock(in: t.title) == nil) ? t.timeMinutes.map { " at \(DaySlot.clockLabel($0))" } ?? "" : ""
                    return name(t) + exact
                }
                for slot in slotsPresent {
                    let line = stacked(rest.filter { $0.sortSlot == slot }, timed: timed).joined(separator: ", ")
                    out.append("\(slot.label): \(line).")
                }
            } else if flat {
                let names = stacked(rest)
                let more = names.count > 12 ? ", and \(names.count - 12) more" : ""
                out.append((out.isEmpty ? "Tasks: " : "Other tasks: ") + names.prefix(12).joined(separator: ", ") + more + ".")
            } else {
                let byCat = Dictionary(grouping: rest, by: { $0.effectiveCategory })
                let parts = TaskCategory.allCases.compactMap { c -> String? in
                    guard let g = byCat[c] else { return nil }
                    return "\(c.label): " + stacked(g).prefix(6).joined(separator: ", ")
                }
                out.append((out.isEmpty ? "" : "Other tasks. ") + parts.joined(separator: ". ") + ".")
            }
        }
        return out
    }

    /// "What are my tasks for tomorrow for the house help": what is due that day (routines and
    /// one-off tasks), plus everything still open from before.
    @MainActor
    static func answer(_ spec: TaskLookupSpec) -> String {
        let store = TaskStore.shared
        let cal = Calendar.current
        if let pid = spec.profileID, let list = store.profiles.first(where: { $0.id == pid }) {
            let all = store.items(in: list)
            let shown = all.filter { spec.status == .all || (spec.status == .done ? $0.isDone : !$0.isDone) }
            guard !shown.isEmpty else {
                return spec.status == .open && !all.isEmpty ? "Everything on \(list.name) is done." : "\(list.name) is empty."
            }
            let names = TaskStacking.stacks(shown).map { $0.lead.title + ($0.extra > 0 ? " +\($0.extra)" : "") }
            let more = names.count > 12 ? ", and \(names.count - 12) more" : ""
            return "\(list.name) has \(shown.count) \(shown.count == 1 ? "item" : "items"): " + names.prefix(12).joined(separator: ", ") + more + "."
        }
        if spec.overdueOnly {
            var q = TaskLookupSpec(category: spec.category, day: .anytime, status: .open)
            q.assignees = spec.assignees
            let late = store.query(q).filter(\.isOverdue).sorted { $0.effectiveDue < $1.effectiveDue }
            let who = (spec.assignees.count == 1 && !spec.assignees.contains(Assignee.me)) ? "\(spec.assignees[0]) has" : "You have"
            guard !late.isEmpty else { return "\(who) nothing overdue." }
            let stacks = TaskStacking.stacks(late)
            let list = stacks.prefix(10).map { s in
                "\(s.lead.title)\(s.extra > 0 ? " +\(s.extra)" : "") (\(lateNote(s.lead)), \(s.lead.effectiveAssignee))"
            }.joined(separator: "; ")
            let more = stacks.count > 10 ? "; and \(stacks.count - 10) more" : ""
            return "\(who) \(late.count) overdue \(late.count == 1 ? "task" : "tasks"): \(list)\(more)."
        }
        let statusWord = spec.status == .open ? "open " : (spec.status == .done ? "completed " : "")
        let catWord = spec.category.map { $0.label.lowercased() + " " } ?? ""
        let mineOnly = spec.assignees.isEmpty || spec.assignees.contains { $0 == Assignee.me }
        let subject = (spec.assignees.count == 1 && !mineOnly) ? "\(spec.assignees[0]) has" : "You have"

        var whenPhrase = ""
        switch spec.day {
        case .today: whenPhrase = " today, " + Date.now.formatted(.dateTime.weekday(.wide))
        case .tomorrow:
            let t = cal.date(byAdding: .day, value: 1, to: .now) ?? .now
            whenPhrase = " tomorrow, " + t.formatted(.dateTime.weekday(.wide))
        case .anytime: break
        }

        let onDay: [TaskItem]
        let earlier: [TaskItem]
        if spec.day == .anytime {
            onDay = store.query(spec); earlier = []
        } else {
            let b = store.briefing(spec); onDay = b.onDay; earlier = b.earlier
        }

        if onDay.isEmpty && earlier.isEmpty { return "\(subject) no \(statusWord)\(catWord)tasks\(whenPhrase)." }

        var sections: [String] = []
        if onDay.isEmpty {
            sections.append("\(subject) no \(statusWord)\(catWord)tasks due\(whenPhrase).")
        } else {
            sections.append("\(subject) \(onDay.count) \(statusWord)\(catWord)\(onDay.count == 1 ? "task" : "tasks")\(whenPhrase).")
            sections.append(contentsOf: detail(onDay, flat: spec.category != nil || !spec.assignees.isEmpty, showWho: spec.assignees.count != 1))
        }
        if !earlier.isEmpty {
            // Backlog: the same chore missed on several days is shown once with a count.
            var order: [String] = []
            var byTitle: [String: [TaskItem]] = [:]
            for t in earlier {
                let k = t.title.lowercased()
                if byTitle[k] == nil { order.append(k) }
                byTitle[k, default: []].append(t)
            }
            let list = order.prefix(8).compactMap { k -> String? in
                guard let g = byTitle[k], let oldest = g.min(by: { $0.effectiveDue < $1.effectiveDue }) else { return nil }
                let who = spec.assignees.count != 1 ? ", \(oldest.effectiveAssignee)" : ""
                let count = g.count > 1 ? " +\(g.count - 1)" : ""
                return "\(oldest.title)\(count) (\(g.count > 1 ? "oldest " : "")\(lateNote(oldest))\(who))"
            }.joined(separator: ", ")
            let more = order.count > 8 ? ", and \(order.count - 8) more" : ""
            sections.append("Backlog from earlier, still open: " + list + more + ".")
        }
        return sections.joined(separator: " ")
    }
}


// MARK: - Finds "the dusting one" among your tasks

enum TaskMatcher {
    enum Resolution {
        case found([TaskItem])
        case ambiguous(String, [TaskItem])
        case none
    }

    private static let stop: Set<String> = [
        "mark", "complete", "completed", "complet", "finish", "finished", "done", "delete", "remove", "cancel", "drop",
        "reopen", "rename", "change", "edit", "update", "undo", "tick", "check", "cross", "off", "as", "the", "a", "an",
        "my", "task", "tasks", "to", "of", "for", "please", "kitty", "all", "every", "everything", "today", "tomorrow",
        "that", "it", "this", "one", "ones", "i", "ive", "did", "with", "from", "on", "in", "is", "are", "not", "pending",
        "incomplete", "undone", "get", "rid", "can", "you", "could", "and", "list", "item", "items", "out", "up", "into",
        "now", "just", "already", "have", "was", "were", "assign", "reassign", "move", "reschedule", "postpone", "push", "delay",
        "till", "until", "tonight", "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "scrap", "discard", "erase", "restore", "hey", "so", "then"
    ]

    /// Words that name a category ("househelp", "maid", "office") so they don't count as task words.
    static func categoryWords(_ c: TaskCategory?) -> Set<String> {
        guard let c else { return [] }
        let extra: [TaskCategory: [String]] = [
            .househelp: ["househelp", "house", "help", "maid", "helper", "housemaid", "housekeeper", "domestic"],
            .work: ["work", "office", "job"], .personal: ["personal"], .family: ["family", "kids"],
            .errands: ["errand", "errands", "shopping"], .health: ["health", "fitness"],
            .finance: ["finance", "money", "bills"], .other: ["other"]
        ]
        return Set(extra[c] ?? [])
    }

    static func tokens(_ s: String, dropping extra: Set<String> = []) -> [String] {
        s.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { ($0.count > 1 || $0.first?.isNumber == true) && !stop.contains($0) && !extra.contains($0) }
    }

    private static func stem(_ w: String) -> String {
        for suf in ["ing", "es", "ed", "s"] where w.count > suf.count + 2 && w.hasSuffix(suf) {
            return String(w.dropLast(suf.count))
        }
        return w
    }

    static func same(_ a: String, _ b: String) -> Bool {
        let x = stem(a), y = stem(b)
        if x == y { return true }
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        return short.count >= 3 && long.hasPrefix(short) && long.count - short.count <= 2
    }

    /// Resolve one piece of target text against the store.
    /// `pickAll`: return every match (for "all ...") instead of asking which one.
    @MainActor
    static func resolve(_ piece: String, cmd: TaskCommand, status: StatusFilter, pickAll: Bool) -> [Resolution] {
        let store = TaskStore.shared
        var scoped = store.query(TaskLookupSpec(category: cmd.category, day: cmd.day, status: status))
        var wide = store.query(TaskLookupSpec(category: nil, day: .anytime, status: status))
        if let pid = cmd.profileID {            // "mark milk done in my Blinkit order": only look on that list
            scoped = scoped.filter { $0.profileID == pid }
            wide = wide.filter { $0.profileID == pid }
        }

        let qTokens = tokens(piece, dropping: categoryWords(cmd.category).union(cmd.dropWords))
        if qTokens.isEmpty {
            // Only a category / day / "all" was given.
            return [scoped.isEmpty ? .none : .found(scoped)]
        }

        // Try the narrowed list first, then everything (the category guess may differ from the user's).
        for (pool, q) in [(scoped, qTokens), (wide, tokens(piece, dropping: cmd.dropWords))] {
            let r = best(pool, q, pickAll: pickAll, piece: piece)
            if case .none = r { continue }
            return [r]
        }
        return [.none]
    }

    /// Match free text against any list of items (routines, saved plans), ignoring the given words.
    static func resolvePool(_ text: String, pool: [TaskItem], extraStop: Set<String>) -> Resolution {
        let q = tokens(text, dropping: extraStop)
        guard !q.isEmpty else { return .none }
        return best(pool, q, pickAll: false, piece: text)
    }

    private static func best(_ pool: [TaskItem], _ q: [String], pickAll: Bool, piece: String) -> Resolution {
        guard !q.isEmpty else { return .none }
        let need = q.count == 1 ? 1 : (q.count + 1) / 2
        let ordered = pool.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        let scored: [(TaskItem, Int)] = ordered.compactMap { t in
            let tt = tokens(t.title)
            let score = q.filter { w in tt.contains { same(w, $0) } }.count
            return score >= need ? (t, score) : nil
        }
        guard let top = scored.map(\.1).max() else { return .none }
        let winners = scored.filter { $0.1 == top }.map(\.0)
        if pickAll { return .found(scored.map(\.0)) }
        if winners.count == 1 { return .found(winners) }
        if Set(winners.map { $0.title.lowercased() }).count == 1 { return .found([winners[0]]) }
        return .ambiguous(piece, winners)
    }
}

// MARK: - Conversation turns: understand first, show a preview, then apply

enum PreviewColor { case neutral, purple, indigo, red, orange, person(String) }

struct PreviewTag: Identifiable {
    let id = UUID()
    var text: String
    var icon: String
    var color: PreviewColor = .neutral
}

struct PreviewRow: Identifiable {
    let id = UUID()
    var icon: String
    var title: String
    var tags: [PreviewTag] = []
}

/// What Kitty is about to do. Nothing changes until `apply` runs.
struct Proposal {
    let id = UUID()                 // what the ConfirmationManager arms and consumes: one proposal executes at most once
    var title: String
    var rows: [PreviewRow]
    var notes: [String] = []
    var confirmLabel = "Add"
    var autoConfirm = true          // fills a 2-second button, then applies by itself
    var destructive = false         // never applies by itself
    var runImmediately = false      // straightforward and low risk: just do it
    var pendingTitle: String? = nil // what the conversation should call this while it waits to be saved
    var pendingPlaybook: String? = nil
    var prompt: String? = nil       // the one short question Kitty asks for this preview, "Should I save these?"
    var apply: @MainActor () async -> AgentReply
}

enum TurnResult {
    case wait                       // the user is probably still talking: say nothing, keep listening
    case reply(AgentReply)          // an answer: nothing to confirm
    case proposal(Proposal)         // a preview to confirm
    case question(String)           // Kitty needs more information and will not guess
}

struct ChangePlan {
    var action: AgentAction
    var cmd: TaskCommand
    var items: [TaskItem]
    var problems: [String]
}

enum ChangeOutcome {
    case plan(ChangePlan)
    case problem(String)
}

enum ForgetTarget {
    case profile(TaskProfile)
    case routine(Routine)
    case playbook(Playbook)
    case problem(String)
}

extension TaskAgent {

    // MARK: Entry point for the conversation screen

    @MainActor
    static func propose(_ text: String) async -> TurnResult {
        let store = TaskStore.shared
        store.refreshRoutines()

        if isBareAcknowledgement(text) { return .question("I'm listening. What would you like me to do?") }

        let routed = await TaskPlanner.route(text)
        switch routed {
        case .ask:
            return .reply(await askReply(text))

        case .chat:
            return .reply(AgentReply(message: await TaskPlanner.chat(text), didAdd: false))

        case .teach:
            return await proposeTeach(text)

        case .profile:
            return await proposeProfile(text)

        case .add:
            return await proposeAdd(text)

        case .clear:
            let done = store.tasks.filter(\.isDone)
            guard !done.isEmpty else {
                return .reply(AgentReply(message: "There are no completed tasks to clear.", didAdd: false))
            }
            return .proposal(Proposal(
                title: "Clear \(done.count) completed \(done.count == 1 ? "task" : "tasks")",
                rows: done.prefix(8).map { PreviewRow(icon: "checkmark.circle.fill", title: $0.title) },
                confirmLabel: "Clear",
                autoConfirm: false,
                destructive: true,
                apply: {
                    let n = store.clearCompleted()
                    return AgentReply(message: "Cleared \(n) completed \(n == 1 ? "task" : "tasks").", didAdd: false, didChange: n > 0)
                }))

        case .complete, .reopen, .rename, .delete, .assign, .reschedule:
            return await proposeChange(routed, text)
        }
    }

    private static func isBareAcknowledgement(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let filler: Set<String> = ["yes", "yeah", "yep", "no", "nope", "ok", "okay", "sure", "hmm", "um", "uh", "thanks", "please", "kitty", "hey"]
        return words.count <= 2 && words.allSatisfy { filler.contains($0) }
    }

    // MARK: Questions

    @MainActor
    static func askReply(_ text: String, useModel: Bool = true, base: TaskLookupSpec? = nil) async -> AgentReply {
        if text.lowercased().contains("playbook") { return playbookReply(text) }
        if isRoutineQuestion(text) { return AgentReply(message: routinesSummary(), didAdd: false) }
        var spec = useModel ? await TaskPlanner.interpretQuery(text) : TaskPlanner.ruleQuery(text)
        let lower = text.lowercased()
        // The model sometimes invents a category; keep one only if the words really point to it.
        if TaskCategory.mentioned(in: lower) == nil { spec.category = nil }
        // Say what you want to see: open tasks, overdue ones, finished ones, or everything.
        let words = Set(lower.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let wantsOverdue = !words.isDisjoint(with: ["overdue", "backlog", "late", "missed", "behind"]) || lower.contains("past due")
        let wantsDone = !words.isDisjoint(with: ["done", "completed", "finished", "complete"]) && !lower.contains("not done")
        let wantsOpen = !words.isDisjoint(with: ["open", "pending", "remaining", "outstanding", "incomplete", "unfinished"])
            || lower.contains("not done") || lower.contains("left to do")
        let wantsAll = !words.isDisjoint(with: ["everything"]) || lower.contains("all tasks") || lower.contains("all my tasks")
            || lower.contains("all the tasks") || lower.contains("every task")
        if wantsOverdue {
            spec.overdueOnly = true; spec.status = .open
        } else if wantsDone {
            spec.status = .done
        } else if wantsOpen {
            spec.status = .open
        } else if wantsAll {
            spec.status = .all
        }
        if let who = mentionedAssignee(in: text) {
            spec.assignees = who == Assignee.me ? [Assignee.me, Assignee.family] : [who]
            spec.category = nil
        } else if spec.category == nil, isMyTasksQuestion(lower) {
            spec.assignees = [Assignee.me, Assignee.family]      // "my tasks" = tagged Me, or for the whole Family
        }
        if let list = TaskStore.shared.profileMentioned(in: text) {
            spec.profileID = list.id                  // "what's in my Blinkit order"
            spec.assignees = []
            spec.category = nil
            spec.day = .anytime
            spec.overdueOnly = false
        }
        if let base { spec = refine(base, with: spec, words: words, lower: lower) }
        let facts = answer(spec)
        var message = facts
        // Short answers are already fine. Longer ones get worded by the model, following the Kitty guide.
        if useModel, KittyGuideStore.smartReplies, facts.count > 90,
           let worded = await TaskPlanner.speakableSummary(question: text, facts: facts) {
            message = worded
        }
        let items = listItems(for: spec)
        return AgentReply(message: message, didAdd: false, spec: spec, hint: narrowingHint(for: spec, items: items))
    }

    /// The tasks a lookup shows, in the same sense as `answer(_:)`.
    @MainActor
    static func listItems(for spec: TaskLookupSpec) -> [TaskItem] {
        let store = TaskStore.shared
        if spec.profileID != nil || spec.overdueOnly || spec.day == .anytime { return store.query(spec) }
        let b = store.briefing(spec)
        return b.onDay + b.earlier
    }

    /// A long, unfiltered list is the one case where a narrower view helps. Suggests the split that divides it most evenly
    /// (by person, category or today) and says nothing for short lists or lists already narrowed.
    @MainActor
    static func narrowingHint(for spec: TaskLookupSpec, items: [TaskItem]) -> String? {
        guard items.count > 8, spec.assignees.isEmpty, spec.category == nil, spec.day == .anytime, !spec.overdueOnly,
              spec.profileID == nil, spec.status == .open else { return nil }
        let total = Double(items.count)

        func top(_ names: [String]) -> [(name: String, count: Int)] {
            Dictionary(grouping: names, by: { $0 }).map { (name: $0.key, count: $0.value.count) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        }
        var best: (balance: Double, text: String)?
        func consider(_ balance: Double, _ text: String) {
            if balance >= 0.2, balance > (best?.balance ?? 0) { best = (balance, text) }
        }

        let people = top(items.map(\.effectiveAssignee))
        if people.count >= 2 {
            func possessive(_ n: String) -> String { n == Assignee.me ? "yours" : "\(n)'s" }
            consider(1 - Double(people[0].count) / total, "Want just \(possessive(people[0].name)), or \(possessive(people[1].name))?")
        }
        let categories = top(items.map(\.categoryLabel))
        if categories.count >= 2 {
            consider(1 - Double(categories[0].count) / total, "Want just \(categories[0].name.lowercased()), or \(categories[1].name.lowercased())?")
        }
        let cal = Calendar.current
        let today = items.filter { cal.isDateInToday($0.effectiveDue) }.count
        if today > 0, today < items.count {
            let share = Double(today) / total
            consider(min(share, 1 - share), "Want just today's?")
        }
        return best?.text
    }

    /// A follow-up like "only tomorrow" or "just the maid" changes only what it mentions. Everything else stays as it was.
    @MainActor
    static func refine(_ base: TaskLookupSpec, with new: TaskLookupSpec, words: Set<String>, lower: String) -> TaskLookupSpec {
        var out = base
        if TaskCategory.mentioned(in: lower) != nil { out.category = new.category }
        if words.contains("tomorrow") { out.day = .tomorrow }
        else if !words.isDisjoint(with: ["today", "tonight"]) || lower.contains("this morning") { out.day = .today }
        else if lower.contains("any day") || lower.contains("all days") || lower.contains("any date") || words.contains("anytime") { out.day = .anytime }
        if words.contains("overdue") || lower.contains("backlog") || words.contains("late") || lower.contains("past due") {
            out.overdueOnly = true; out.status = .open
        } else if new.status != .open || !words.isDisjoint(with: ["open", "pending", "remaining", "outstanding", "incomplete", "unfinished"]) || lower.contains("all tasks") {
            out.status = new.status; out.overdueOnly = false
        }
        if !words.isDisjoint(with: ["everyone", "anyone", "everybody"]) {
            out.assignees = []
        } else if mentionedAssignee(in: lower) != nil || isMyTasksQuestion(lower) || !words.isDisjoint(with: ["personal", "mine"]) {
            out.assignees = new.assignees
        }
        if new.profileID != nil { out.profileID = new.profileID; out.assignees = []; out.category = nil; out.day = .anytime }
        return out
    }

    /// Is this short phrase a change to the list just shown ("only tomorrow", "just plants", "what about the maid")?
    @MainActor
    static func isViewRefinement(_ text: String) -> Bool {
        let lower = text.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard let first = words.first, words.count <= 9 else { return false }
        let doing: Set<String> = ["add", "create", "remind", "buy", "call", "clean", "delete", "remove", "complete", "mark", "rename", "assign",
                                  "move", "reschedule", "schedule", "make", "teach", "clear", "finish", "wash", "fix", "pay", "book", "order",
                                  "cook", "water", "send", "take", "bring", "pick", "cancel", "yes", "no", "okay", "thanks"]
        guard words.allSatisfy({ !doing.contains($0) }) else { return false }
        let lead: Set<String> = ["only", "just", "and", "also", "but", "now", "instead", "for", "what", "whats", "how", "show", "filter", "narrow",
                                 "those", "them", "same", "with", "in", "on", "by", "any", "which", "not", "without", "except", "list"]
        let daySignals: Set<String> = ["today", "tomorrow", "tonight", "overdue", "late", "done", "completed", "open", "pending", "personal",
                                       "family", "mine", "everyone", "anyone", "everything", "all"]
        let wordSignals = words.contains { daySignals.contains($0) } || lower.contains("this morning") || lower.contains("any day")
        let signal = wordSignals || TaskCategory.mentioned(in: lower) != nil || mentionedAssignee(in: lower) != nil
        guard signal else { return false }
        guard lead.contains(first) || daySignals.contains(first) || TaskCategory.mentioned(in: first) != nil
                || mentionedAssignee(in: first) != nil else { return false }
        // "show tasks for tomorrow" is a whole new question; "only tomorrow" narrows the last one.
        let namesTasks = words.contains { ["task", "tasks", "todo", "todos", "list"].contains($0) }
        if namesTasks, !["only", "just", "and", "also", "now", "but", "instead", "same"].contains(first) { return false }
        return true
    }

    // MARK: Adding

    /// Asks instead of guessing when a repeating task is missing its day.
    private static func missingInfoQuestion(_ text: String) -> String? {
        let t = text.lowercased()
        let weekly = t.contains("weekly") || t.contains("every week") || t.contains("once a week") || t.contains("other week")
        if weekly, TaskPlanner.weekdaysMentioned(t).isEmpty {
            return "Which day of the week should that repeat?"
        }
        let monthly = ["monthly", "every month", "once a month", "each month"].contains { t.contains($0) }
        if monthly, t.range(of: "\\d{1,2}(st|nd|rd|th)", options: .regularExpression) == nil {
            return "Which day of the month should that repeat?"
        }
        let vague = ["regularly", "often", "periodically", "frequently", "from time to time"].contains { t.contains($0) }
        if vague, TaskPlanner.ruleRecurrence(in: text) == nil {
            return "How often should that repeat? For example every day, or every Saturday."
        }
        return nil
    }

    private static func plannedTags(_ p: PlannedTask, assumed: inout Bool) -> [PreviewTag] {
        let today = Calendar.current.startOfDay(for: .now)
        let who = p.assignee ?? (p.category == .househelp ? Assignee.househelp : Assignee.me)
        var tags: [PreviewTag] = []
        if p.assignee == nil { assumed = true }
        tags.append(PreviewTag(text: p.assignee == nil ? "\(who) (assumed)" : who, icon: "person.fill", color: .person(who)))
        if let rec = p.recurrence {
            tags.append(PreviewTag(text: rec.scheduleText, icon: "repeat", color: .purple))
        } else {
            let due = p.due ?? today
            if p.due == nil { assumed = true }
            tags.append(PreviewTag(text: p.due == nil ? "\(dueWord(due)) (assumed)" : dueWord(due), icon: "calendar"))
        }
        if let m = p.timeMinutes {
            tags.append(PreviewTag(text: DaySlot.clockLabel(m), icon: DaySlot.from(minutes: m).symbol, color: .indigo))
        } else if let s = p.slot, s != .anytime {
            tags.append(PreviewTag(text: s.label, icon: s.symbol, color: .indigo))
        }
        if let name = p.categoryName { tags.append(PreviewTag(text: name, icon: p.category.symbol)) }
        if let pr = p.priority {
            tags.append(PreviewTag(text: pr.capitalized + " priority", icon: "flag.fill",
                                   color: pr == "high" ? .red : (pr == "medium" ? .orange : .neutral)))
        }
        return tags
    }

    private static func listTags(_ name: String, isNew: Bool, _ p: PlannedTask) -> [PreviewTag] {
        var tags = [PreviewTag(text: name, icon: TaskProfile.symbol(for: name), color: .orange)]
        if isNew { tags.append(PreviewTag(text: "New list", icon: "sparkles", color: .purple)) }
        if let who = p.assignee { tags.append(PreviewTag(text: who, icon: "person.fill", color: .person(who))) }
        if let due = p.due { tags.append(PreviewTag(text: dueWord(due), icon: "calendar")) }
        return tags
    }

    @MainActor
    private static func proposeAdd(_ text: String) async -> TurnResult {
        let store = TaskStore.shared
        if let question = missingInfoQuestion(text) { return .question(question) }

        let result = await TaskPlanner.plan(text)
        guard !result.tasks.isEmpty else { return .question("I didn't catch a task in that. What should I add?") }
        return buildAddProposal(result.tasks, usedAI: result.usedAI, text: text)
    }

    /// Turns planned tasks, routines, list items and playbook offers into one preview.
    @MainActor
    static func buildAddProposal(_ tasks: [PlannedTask], usedAI: Bool, text: String, sink: SaveSink? = nil) -> TurnResult {
        let store = TaskStore.shared
        let sink = sink ?? StoreSaveSink()
        let result = (tasks: tasks, usedAI: usedAI)

        var oneOffs: [PlannedTask] = []
        var routines: [PlannedTask] = []
        var listed: [PlannedTask] = []                // items for a named list
        var candidate: (pb: Playbook, due: Date?)? = nil
        for p in result.tasks {
            if p.recurrence != nil {
                routines.append(p)
            } else if let list = p.profile, !TaskStore.cleanProfileName(list).isEmpty {
                listed.append(p)
            } else if candidate == nil, let pb = sink.playbook(matching: p.title) {
                candidate = (pb, p.due)            // a taught procedure: ask before adding the whole thing
            } else {
                oneOffs.append(p)
            }
        }

        let today = Calendar.current.startOfDay(for: .now)
        var rows: [PreviewRow] = []
        var assumed = false
        for p in oneOffs { rows.append(PreviewRow(icon: "circle", title: p.title, tags: plannedTags(p, assumed: &assumed))) }
        for p in routines { rows.append(PreviewRow(icon: "repeat", title: p.title, tags: plannedTags(p, assumed: &assumed))) }

        // A list is found by name, or created the first time you mention it.
        var listPlans: [(name: String, existing: TaskProfile?, items: [PlannedTask])] = []
        for p in listed {
            let raw = p.profile ?? ""
            let existing = store.profile(named: raw)
            let name = existing?.name ?? TaskStore.cleanProfileName(raw)
            if let i = listPlans.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                listPlans[i].items.append(p)
            } else {
                listPlans.append((name, existing, [p]))
            }
        }
        for plan in listPlans {
            for p in plan.items {
                rows.append(PreviewRow(icon: TaskProfile.symbol(for: plan.name), title: p.title,
                                       tags: listTags(plan.name, isNew: plan.existing == nil, p)))
            }
        }
        let playbookChoice = candidate
        let playbookDue = playbookChoice.map { $0.due ?? TaskPlanner.ruleDue(text) ?? today } ?? today
        if let c = playbookChoice {
            rows.append(PreviewRow(icon: "list.bullet.rectangle", title: "\(c.pb.name) playbook", tags: [
                PreviewTag(text: "\(c.pb.steps.count) tasks", icon: "list.number", color: .orange),
                PreviewTag(text: dueWord(playbookDue), icon: "calendar")
            ]))
        }

        var bits: [String] = []
        if !oneOffs.isEmpty { bits.append("\(oneOffs.count) \(oneOffs.count == 1 ? "task" : "tasks")") }
        if !routines.isEmpty { bits.append("\(routines.count) \(routines.count == 1 ? "routine" : "routines")") }
        for plan in listPlans { bits.append("\(plan.items.count) \(plan.items.count == 1 ? "item" : "items") to \(plan.name)") }
        if playbookChoice != nil { bits.append("a playbook") }

        var notes: [String] = []
        if assumed { notes.append("“Assumed” means you didn't say it. Keep talking, like “make that tomorrow”, to change it.") }
        for plan in listPlans where plan.existing == nil { notes.append("“\(plan.name)” is a new list. I'll create it.") }
        if !result.usedAI { notes.append("I used simple rules because \(TaskPlanner.fallbackReason()), so please check this.") }

        let tasksToAdd = oneOffs
        let routinesToAdd = routines
        let listsToAdd = listPlans
        let once = Once()
        return .proposal(Proposal(
            title: "Add " + bits.joined(separator: " and "),
            rows: rows,
            notes: notes,
            confirmLabel: "Add",
            autoConfirm: playbookChoice == nil,
            apply: {
                guard once.fire() else { return AgentReply(message: "Already saved.", didAdd: false) }     // never twice
                var created: [UUID] = sink.saveTasks(tasksToAdd)
                var saved = 0
                var already = 0
                var routineIDs = Set<UUID>()
                var savedRoutines: [PlannedTask] = []
                for p in routinesToAdd {
                    guard p.recurrence != nil else { continue }
                    if let id = sink.saveRoutine(p) {
                        saved += 1
                        routineIDs.insert(id)
                        savedRoutines.append(p)
                    } else { already += 1 }
                }
                var listMessages: [String] = []
                for plan in listsToAdd {
                    let made = store.ensureProfile(plan.name)
                    var count = 0
                    for p in plan.items {
                        let items = store.addItems([p.title], to: made.profile, due: p.due, assignee: p.assignee, notes: [p.notes])
                        count += items.count
                        created += items.map(\.id)
                    }
                    listMessages.append("\(count) \(count == 1 ? "item" : "items") to \(made.profile.name)\(made.created ? " (new list)" : "").")
                }
                var playbookCount = 0
                if let c = playbookChoice {
                    let ids = sink.addPlaybookTasks(c.pb, due: playbookDue)
                    playbookCount = ids.count
                    created += ids
                }
                created += await sink.finishSaving(routineIDs: routineIDs)

                // Show the tasks themselves, with one short grouped confirmation.
                if !created.isEmpty {
                    let message = (tasksToAdd.isEmpty && savedRoutines.isEmpty)
                        ? "Here they are:"
                        : DraftSummary.saved(tasks: tasksToAdd, routines: savedRoutines, alreadyHad: already)
                    return AgentReply(message: message, didAdd: true, didChange: true, created: created)
                }
                var parts: [String] = []
                if saved > 0 { parts.append("Saved \(saved) \(saved == 1 ? "routine" : "routines").") }
                if already > 0 { parts.append("You already had \(already) of those routines.") }
                parts.append(contentsOf: listMessages)
                if let c = playbookChoice { parts.append("Added \(playbookCount) tasks for \(c.pb.name).") }
                return AgentReply(message: parts.isEmpty ? "Nothing new to add." : parts.joined(separator: " "),
                                  didAdd: true, didChange: true)
            }))
    }

    // MARK: Teaching a playbook

    @MainActor
    private static func proposeTeach(_ text: String) async -> TurnResult {
        let planned = await TaskPlanner.planPlaybook(text)
        guard let pb = planned.result, pb.steps.count >= 2 else {
            return .question("I couldn't pick out the steps yet. Tell me each step and who does it, like: the cook marinates the chicken, the maid washes the rice.")
        }
        let rows = pb.steps.enumerated().map { i, step in
            PreviewRow(icon: "\(min(i + 1, 50)).circle", title: step.title,
                       tags: step.assignee.map { [PreviewTag(text: $0, icon: "person.fill", color: .person($0))] } ?? [])
        }
        var notes: [String] = []
        if !planned.usedAI { notes.append("I used simple rules because \(TaskPlanner.fallbackReason()), so please check the steps.") }
        let store = TaskStore.shared
        return .proposal(Proposal(
            title: "Save the \(pb.name) playbook",
            rows: rows,
            notes: notes,
            confirmLabel: "Save",
            apply: {
                let replaced = store.savePlaybook(name: pb.name, category: pb.category, steps: pb.steps)
                return AgentReply(message: "\(replaced ? "Updated" : "Saved") your \(pb.name) playbook with \(pb.steps.count) tasks. Next time you say you're planning it, I'll ask before adding them.",
                                  didAdd: false, didChange: true)
            }))
    }

    // MARK: Changing existing tasks

    private static func taskTags(_ t: TaskItem) -> [PreviewTag] {
        var tags = [PreviewTag(text: t.effectiveAssignee, icon: "person.fill", color: .person(t.effectiveAssignee))]
        if t.isOverdue {
            tags.append(PreviewTag(text: "\(t.daysOverdue)d overdue", icon: "exclamationmark.triangle.fill", color: .red))
        } else {
            tags.append(PreviewTag(text: t.dueLabel, icon: "calendar"))
        }
        if let time = t.timeLabel { tags.append(PreviewTag(text: time, icon: t.sortSlot.symbol, color: .indigo)) }
        return tags
    }

    @MainActor
    static func planChange(_ action: AgentAction, text: String, useModel: Bool = true) async -> ChangeOutcome {
        var cmd = useModel ? await TaskPlanner.interpretCommand(text, action: action) : TaskPlanner.ruleCommand(text, action: action)
        if let list = TaskStore.shared.profileMentioned(in: text) {
            cmd.profileID = list.id                                // "...in my Blinkit order": only that list
            cmd.dropWords = TaskStore.shared.listWords(list)       // and its name is not part of the item
        }

        if action == .rename {
            guard !cmd.newTitle.isEmpty else {
                return .problem("What should the new name be? Try: rename dusting to dust the shelves.")
            }
            switch TaskMatcher.resolve(cmd.target, cmd: cmd, status: .all, pickAll: false).first {
            case .found(let items)?:
                return .plan(ChangePlan(action: action, cmd: cmd, items: [items[0]], problems: []))
            case .ambiguous(_, let items)?:
                return .problem("Which one: " + items.prefix(4).map(\.title).joined(separator: ", or ") + "?")
            default:
                return .problem("I couldn't find that task. Which one do you mean?")
            }
        }
        if action == .assign, cmd.newAssignee.isEmpty {
            return .problem("Who should it go to? Try: assign sweeping to the maid.")
        }
        if action == .reschedule, cmd.newDue == nil {
            return .problem("Which day should I move it to? Try: tomorrow, or Saturday.")
        }

        let status: StatusFilter
        switch action {
        case .complete, .assign, .reschedule: status = .open
        case .reopen: status = .done
        default: status = .all
        }

        // "delete everything" with nothing to narrow it is too risky by voice.
        let hasTarget = !TaskMatcher.tokens(cmd.target, dropping: TaskMatcher.categoryWords(cmd.category).union(cmd.dropWords)).isEmpty
        if action == .delete, !hasTarget, cmd.category == nil {
            return .problem("Which task should I delete? Name a task, or a category like househelp.")
        }

        var changed: [TaskItem] = []
        var problems: [String] = []
        let pieces = hasTarget ? TaskStore.splitCompound(cmd.target) : [""]
        for piece in pieces {
            switch TaskMatcher.resolve(piece, cmd: cmd, status: status, pickAll: cmd.all || piece.isEmpty).first {
            case .found(let items)?:
                for item in items where !changed.contains(where: { $0.id == item.id }) { changed.append(item) }
            case .ambiguous(_, let items)?:
                problems.append("Which one did you mean: " + items.prefix(4).map(\.title).joined(separator: ", or ") + "?")
            default:
                if piece.isEmpty {
                    problems.append(action == .complete ? "There are no open tasks matching that." : "There are no matching tasks.")
                } else if action == .complete,
                          case .found(let already)? = TaskMatcher.resolve(piece, cmd: cmd, status: .done, pickAll: false).first {
                    problems.append("\(already[0].title) is already done.")
                } else if action == .reopen,
                          case .found(let already)? = TaskMatcher.resolve(piece, cmd: cmd, status: .open, pickAll: false).first {
                    problems.append("\(already[0].title) is already open.")
                } else {
                    problems.append("I couldn't find a task matching \(piece). Which one do you mean?")
                }
            }
        }
        guard !changed.isEmpty else { return .problem(problems.joined(separator: " ")) }
        return .plan(ChangePlan(action: action, cmd: cmd, items: changed, problems: problems))
    }

    @MainActor
    static func applyChange(_ plan: ChangePlan) -> AgentReply {
        let store = TaskStore.shared
        let action = plan.action
        let cmd = plan.cmd
        let changed = plan.items

        for item in changed {
            switch action {
            case .complete: store.complete(item.id)
            case .reopen: store.reopen(item.id)
            case .delete: store.remove(item.id)
            case .rename: store.rename(item.id, to: cmd.newTitle)
            case .assign:
                store.setAssignee(item.id, to: cmd.newAssignee)
                if let rid = item.routineID { store.setRoutineAssignee(rid, to: cmd.newAssignee) }   // future days follow
            case .reschedule:
                if let d = cmd.newDue { store.setDue(item.id, to: d) }
            default: break
            }
        }

        var parts: [String] = []
        let names = changed.prefix(8).map(\.title).joined(separator: ", ")
        let more = changed.count > 8 ? ", and \(changed.count - 8) more" : ""
        let n = changed.count
        switch action {
        case .rename:
            parts.append("Renamed \(changed[0].title) to \(cmd.newTitle).")
        case .assign:
            let who = Assignee.normalize(cmd.newAssignee)
            let routineNote = changed.contains { $0.routineID != nil } ? " Future days of the routine follow too." : ""
            parts.append((n == 1 ? "Assigned \(names) to \(who)." : "Assigned \(n) tasks to \(who): \(names)\(more).") + routineNote)
        case .reschedule:
            let when = dueWord(cmd.newDue ?? .now)
            parts.append(n == 1 ? "Moved \(names) to \(when)." : "Moved \(n) tasks to \(when): \(names)\(more).")
        default:
            let verb = action == .complete ? "Marked" : (action == .reopen ? "Reopened" : "Deleted")
            let suffix = action == .complete ? " as done" : ""
            parts.append(n == 1 ? "\(verb) \(names)\(suffix)." : "\(verb) \(n) tasks\(suffix): \(names)\(more).")
        }
        parts.append(contentsOf: plan.problems)
        return AgentReply(message: parts.joined(separator: " "), didAdd: false, didChange: true)
    }

    @MainActor
    static func proposeChange(_ action: AgentAction, _ text: String, useModel: Bool = true) async -> TurnResult {
        let store = TaskStore.shared

        if action == .delete, let target = findForgetTarget(text) {
            switch target {
            case .problem(let message):
                return .question(message)
            case .playbook(let pb):
                let rows = pb.steps.enumerated().map { i, step in
                    PreviewRow(icon: "list.number", title: "\(i + 1). \(step.title)",
                               tags: step.assignee.map { [PreviewTag(text: $0, icon: "person.fill", color: .person($0))] } ?? [])
                }
                return .proposal(Proposal(
                    title: "Forget the \(pb.name) playbook", rows: rows, confirmLabel: "Forget", autoConfirm: false, destructive: true,
                    apply: {
                        store.removePlaybook(pb.id)
                        return AgentReply(message: "Forgot your \(pb.name) playbook.", didAdd: false, didChange: true)
                    }))
            case .profile(let p):
                let items = store.items(in: p)
                return .proposal(Proposal(
                    title: "Delete the \(p.name) list",
                    rows: [PreviewRow(icon: p.symbol, title: p.name, tags: [PreviewTag(text: "\(items.count) \(items.count == 1 ? "item" : "items")", icon: "list.number")])],
                    notes: items.isEmpty ? [] : ["This also removes the \(items.count) \(items.count == 1 ? "item" : "items") on it."],
                    confirmLabel: "Delete", autoConfirm: false, destructive: true,
                    apply: {
                        let n = store.items(in: p).count
                        store.removeProfile(p.id, deleteItems: true)
                        return AgentReply(message: "Deleted the \(p.name) list and its \(n) \(n == 1 ? "item" : "items").", didAdd: false, didChange: true)
                    }))
            case .routine(let r):
                let row = PreviewRow(icon: "repeat", title: r.title, tags: [
                    PreviewTag(text: r.scheduleText, icon: "repeat", color: .purple),
                    PreviewTag(text: r.effectiveAssignee, icon: "person.fill", color: .person(r.effectiveAssignee))
                ])
                return .proposal(Proposal(
                    title: "Stop this routine", rows: [row], confirmLabel: "Remove", autoConfirm: false, destructive: true,
                    apply: {
                        store.removeRoutine(r.id)
                        return AgentReply(message: "Removed the routine \(r.title). It won't come back on future days.", didAdd: false, didChange: true)
                    }))
            }
        }

        switch await planChange(action, text: text, useModel: useModel) {
        case .problem(let message):
            return .question(message)
        case .plan(let plan):
            return .proposal(changeProposal(plan))
        }
    }

    @MainActor
    private static func changeProposal(_ plan: ChangePlan) -> Proposal {
        let action = plan.action
        let n = plan.items.count
        let icon: String
        let title: String
        let label: String
        switch action {
        case .complete: icon = "checkmark.circle"; title = n == 1 ? "Mark as done" : "Mark \(n) tasks as done"; label = "Mark done"
        case .reopen: icon = "arrow.uturn.backward.circle"; title = n == 1 ? "Reopen this task" : "Reopen \(n) tasks"; label = "Reopen"
        case .delete: icon = "trash"; title = n == 1 ? "Delete this task" : "Delete \(n) tasks"; label = "Delete"
        case .assign: icon = "person.crop.circle.badge.checkmark"; title = "Assign to \(Assignee.normalize(plan.cmd.newAssignee))"; label = "Assign"
        case .reschedule: icon = "calendar.badge.clock"; title = "Move to \(dueWord(plan.cmd.newDue ?? .now))"; label = "Move"
        case .rename: icon = "pencil"; title = "Rename"; label = "Rename"
        default: icon = "checkmark"; title = "Update"; label = "Apply"
        }
        let rows = TaskStacking.stacks(plan.items).prefix(12).map { stack -> PreviewRow in
            var tags = taskTags(stack.lead)
            if stack.extra > 0 { tags.insert(PreviewTag(text: "+\(stack.extra)", icon: "square.stack.fill", color: .red), at: 0) }
            return PreviewRow(icon: icon,
                              title: action == .rename ? "\(stack.lead.title) → \(plan.cmd.newTitle)" : stack.lead.title,
                              tags: tags)
        }
        return Proposal(
            title: title,
            rows: Array(rows),
            notes: plan.problems,
            confirmLabel: label,
            autoConfirm: action != .delete,
            destructive: action == .delete,
            // Finishing or reopening one clearly matched task is straightforward: just do it.
            runImmediately: (action == .complete || action == .reopen) && n == 1 && plan.problems.isEmpty,
            apply: { applyChange(plan) })
    }

    // MARK: Lists by voice: create, rename, finish, empty, move

    /// "start a new Blinkit order", "create a list called Goa trip"
    @MainActor
    private static func newListName(from text: String) -> String {
        for sep in [" called ", " named "] {
            if let r = text.range(of: sep, options: [.caseInsensitive, .backwards]) {
                return TaskStore.cleanProfileName(String(text[r.upperBound...]))
            }
        }
        let skip: Set<String> = ["create", "start", "make", "set", "up", "add", "a", "an", "new", "my", "the", "our", "please", "for", "profile"]
        let nouns: Set<String> = ["list", "order", "cart", "basket", "checklist", "profile"]
        var kept: [String] = []
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let w = raw.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if skip.contains(w) { continue }
            kept.append(String(raw).trimmingCharacters(in: .punctuationCharacters))
            if nouns.contains(w) { break }
        }
        let name = TaskStore.cleanProfileName(kept.joined(separator: " "))
        return nouns.contains(name.lowercased()) ? "" : name
    }

    @MainActor
    private static func proposeProfile(_ text: String) async -> TurnResult {
        let store = TaskStore.shared
        let t = text.lowercased()

        func whichList() -> TurnResult {
            let names = store.profiles.map(\.name)
            return .question(names.isEmpty
                ? "You don't have any lists yet. Say, for example: add milk to my Blinkit order."
                : "Which list do you mean? You have: " + names.joined(separator: ", ") + ".")
        }

        // Rename: "rename my Blinkit order to Zepto order"
        if t.hasPrefix("rename") {
            guard let r = text.range(of: " to ", options: [.caseInsensitive, .backwards]) else {
                return .question("What should the new name be?")
            }
            let before = String(text[..<r.lowerBound])
            let newName = TaskStore.cleanProfileName(String(text[r.upperBound...]))
            guard let list = store.profileMentioned(in: before) ?? store.profile(named: before) else { return whichList() }
            guard !newName.isEmpty else { return .question("What should the new name be?") }
            return .proposal(Proposal(
                title: "Rename list",
                rows: [PreviewRow(icon: list.symbol, title: "\(list.name) → \(newName)")],
                confirmLabel: "Rename",
                apply: {
                    store.renameProfile(list.id, to: newName)
                    return AgentReply(message: "Renamed \(list.name) to \(newName).", didAdd: false, didChange: true)
                }))
        }

        // Move: "move milk to my Zepto order"
        if t.hasPrefix("move ") || t.hasPrefix("put ") {
            guard let r = text.range(of: " to ", options: [.caseInsensitive, .backwards])
                    ?? text.range(of: " in ", options: [.caseInsensitive, .backwards]) else { return whichList() }
            let before = String(text[..<r.lowerBound])
            let destination = String(text[r.upperBound...])
            let name = store.profile(named: destination)?.name ?? TaskStore.cleanProfileName(destination)
            guard !name.isEmpty else { return whichList() }
            var cmd = TaskCommand()
            cmd.target = before
            switch TaskMatcher.resolve(before, cmd: cmd, status: .open, pickAll: false).first {
            case .found(let items)?:
                let isNew = store.profile(named: destination) == nil
                var notes: [String] = []
                if isNew { notes.append("“\(name)” is a new list. I'll create it.") }
                return .proposal(Proposal(
                    title: "Move to \(name)",
                    rows: items.map { PreviewRow(icon: TaskProfile.symbol(for: name), title: $0.title,
                                                 tags: [PreviewTag(text: name, icon: "tray.full.fill", color: .orange)]) },
                    notes: notes,
                    confirmLabel: "Move",
                    apply: {
                        let target = store.ensureProfile(name).profile
                        items.forEach { store.moveTask($0.id, to: target) }
                        return AgentReply(message: "Moved \(items.count) \(items.count == 1 ? "item" : "items") to \(target.name).", didAdd: false, didChange: true)
                    }))
            case .ambiguous(_, let items)?:
                return .question("Which one: " + items.prefix(4).map(\.title).joined(separator: ", or ") + "?")
            default:
                return .question("I couldn't find that item. Which one do you mean?")
            }
        }

        let mentioned = store.profileMentioned(in: text)
        let clearing = ["clear ", "empty ", "reset "].contains { t.hasPrefix($0) }
        let finishing = ["placed", "ordered", "got everything", "bought everything", "have everything", "done with", "finished with"].contains { t.contains($0) }

        if let list = mentioned, clearing {
            let items = store.items(in: list)
            guard !items.isEmpty else { return .reply(AgentReply(message: "\(list.name) is already empty.", didAdd: false)) }
            return .proposal(Proposal(
                title: "Remove all \(items.count) \(items.count == 1 ? "item" : "items") from \(list.name)",
                rows: items.prefix(8).map { PreviewRow(icon: "trash", title: $0.title) },
                confirmLabel: "Remove",
                autoConfirm: false,
                destructive: true,
                apply: {
                    let n = store.clearItems(in: list)
                    return AgentReply(message: "Removed \(n) \(n == 1 ? "item" : "items") from \(list.name). The list is still there.", didAdd: false, didChange: true)
                }))
        }

        if let list = mentioned, finishing {
            let open = store.items(in: list).filter { !$0.isDone }
            guard !open.isEmpty else { return .reply(AgentReply(message: "Nothing is left open on \(list.name).", didAdd: false)) }
            return .proposal(Proposal(
                title: "Mark everything on \(list.name) as done",
                rows: open.prefix(8).map { PreviewRow(icon: "checkmark.circle", title: $0.title) },
                notes: open.count > 8 ? ["and \(open.count - 8) more"] : [],
                confirmLabel: "Mark done",
                apply: {
                    let n = store.completeAll(in: list)
                    return AgentReply(message: "Marked \(n) \(n == 1 ? "item" : "items") on \(list.name) as done.", didAdd: false, didChange: true)
                }))
        }

        // Create: "start a new Blinkit order", "create a list called Goa trip"
        let wantsNew = t.contains("new list") || t.contains("new order") || t.contains("new profile") || t.contains("list called")
            || t.contains("list named") || ["create ", "start ", "make ", "set up "].contains { t.hasPrefix($0) }
        if wantsNew {
            if let list = mentioned {
                return .reply(AgentReply(message: "You already have a list called \(list.name).", didAdd: false))
            }
            let name = newListName(from: text)
            guard !name.isEmpty else { return .question("What should I call the list?") }
            return .proposal(Proposal(
                title: "Create a new list",
                rows: [PreviewRow(icon: TaskProfile.symbol(for: name), title: name,
                                  tags: [PreviewTag(text: "New list", icon: "sparkles", color: .purple)])],
                confirmLabel: "Create",
                apply: {
                    let made = store.ensureProfile(name)
                    return AgentReply(message: "Created your \(made.profile.name) list. Say, for example: add milk to my \(made.profile.name).", didAdd: false, didChange: true)
                }))
        }

        return whichList()
    }

    // MARK: Routines and playbooks to forget

    @MainActor
    static func findForgetTarget(_ text: String) -> ForgetTarget? {
        let store = TaskStore.shared
        let t = text.lowercased()
        let ignore: Set<String> = ["forget", "stop", "routine", "routines", "recurring", "repeating", "repeat", "daily", "weekly",
                                   "plan", "plans", "playbook", "playbooks", "saved", "day", "week", "each", "other", "alternate", "monthly",
                                   "biweekly", "fortnightly", "month"]

        // "delete my Goa trip list": the sentence is only about the list (otherwise it is an item on it)
        if let list = store.profileMentioned(in: text) {
            let rest = TaskMatcher.tokens(text, dropping: store.listWords(list).union(["forget", "stop"]))
            if rest.isEmpty { return .profile(list) }
        }

        if t.contains("playbook") || t.contains(" plan") || t.hasSuffix("plan") {
            if let pb = store.playbook(matching: text, ignoring: ignore, minWords: 1) { return .playbook(pb) }
            return .problem("I don't have a playbook matching that.")
        }

        let explicit = ["routine", "recurring", "repeating", "repeat"].contains { t.contains($0) }
        let schedule = explicit || ["daily", "weekly", "every day", "every week", "each day", "every other", "alternate", "monthly",
                                    "biweekly", "fortnightly"].contains { t.contains($0) }
        guard schedule else { return nil }

        let pool = store.routines.map { TaskItem(id: $0.id, title: $0.title) }
        switch TaskMatcher.resolvePool(text, pool: pool, extraStop: ignore) {
        case .found(let hits):
            if let r = store.routines.first(where: { $0.id == hits[0].id }) { return .routine(r) }
            return .problem("I couldn't find a routine matching that.")
        case .ambiguous(_, let hits):
            return .problem("Which routine: " + hits.prefix(4).map(\.title).joined(separator: ", or ") + "?")
        case .none:
            return explicit ? .problem("I couldn't find a routine matching that.") : nil
        }
    }
}

// MARK: - Voice turns
//
// The app listens, buffers and decides WHEN a turn might be finished. The on-device model decides WHAT it means,
// once per likely-complete turn. The app validates the answer before anything is saved.

/// The persistent instructions for the model session, exactly as specified, followed by the few-shot examples.
enum PersistentInstructions {
    static let text = """
    You are the voice assistant for a household to-do app.

    You understand only these objects:
    - Task: one actionable action.
    - Routine: one task repeated on a schedule.
    - Playbook: an ordered group of related tasks with one shared goal.

    Your job is to understand the current utterance and decide the next action.

    First decide whether the utterance is semantically complete.

    Return wait=true if the user is still speaking, hesitating, correcting themselves, or the utterance is incomplete.

    Signs of an incomplete utterance:
    - Ends with “and”, “but”, “or”, “then”, “for”, “about”, “to”
    - Ends with “um”, “uh”, “actually”, “wait”
    - Has an action verb but no object
    - Has an object but no action
    - Is an unfinished phrase
    - Sounds like the user is thinking or will continue

    If wait=true, return no task, no playbook, no clarifying question, and an empty spoken response.
    If you fill in a task title, wait MUST be false: a sentence like “Add a task to clean the bathroom” is complete.

    If the utterance is complete, classify the action as one of:
    - create_task
    - create_routine
    - create_playbook
    - update_task
    - complete_task
    - delete_task
    - view_tasks
    - clarify
    - unrelated

    A valid task must have:
    1. An actionable verb, such as clean, buy, wash, call, water, fix, schedule, prepare.
    2. A clear object, such as bathroom, milk, laundry, plants, tap, bill.
    3. Enough context to understand what should be done.

    Use create_routine only when the user states or clearly implies a repeating schedule.
    Use create_playbook when the user wants several ordered related steps for one shared goal.
    If the user lists unrelated actions, return separate tasks.
    “Buy milk and bread” is one shopping task. “Clean the bathroom and buy milk” is two tasks.
    When several items are asked for at once, return every item in the tasks, routines or playbook arrays. Never merge them.

    Extract only explicitly stated metadata:
    - title
    - category
    - due date or time
    - priority
    - assignee
    - frequency or schedule
    - notes

    Never invent missing metadata.

    Choose the most specific sensible category.
    Prefer a category from Known Categories.
    If none fits, create a short new category.
    Use room categories for room-specific work and activity categories otherwise.

    Be brief, warm, and natural.
    Use one short sentence for confirmation.
    Do not repeat the user’s entire request.
    Do not create anything while waiting.

    # Clarification rules

    If the utterance is incomplete, return wait=true and continue listening.

    If the utterance is complete but unclear, identify the single most important missing detail.
    Return action=clarify and ask one short, natural question.

    Ask only for a required detail.
    Do not ask for optional metadata unless the user requests it.
    Offer choices when the likely answers are known.
    Do not repeat a question that has already been answered.
    Do not ask “Are you done?” or “Shall I go ahead and create?” unless confirming a routine, playbook, bulk draft, update, delete, or completion.

    If the user answers a clarification question, incorporate the answer into the pending task, routine, or playbook.
    Then decide whether another required detail is missing.
    If none is missing, save a low-risk task or request confirmation for a routine, playbook, bulk draft, update, delete, or completion.

    If the user says “yes” to a confirmation, execute the pending action immediately.
    Do not ask for confirmation again.
    If the user says “no”, ask what they would like to change.

    Maximum three clarification rounds.
    After three rounds, propose the best interpretation and ask: “Should I save it this way, or would you like to change something?”

    Examples:

    Utterance: “Add a task to…”
    Result: wait=true

    Utterance: “Add a task to clean the…”
    Result: wait=true

    Utterance: “Add a task to clean the bathroom.”
    Result: create_task, title=“Clean bathroom”, category=“Bathroom”

    Utterance: “Add a task for laundry.”
    Result: clarify, question=“What should I do with the laundry—wash, fold, or put it away?”

    Utterance: “Water the plants every morning.”
    Result: create_routine, title=“Water plants”, category=“Plants”, frequency=daily

    Utterance: “Buy milk tomorrow.”
    Result: create_task, title=“Buy milk”, category=“Groceries”, dueDate=tomorrow

    Utterance: “Create a playbook to cook biryani.”
    Result: create_playbook, name=“Cook biryani”, steps=[“Buy ingredients”, “Marinate chicken”, “Cook rice”, “Assemble and cook biryani”]

    Utterance: “Clean the bathroom, buy milk, and water the plants.”
    Result: three separate tasks:
    - Clean bathroom, category=Bathroom
    - Buy milk, category=Groceries
    - Water plants, category=Plants
    (The first goes in title and category. The others go in moreTasks as “title | category”.)

    Utterance: “Add these tasks: dishes, laundry, trash.”
    Result: create_tasks with three drafts: “Wash dishes”, “Do laundry”, “Take out trash”

    Utterance: “Actually, make it high priority.”
    Result: update pending task, priority=high

    Utterance: “What tasks do I have today?”
    Result: view_tasks
    """
}

/// The model's decision in plain Swift, so the validator and tests do not depend on iOS 26.
struct AgentDecisionValue: Equatable {
    var wait = false
    var action = ""
    var title = ""
    var category = ""
    var dueDate = ""
    var dueTime = ""
    var priority = ""
    var assignee = ""
    var frequency = ""
    var notes = ""
    var playbookName = ""
    var playbookSteps: [String] = []
    var clarifyingQuestion = ""
    var spokenResponse = ""
    var moreTasks: [String] = []
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct AgentDecision {
    @Guide(description: "True if user is still speaking or utterance is incomplete")
    var wait: Bool

    @Guide(description: "create_task, create_routine, create_playbook, update_task, complete_task, delete_task, view_tasks, clarify, or unrelated")
    var action: String

    @Guide(description: "Short actionable task title, or empty")
    var title: String

    @Guide(description: "Specific household category, or empty")
    var category: String

    @Guide(description: "ISO date or empty")
    var dueDate: String

    @Guide(description: "ISO time or empty")
    var dueTime: String

    @Guide(description: "low, medium, high, or empty")
    var priority: String

    @Guide(description: "Assignee name or empty")
    var assignee: String

    @Guide(description: "once, daily, weekly, monthly, custom, or empty")
    var frequency: String

    @Guide(description: "Optional notes")
    var notes: String

    @Guide(description: "Playbook name or empty")
    var playbookName: String

    @Guide(description: "Ordered playbook step titles")
    var playbookSteps: [String]

    @Guide(description: "One short clarifying question, or empty")
    var clarifyingQuestion: String

    @Guide(description: "One short natural spoken reply, or empty while waiting")
    var spokenResponse: String

    // Added to the specified type: it has one title, so several unrelated tasks need somewhere to go.
    @Guide(description: "For several unrelated tasks in one utterance: every task after the first, each written as 'title | category'. Otherwise empty.")
    var moreTasks: [String]

    var value: AgentDecisionValue {
        AgentDecisionValue(wait: wait, action: action, title: title, category: category, dueDate: dueDate, dueTime: dueTime,
                           priority: priority, assignee: assignee, frequency: frequency, notes: notes,
                           playbookName: playbookName, playbookSteps: playbookSteps,
                           clarifyingQuestion: clarifyingQuestion, spokenResponse: spokenResponse, moreTasks: moreTasks)
    }
}
#endif

/// Where decisions come from. The real one is Apple's on-device model; tests use a scripted one.
@MainActor
protocol DecisionProviding {
    func decide(prompt: String) async -> AgentDecisionValue?
    /// For utterances the BulkDetector flagged: an array of drafts instead of one.
    func decideBulk(prompt: String) async -> BulkDecisionValue?
}

extension DecisionProviding {
    func decideBulk(prompt: String) async -> BulkDecisionValue? { nil }
}

@MainActor
struct NoModelEngine: DecisionProviding {
    func decide(prompt: String) async -> AgentDecisionValue? { nil }
}

#if canImport(FoundationModels)
/// One model session with the persistent instructions. It is replaced every few turns so the context never fills up.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@MainActor
final class DecisionEngine: DecisionProviding {
    static let maxTurnsPerSession = 6
    static func shouldRotate(turnsSoFar: Int) -> Bool { turnsSoFar >= maxTurnsPerSession }

    private var session: LanguageModelSession?
    private var turns = 0
    private var busy = false

    func decide(prompt: String) async -> AgentDecisionValue? {
        await respond(prompt) { s in try await s.respond(to: prompt, generating: AgentDecision.self).content.value }
    }

    func decideBulk(prompt: String) async -> BulkDecisionValue? {
        await respond(prompt) { s in try await s.respond(to: prompt, generating: BulkAgentDecision.self).content.value }
    }

    private func respond<T>(_ prompt: String, _ run: (LanguageModelSession) async throws -> T) async -> T? {
        guard case .available = SystemLanguageModel.default.availability else {
            Breadcrumb.log("decision: model unavailable: \(TaskPlanner.fallbackReason())")
            return nil
        }
        if Self.shouldRotate(turnsSoFar: turns) { session = nil; turns = 0 }
        // A session answers one request at a time. If one is still running, use a fresh session for this one.
        let reuse = !busy
        let s = reuse ? (session ?? LanguageModelSession(instructions: PersistentInstructions.text))
                      : LanguageModelSession(instructions: PersistentInstructions.text)
        if reuse { session = s; busy = true; turns += 1 }
        defer { if reuse { busy = false } }
        do {
            return try await run(s)
        } catch {
            Breadcrumb.log("decision: failed: \(String(describing: error).prefix(140))")
            if reuse { session = nil; turns = 0 }     // a failed turn can leave a session unusable (for example a full context)
            return nil
        }
    }
}
#endif

/// The short per-turn prompt. It never carries the conversation history.
enum PromptBuilder {
    /// An utterance with no clear actions that is still too long keeps its beginning and its end; the front is never cut off.
    static let maxUtteranceCharacters = 900
    static let maxCategories = 12

    static let maxContextCharacters = 300

    /// `digest`: for a long turn, the shared context and one line per action instead of the whole rambling utterance.
    static func build(utterance: String, pendingTask: String?, pendingPlaybook: String?,
                      knownCategories: [String], now: Date, calendar: Calendar = .current, context: String = "",
                      digest: String? = nil) -> String {
        var u = utterance.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "'")
        if u.count > maxUtteranceCharacters {
            let half = maxUtteranceCharacters / 2
            u = String(u.prefix(half)) + " … " + String(u.suffix(half))
        }
        let said = digest.map { "Current utterance (a long turn, chatter removed; one action per line):\n" + $0.replacingOccurrences(of: "\"", with: "'") }
            ?? "Current utterance: \"\(u)\""
        let categories = knownCategories.prefix(maxCategories).joined(separator: ", ")
        let pendingLabel = pendingTask.map { String($0.prefix(80)) } ?? "none"
        let playbookLabel = pendingPlaybook.map { String($0.prefix(80)) } ?? "none"
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return """
        \(said)
        Pending task: \(pendingLabel)
        Pending playbook: \(playbookLabel)
        Known categories: \(categories.isEmpty ? "none" : categories)
        Current date: \(f.string(from: now))
        \(context.isEmpty ? "" : String(context.prefix(maxContextCharacters)))

        Decide whether this utterance is complete.
        If incomplete, return wait=true.
        If complete but unclear, return clarify with one short question.
        If complete and valid, classify and extract the task, routine, or playbook.
        """
    }
}

enum ActionLexicon {
    static let verbs: Set<String> = [
        "add", "arrange", "ask", "bake", "bathe", "bring", "brush", "buy", "call", "cancel", "change", "charge", "check", "clean",
        "clear", "close", "collect", "comb", "complete", "confirm", "cook", "create", "cut", "declutter", "defrost", "deliver",
        "disinfect", "do", "drain", "dry", "dust", "email", "empty", "feed", "fill", "find", "finish", "fix", "fold", "get",
        "give", "groom", "hang", "iron", "journal", "kill", "label", "load", "lock", "make", "mark", "mop", "move", "mow", "order",
        "organise", "organize", "pack", "pay", "pick", "plan", "plant", "polish", "pour", "prepare", "print", "put", "read",
        "recharge", "refill", "refuel", "remind", "remove", "renew", "repair", "replace", "reply", "reset", "return", "rinse",
        "sanitize", "schedule", "scrub", "send", "serve", "service", "set", "sew", "shop", "shred", "sort", "soak", "stock",
        "sweep", "switch", "take", "tidy", "trim", "turn", "unload", "unpack", "update", "vacuum", "visit", "walk", "wash", "water",
        "wipe", "wrap", "book", "meet", "pickup", "dispose", "restock", "spray", "steam", "peel", "chop", "boil", "heat", "wake",
        "test", "inspect", "weigh", "submit", "file", "register", "apply", "donate", "recycle", "throw", "bleach", "descale",
        "write", "draft", "review", "research", "build", "develop", "launch", "outline", "analyze", "analyse", "finalize", "finalise",
        "brainstorm", "evaluate", "assess", "define", "publish", "approve", "negotiate", "design",
        "validate", "verify", "implement", "deploy", "release", "ship", "improve", "optimize", "optimise", "investigate", "discuss",
        "align", "share"
    ]
}

// MARK: Local gate: obviously unfinished speech never reaches the model

struct LocalSemanticPrechecker {
    enum Verdict: Equatable {
        case incomplete(String)
        case mayBeComplete
    }

    // The word lists live in SpeechLexicon so the gate, the cleaner and this prechecker share one copy.
    static let fillers = SpeechLexicon.fillers
    static let dangling = SpeechLexicon.dangling
    static let determiners = SpeechLexicon.determiners
    static let questionStarters = SpeechLexicon.questionStarters
    static let frames = SpeechLexicon.frames
    static let acknowledgements = SpeechLexicon.acknowledgements

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "…", with: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
    }

    // MARK: A setup sentence: "I'm working on a project…", "I'd like to create a list of tasks…"

    /// Phrases that introduce something the speaker is about to list, not something to act on.
    static let announcements: [[String]] = [
        ["working", "on", "a", "project"], ["working", "on", "the", "project"], ["working", "on", "my", "project"],
        ["have", "a", "project"], ["starting", "a", "project"], ["starting", "a", "new", "project"], ["start", "a", "project"],
        ["list", "of", "tasks"], ["list", "of", "to", "dos"], ["list", "of", "todos"], ["list", "of", "things"], ["list", "of", "items"],
        ["task", "list"], ["to", "do", "list"], ["todo", "list"],
        ["a", "few", "things"], ["a", "few", "tasks"], ["a", "few", "items"], ["a", "couple", "of", "things"], ["a", "couple", "of", "tasks"],
        ["some", "tasks"], ["several", "tasks"], ["multiple", "tasks"], ["bunch", "of", "tasks"], ["bunch", "of", "things"],
        ["let", "me", "give", "you"], ["let", "me", "tell", "you"], ["let", "me", "list"], ["let", "me", "dictate"]
    ]
    /// The speaker talking about themselves ("I want…", "we need…", "let me…"): what keeps "show my list of tasks" a request.
    private static let selfWords: Set<String> = ["i", "im", "i'm", "i'd", "id", "i've", "ive", "i'll", "ill", "we", "we're", "were", "let", "let's", "lets"]

    /// True when the speech so far only sets the scene for a list of tasks and names none of them yet.
    /// Kitty keeps listening instead of asking about it: the tasks are about to be said.
    static func announcesMore(_ raw: String) -> Bool {
        let t = tokens(raw)
        guard t.count >= 4, t.prefix(5).contains(where: { selfWords.contains($0) }) else { return false }
        var lastEnd = -1
        for phrase in announcements where phrase.count <= t.count {
            for start in 0...(t.count - phrase.count) where Array(t[start..<(start + phrase.count)]) == phrase {
                lastEnd = max(lastEnd, start + phrase.count)
            }
        }
        guard lastEnd >= 0 else { return false }
        let rest = Array(t[lastEnd...])
        if rest.count <= 2 { return true }                                         // "to add", "for it"
        return rest.count <= 4 && !rest.contains { ActionLexicon.verbs.contains($0) }   // "for that project"
    }

    static func check(_ raw: String) -> Verdict {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .incomplete("empty") }
        if text.hasSuffix("…") || text.hasSuffix("...") { return .incomplete("trailing off") }

        let all = tokens(text)
        guard let last = all.last else { return .incomplete("no words") }
        if acknowledgements.contains(all.joined(separator: " ")) { return .mayBeComplete }
        if text.hasSuffix(",") { return .incomplete("ends with a comma") }
        if dangling.contains(last) { return .incomplete("ends with “\(last)”") }

        var w = all
        while let f = w.first, fillers.contains(f) { w.removeFirst() }
        if w.isEmpty { return .incomplete("only filler") }

        // "actually make it..." is only a correction once it says what to change.
        var correcting = false
        // A bare "wait" opens a correction only as "wait, make it...". "Wait for the plumber" is a task.
        let waitCorrects = text.lowercased().drop(while: { !$0.isLetter }).hasPrefix("wait,")
        for opener in [["actually"], ["no", "wait"], ["wait"], ["i", "mean"], ["scratch", "that"]]
        where w.starts(with: opener) && (opener != ["wait"] || waitCorrects) {
            w.removeFirst(opener.count)
            correcting = true
            break
        }
        if correcting {
            guard let f = w.first else { return .incomplete("correction fragment") }
            if ["make", "change", "set", "move", "put"].contains(f), w.count < 4 { return .incomplete("correction fragment") }
        }

        // Questions about the list are complete once they have a few words.
        if let f = w.first, questionStarters.contains(f) {
            return w.count >= 3 ? .mayBeComplete : .incomplete("unfinished question")
        }

        var framed = false
        outer: while true {
            for f in frames where w.starts(with: f) {
                w.removeFirst(f.count)
                framed = true
                continue outer
            }
            if let first = w.first, ["and", "then", "also"].contains(first) {
                w.removeFirst()
                continue outer
            }
            break
        }

        if w.isEmpty { return .incomplete("action without an object") }
        // "Every day: make beds, wash dishes": a schedule first, then the actions.
        if let first = w.first, ["every", "each"].contains(first), w.count >= 3,
           w.dropFirst().contains(where: { ActionLexicon.verbs.contains($0) }) { return .mayBeComplete }
        if let first = w.first, determiners.contains(first) {
            if framed, w.count >= 2 { return .mayBeComplete }     // "add a task for the project": finished, but the model asks what to do
            return .incomplete("object without an action")
        }
        if w.count == 1 {
            let isVerb = ActionLexicon.verbs.contains(w[0])
            if framed && !isVerb { return .mayBeComplete }      // "add a task for laundry": the model will ask what to do with it
            return .incomplete(isVerb ? "action without an object" : "a single word")
        }
        return .mayBeComplete
    }
}

// MARK: Validation: nothing is saved until Swift agrees with the model

struct ValidatedTask: Equatable {
    var title: String
    var categoryName: String? = nil
    var due: Date? = nil
    var timeMinutes: Int? = nil
    var priority: String? = nil
    var assignee: String? = nil
    var notes: String? = nil
    var recurrence: RecurrenceSpec? = nil

    /// The task in the form the store and the preview use.
    func planned() -> PlannedTask {
        let category: TaskCategory
        if let name = categoryName {
            category = TaskCategory.mentioned(in: name.lowercased()) ?? TaskCategory.guess(from: name + " " + title)
        } else {
            category = TaskCategory.guess(from: title)
        }
        let guess = DaySlot.guess(from: title)
        return PlannedTask(title: title, category: category, due: due, recurrence: recurrence, assignee: assignee,
                           slot: (timeMinutes != nil || guess == .anytime) ? nil : guess, timeMinutes: timeMinutes,
                           profile: nil, categoryName: categoryName, priority: priority, notes: notes)
    }
}

enum Validated: Equatable {
    case wait
    case clarify(String)
    case duplicate(String)
    case tasks([ValidatedTask])
    case routine(ValidatedTask)
    case playbook(name: String, steps: [String], stated: Bool)
    case update(target: String, changes: ValidatedTask)
    case complete(target: String)
    case delete(target: String)
    case view
    case unrelated(String)
}

struct ValidationContext {
    var knownCategories: [String] = []
    /// People the household has named before (assignees on tasks, routines and playbook steps).
    var knownAssignees: [String] = []
    var pendingTitles: [String] = []
    var recentTitles: [String] = []
    var now = Date()
    var calendar = Calendar.current
}

enum TaskValidator {
    static let genericCategories: Set<String> = ["task", "tasks", "other", "misc", "miscellaneous", "general", "stuff", "things",
                                                 "todo", "to do", "to-do", "chores", "chore", "item", "items", "none", "unknown"]
    static let frequencies: Set<String> = ["daily", "weekly", "monthly", "custom"]
    private static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    static func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    // MARK: The checks

    /// A task needs an action and an object. "Laundry" alone is not a task.
    static func isActionable(_ title: String) -> Bool {
        let words = LocalSemanticPrechecker.tokens(title)
        guard words.count >= 2 else { return false }
        if ActionLexicon.verbs.contains(words[0]) { return true }
        if words.count >= 3, ["please", "also", "then"].contains(words[0]), ActionLexicon.verbs.contains(words[1]) { return true }
        return !LocalSemanticPrechecker.determiners.contains(words[0])     // an unfamiliar verb is allowed, a bare noun phrase is not
    }

    static func mentionsDate(_ utterance: String) -> Bool {
        let t = utterance.lowercased()
        let words = ["today", "tomorrow", "tonight", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                     "next week", "next month", "this week", "weekend", "january", "february", "march", "april", "june", "july",
                     "august", "september", "october", "november", "december"]
        if words.contains(where: { t.contains($0) }) { return true }
        return t.range(of: "\\b\\d{1,2}(st|nd|rd|th)\\b|\\b\\d{1,2}[/-]\\d{1,2}\\b", options: .regularExpression) != nil
    }

    /// "tomorrow", "Monday" worked out here with the user's calendar, never taken from the model.
    static func relativeDate(in utterance: String, ctx: ValidationContext) -> Date? {
        let t = utterance.lowercased()
        let cal = ctx.calendar
        let today = cal.startOfDay(for: ctx.now)
        if t.contains("tomorrow") { return cal.date(byAdding: .day, value: 1, to: today) }
        if t.contains("today") || t.contains("tonight") { return today }
        let todayNumber = cal.component(.weekday, from: today)
        for (i, name) in weekdayNames.enumerated() where t.contains(name) {
            return cal.date(byAdding: .day, value: (i + 1 - todayNumber + 7) % 7, to: today)
        }
        return nil
    }

    static func resolveDate(_ value: String, utterance: String, ctx: ValidationContext) -> Date? {
        guard mentionsDate(utterance) else { return nil }               // never invent a date
        if let relative = relativeDate(in: utterance, ctx: ctx) { return relative }
        let f = DateFormatter()
        f.calendar = ctx.calendar
        f.timeZone = ctx.calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = f.date(from: String(v.prefix(10))) { return ctx.calendar.startOfDay(for: d) }
        return nil
    }

    static func resolveTime(_ value: String, utterance: String) -> Int? {
        let t = utterance.lowercased()
        if let m = DaySlot.parseClock(in: utterance) { return m }
        if t.contains("noon") { return 12 * 60 }
        if t.contains("midnight") { return 0 }
        if t.contains("o'clock") || t.contains(":") { return DaySlot.parseHHmm(value) }
        return nil
    }

    static func resolvePriority(_ value: String, utterance: String) -> String? {
        let v = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let cues: [String: [String]] = [
            "high": ["high priority", "urgent", "important", "asap", "critical", "top priority", "highest priority"],
            "medium": ["medium priority", "normal priority", "moderate priority"],
            "low": ["low priority", "not urgent", "no rush", "lowest priority"]
        ]
        guard let list = cues[v] else { return nil }
        let t = utterance.lowercased()
        return list.contains { t.contains($0) } ? v : nil
    }

    /// The assignee, only if the user actually said it. A name that is one close, sound-alike match for a known person
    /// ("Priyah" for "Priya") becomes the known name; one that merely sounds alike ("Rainy" for "Rani") is left to the
    /// read-back question in `ReadBackCheck`; a name that matches nobody is kept as it was heard.
    static func resolveAssignee(_ value: String, utterance: String, known: [String] = []) -> String? {
        let normalized = Assignee.normalize(value)
        guard !normalized.isEmpty else { return nil }
        let said = Set(LocalSemanticPrechecker.tokens(utterance))
        let raw = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // "for Kitty project" names a project, never the person the work is for.
        let tokens = LocalSemanticPrechecker.tokens(utterance)
        let parts = LocalSemanticPrechecker.tokens(raw)
        if let last = parts.last, !parts.isEmpty {
            for (i, w) in tokens.enumerated() where w == last && i + 1 < tokens.count
                && ["project", "app", "list", "board", "workspace", "folder", "channel"].contains(tokens[i + 1]) { return nil }
        }
        let stated = raw.contains(" ") ? utterance.lowercased().contains(raw) : said.contains(raw)
        if stated {
            if !ReadBackCheck.isRole(normalized),
               case .strong(let name) = VocabularyMatcher.match(normalized, in: known.filter { !ReadBackCheck.isRole($0) }) {
                return Assignee.normalize(name)
            }
            return normalized
        }
        if let detected = Assignee.detect(in: utterance), detected.lowercased() == normalized.lowercased() { return normalized }
        return nil
    }

    static func resolveCategory(_ value: String, known: [String]) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        if let k = known.first(where: { key($0) == key(v) }) { return k }       // reuse a known category
        let words = v.split(whereSeparator: { $0.isWhitespace })
        guard words.count <= 3, v.count <= 24, !genericCategories.contains(v.lowercased()) else { return nil }
        return v.prefix(1).uppercased() + v.dropFirst()                          // a new category, but only a specific one
    }

    private static func cleanNotes(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(200))
    }

    private static func clarifyAbout(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "What would you like me to add?" : "What would you like me to do with \(t.lowercased())?"
    }

    static func stepsStated(_ utterance: String) -> Bool {
        let t = utterance.lowercased()
        return t.contains(",") || t.contains(" then ") || t.contains("first") || t.contains("step")
    }

    private static func buildTask(title raw: String, category: String, dueDate: String, dueTime: String, priority: String,
                                  assignee: String, notes: String, utterance: String, ctx: ValidationContext) -> ValidatedTask? {
        let title = TaskPlanner.tidyTitle(raw, removingDay: false)
        guard isActionable(title), title.count <= 80 else { return nil }
        return ValidatedTask(
            title: title,
            categoryName: resolveCategory(category, known: ctx.knownCategories),
            due: resolveDate(dueDate, utterance: utterance, ctx: ctx),
            timeMinutes: resolveTime(dueTime, utterance: utterance),
            priority: resolvePriority(priority, utterance: utterance),
            assignee: resolveAssignee(assignee, utterance: utterance, known: ctx.knownAssignees),
            notes: cleanNotes(notes))
    }

    // MARK: The decision

    /// The on-device model sometimes sets wait=true while it has also filled in a complete task ("Add a task to clean
    /// bathroom" -> wait, title "Clean bathroom"). Swift has the last word: the local gate already judged the sentence
    /// finished, so a wait that comes with a usable title is a mistake, and the task is not thrown away.
    static func waitIsContradicted(_ d: AgentDecisionValue, utterance: String) -> Bool {
        guard LocalSemanticPrechecker.check(utterance) == .mayBeComplete else { return false }
        switch d.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "create_task", "create_routine":  return isActionable(TaskPlanner.tidyTitle(d.title, removingDay: false))
        case "create_playbook", "playbook", "teach_playbook": return !d.playbookSteps.isEmpty
        case "view_tasks": return true                                  // "show me personal tasks" is a whole request
        case "complete_task", "delete_task": return !d.title.trimmingCharacters(in: .whitespaces).isEmpty
        case "update_task": return true
        default: return false
        }
    }

    /// The model also sets wait=true when what it really wants is to ask ("clean" -> action "clarify"). A question the user
    /// never hears looks like Kitty ignoring them, so a wait that arrives with a clarify action becomes the question.
    static func waitIsReallyAQuestion(_ d: AgentDecisionValue) -> Bool {
        d.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == "clarify"
    }

    static func validate(_ d: AgentDecisionValue, utterance: String, context ctx: ValidationContext) -> Validated {
        if d.wait, !waitIsContradicted(d, utterance: utterance), !waitIsReallyAQuestion(d) { return .wait }
        let action = d.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        switch action {
        case "clarify":
            let q = d.clarifyingQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            let one = q.split(separator: "?", omittingEmptySubsequences: true).first.map { String($0) + "?" } ?? q
            return .clarify(q.isEmpty ? ClarificationStateManager.fallbackQuestion(for: .action) : one)

        case "unrelated":
            return .unrelated(d.spokenResponse.trimmingCharacters(in: .whitespacesAndNewlines))

        case "view_tasks":
            return .view

        case "complete_task", "delete_task":
            let target = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { return .clarify("Which task do you mean?") }
            return action == "complete_task" ? .complete(target: target) : .delete(target: target)

        case "update_task":
            var changes = ValidatedTask(title: "")
            changes.priority = resolvePriority(d.priority, utterance: utterance)
            changes.assignee = resolveAssignee(d.assignee, utterance: utterance, known: ctx.knownAssignees)
            changes.due = resolveDate(d.dueDate, utterance: utterance, ctx: ctx)
            changes.timeMinutes = resolveTime(d.dueTime, utterance: utterance)
            changes.notes = cleanNotes(d.notes)
            changes.categoryName = resolveCategory(d.category, known: ctx.knownCategories)
            let any = changes.priority != nil || changes.assignee != nil || changes.due != nil
                || changes.timeMinutes != nil || changes.notes != nil || changes.categoryName != nil
            guard any else { return .clarify("What would you like to change?") }
            return .update(target: d.title.trimmingCharacters(in: .whitespacesAndNewlines), changes: changes)

        case "create_task":
            guard let first = buildTask(title: d.title, category: d.category, dueDate: d.dueDate, dueTime: d.dueTime,
                                        priority: d.priority, assignee: d.assignee, notes: d.notes,
                                        utterance: utterance, ctx: ctx) else {
                return .clarify(clarifyAbout(d.title))
            }
            var tasks = [first]
            for raw in d.moreTasks {
                let parts = raw.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard let title = parts.first, !title.isEmpty else { continue }
                guard let extra = buildTask(title: title, category: parts.count > 1 ? parts[1] : "", dueDate: "", dueTime: "",
                                            priority: "", assignee: "", notes: "", utterance: utterance, ctx: ctx) else {
                    return .clarify(clarifyAbout(title))
                }
                tasks.append(extra)
            }
            // A task that matches the one still waiting to be saved replaces it. One just saved is not added twice.
            let recent = Set(ctx.recentTitles.map(key))
            let fresh = tasks.filter { !recent.contains(key($0.title)) }
            return fresh.isEmpty ? .duplicate(tasks[0].title) : .tasks(fresh)

        case "create_routine":
            guard var task = buildTask(title: d.title, category: d.category, dueDate: d.dueDate, dueTime: d.dueTime,
                                       priority: d.priority, assignee: d.assignee, notes: d.notes,
                                       utterance: utterance, ctx: ctx) else {
                return .clarify(clarifyAbout(d.title))
            }
            let frequency = d.frequency.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard frequencies.contains(frequency) else { return .clarify("How often should it repeat?") }
            let lower = utterance.lowercased()
            var spec = TaskPlanner.ruleRecurrence(in: utterance)?.spec
            switch frequency {
            case "weekly":
                if TaskPlanner.weekdaysMentioned(lower).isEmpty { return .clarify("Which day of the week should it repeat?") }
            case "monthly":
                if lower.range(of: "\\d{1,2}(st|nd|rd|th)", options: .regularExpression) == nil {
                    return .clarify("Which day of the month should it repeat?")
                }
            case "daily":
                if spec == nil { spec = RecurrenceSpec() }
            default:
                break
            }
            guard let schedule = spec else { return .clarify("How often should it repeat?") }
            task.recurrence = schedule
            return .routine(task)

        case "create_playbook":
            let rawName = d.playbookName.isEmpty ? d.title : d.playbookName
            let name = TaskPlanner.tidyTitle(rawName, removingDay: false)
            guard !name.isEmpty else { return .clarify("What should I call the playbook?") }
            let steps = d.playbookSteps.map { TaskPlanner.tidyTitle($0, removingDay: false) }.filter { !$0.isEmpty }
            guard !steps.isEmpty else { return .clarify("What steps should it include?") }
            return .playbook(name: name, steps: Array(steps.prefix(12)), stated: stepsStated(utterance))

        default:
            return .clarify("Sorry, I didn't catch that. What would you like me to do?")
        }
    }
}

// MARK: What the conversation is holding on to

/// The state machine for one conversation, plus the item waiting to be saved, the question waiting for an answer, and
/// what was just created.
///
///   idle -> listening -> pendingTask / pendingRoutine / pendingPlaybook / pendingBulkDraft -> awaitingConfirmation -> idle
///                     \-> awaitingClarification -> (answer) -> listening / pending... / awaitingClarification (next slot)
///
/// A low-risk task or single routine sits in pendingTask / pendingRoutine for the two-second countdown and then saves.
/// Playbooks, bulk drafts, updates, deletes and completions go on to awaitingConfirmation and wait for an explicit "yes".
final class ConversationStateManager {
    static let recentWindow: TimeInterval = 600

    var pendingTitles: [String] = []
    var pendingPlaybook: String?
    var pendingPlanned: [PlannedTask] = []
    var clarification: String?
    var awaitingConfirmation: Bool { phase == .awaitingConfirmation }
    private(set) var recent: [(title: String, at: Date)] = []
    private(set) var lastCreatedID: UUID?
    private(set) var lastCreatedAt: Date?

    // The v30 state machine
    private(set) var phase: ConversationPhase = .idle
    private(set) var transitions: [ConversationPhase] = []
    private(set) var micOn = false
    let clarify = ClarificationStateManager()
    let drafts = BulkDraftManager()
    let confirmation = ConfirmationManager()
    private(set) var pendingProposal: Proposal?
    private(set) var lastProcessed = ""         // the merged speech the pending draft or question was built from
    /// A spoken list has been heard and Kitty is asking about the parts that were unclear (its name, a missing number…).
    var pendingList: ListOutline.Outline?

    /// "Did you say Rani?": what Kitty is waiting to hear back, and what to do with the answer.
    struct ReadBack {
        var heard: String
        var suggestion: String
        var utterance: String               // the whole turn when the question was asked
        var single: AgentDecisionValue?
        var bulk: BulkDecisionValue?
        var askedWho = false                // they said no: the next words are the name
    }
    var readBack: ReadBack?
    /// One read-back per turn. Separate from the clarification rounds, and cleared when the turn ends.
    var readBackUsed = false

    var pendingTaskLabel: String? { pendingTitles.first.map { String($0.prefix(80)) } }

    func move(to next: ConversationPhase) {
        guard next != phase else { return }
        phase = next
        transitions.append(next)
    }

    func setListening(_ on: Bool) {
        micOn = on
        if on, phase == .idle { move(to: .listening) }
        if !on, phase == .listening { move(to: .idle) }
    }

    /// Stored cleaned, so "um, clean the... no wait, wash the car" and "wash the car" count as the same words.
    func markProcessed(_ utterance: String) { lastProcessed = SpeechCleaner.clean(utterance).text }

    /// The words said since the pending draft or question was built. The whole utterance when there is none.
    func delta(for utterance: String) -> String {
        let whole = SpeechCleaner.clean(utterance).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lastProcessed.isEmpty else { return whole }
        let t = VoiceTurnManager.norm(whole), p = VoiceTurnManager.norm(lastProcessed)
        guard !p.isEmpty, t.hasPrefix(p) else { return whole }
        let rest = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? whole : rest
    }

    func setPending(titles: [String], playbook: String?, planned: [PlannedTask]) {
        pendingTitles = titles
        pendingPlaybook = playbook
        pendingPlanned = planned
    }

    /// The last list Kitty showed: "only personal", "just tomorrow" then narrow it instead of starting over.
    var lastView: TaskLookupSpec?
    /// A "want just today's?" suggestion is made at most once per conversation.
    var hintOffered = false

    func clearPending() {
        pendingTitles = []
        pendingPlaybook = nil
        pendingPlanned = []
        clarification = nil
        pendingProposal = nil
        lastProcessed = ""
        pendingList = nil
        readBack = nil
        readBackUsed = false
        drafts.clear()
        clarify.reset()
        confirmation.disarm()
        move(to: micOn ? .listening : .idle)
    }

    func noteCreated(_ items: [(title: String, id: UUID)], now: Date = Date()) {
        for item in items { recent.append((item.title, now)) }
        if let last = items.last { lastCreatedID = last.id; lastCreatedAt = now }
        recent = recent.filter { now.timeIntervalSince($0.at) < Self.recentWindow }
    }

    func recentTitles(now: Date = Date()) -> [String] {
        recent.filter { now.timeIntervalSince($0.at) < Self.recentWindow }.map(\.title)
    }

    func recentlyCreatedID(now: Date = Date()) -> UUID? {
        guard let id = lastCreatedID, let at = lastCreatedAt, now.timeIntervalSince(at) < 300 else { return nil }
        return id
    }

    func reset() {
        clearPending()
        lastView = nil
        hintOffered = false
        recent = []
        lastCreatedID = nil
        lastCreatedAt = nil
        transitions = []
    }

    /// Keeps the state in step with what the screen is now showing.
    func record(_ result: TurnResult) {
        switch result {
        case .question(let q):
            clarification = q
            pendingProposal = nil
            confirmation.disarm()
            move(to: .awaitingClarification)
        case .proposal(let p):
            clarification = nil
            pendingProposal = p
            confirmation.arm(p.id)
            pendingTitles = p.pendingTitle.map { [$0] } ?? p.rows.prefix(3).map(\.title)
            pendingPlaybook = p.pendingPlaybook
            clarify.reset()
            if drafts.playbook != nil || p.pendingPlaybook != nil { move(to: .pendingPlaybook) }
            else if drafts.items.count > 1 { move(to: .pendingBulkDraft) }
            else if drafts.items.first?.kind == .routine || p.rows.first?.icon == "repeat" { move(to: .pendingRoutine) }
            else { move(to: .pendingTask) }
            if !p.autoConfirm || p.destructive { move(to: .awaitingConfirmation) }
        case .reply:
            clearPending()
        case .wait:
            if phase == .idle { move(to: .listening) }
        }
    }
}

// MARK: The turn manager: when to listen, when to ask the model

/// What happened during one turn: kept for every eval (model input, model output, validation, result).
struct TurnTrace {
    var utterance = ""
    var delta = ""
    var route = ""
    var prompt: String?
    var modelOutput: String?
    var validation: String?
    var result = ""
    var modelCallCount = 0          // how many model calls this turn used (a long turn can use up to 3)
    var chunks = 0                  // how many groups of actions a long turn was split into
}

@MainActor
final class VoiceTurnManager {
    static let longPause: TimeInterval = 1.6        // long enough to check whether the thought is finished
    static let finalizerDelay: TimeInterval = 0.5   // after "done"
    static let quickNudgeAfter: TimeInterval = 3.5  // a lone verb ("clean", "buy"): ask what, don't leave her in silence
    static let nudgeAfter: TimeInterval = 10        // a long silence on unfinished speech: gently ask what the task is
    static let announcedHold: TimeInterval = 6      // "I'd like to create a list of tasks…": the tasks are about to come

    /// How long a pause has to be before Kitty looks at the speech. A longer turn gets a longer grace: someone dictating
    /// several sentences pauses between them, and a sentence that ends is not the end of the thought.
    static func pauseNeeded(for text: String) -> TimeInterval {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let sentences = text.filter { ".?!".contains($0) }.count
        var pause = longPause
        if words >= 12 { pause += 0.3 }
        if words >= 25 { pause += 0.4 }
        if words >= 45 { pause += 0.4 }
        if sentences >= 2 { pause += 0.3 }
        return min(pause, 3.2)
    }

    enum Gate: Equatable {
        case keepListening
        case hold(String)               // the local check says it is unfinished: no model call
        case evaluate(String)           // may be complete: one model call
        case forceEvaluate(String)      // "done" / "save it" / "go ahead": treat it as final
        case nudge
    }

    let state = ConversationStateManager()
    private(set) var modelCalls = 0
    private(set) var lastTrace = TurnTrace()
    private let engine: DecisionProviding
    let sink: SaveSink
    private let knownCategories: () -> [String]
    private let knownAssignees: () -> [String]
    /// What the recogniser reported for the speech being worked on (confidence per word). Empty when typed.
    var heardWords: [SpokenWord] = []
    /// Off in evals: a missing model answer must show up as a failure, never fall back to the real task list.
    var ruleFallbackEnabled = true

    init(engine: DecisionProviding? = nil, sink: SaveSink? = nil, knownCategories: (() -> [String])? = nil,
         knownAssignees: (() -> [String])? = nil) {
        self.engine = engine ?? Self.makeEngine()
        self.sink = sink ?? StoreSaveSink()
        self.knownCategories = knownCategories ?? { TaskStore.shared.knownCategoryNames }
        self.knownAssignees = knownAssignees ?? { VocabularyProvider.people() }
    }

    static func makeEngine() -> DecisionProviding {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) { return DecisionEngine() }
        #endif
        return NoModelEngine()
    }

    nonisolated static func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.split(separator: " ").joined(separator: " ")
    }

    static let finalizers = ["that's all", "thats all", "that is all", "save it", "go ahead", "done"]

    /// "...every Monday for the househelp done" -> ("...every Monday for the househelp", true)
    static func splitFinalizer(_ text: String) -> (text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var lowered = trimmed.lowercased().replacingOccurrences(of: "’", with: "'")
        while let l = lowered.last, ".!?,;: ".contains(l) { lowered.removeLast() }
        for f in finalizers where lowered.hasSuffix(f) {
            let cut = lowered.count - f.count
            if cut > 0, lowered[lowered.index(lowered.startIndex, offsetBy: cut - 1)] != " " { continue }
            if f == "done" {
                // "mark dusting done", "the dishes are done": a command or a statement, not "I'm finished talking".
                let before = lowered.dropLast(f.count).split(separator: " ").last.map(String.init) ?? ""
                if lowered.contains("mark ") || ["is", "are", "was", "as", "be", "get", "all"].contains(before) { continue }
            }
            let kept = String(trimmed.prefix(cut)).trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-"))
            return (kept, true)
        }
        return (trimmed, false)
    }

    /// Decides what to do about the speech so far. The model is never involved here.
    /// The words are cleaned first (fillers, repeats, "no wait" repairs), so everything below judges what was meant.
    /// `lastActed` is compared as raw speech: it is the unedited words Kitty last looked at.
    static func gate(utterance: String, silence: TimeInterval, lastActed: String) -> Gate {
        let said = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return .keepListening }
        if silence >= nudgeAfter { return .nudge }
        if norm(said) == norm(lastActed) { return .keepListening }              // already looked at, nothing new said

        let cleaned = SpeechCleaner.clean(said)
        let raw = cleaned.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return .keepListening }                                // only fillers, or everything was taken back
        if cleaned.pendingRepair { return .hold("waiting for the correction") } // "clean the... no wait" and then nothing yet

        let (text, isFinal) = splitFinalizer(raw)
        if isFinal {
            if text.isEmpty { return .keepListening }
            return silence >= finalizerDelay ? .forceEvaluate(text) : .keepListening
        }
        if silence < pauseNeeded(for: text) { return .keepListening }               // a short pause: keep listening
        switch LocalSemanticPrechecker.check(text) {
        case .incomplete(let reason):
            if silence >= quickNudgeAfter, bareQuestion(for: text) != nil { return .nudge }     // "clean", "clean the", "buy"
            return .hold(reason)
        case .mayBeComplete:
            if LocalSemanticPrechecker.announcesMore(text) {                       // "I'd like a list of tasks…": the tasks come next
                return silence >= announcedHold ? .nudge : .hold("the tasks are still to come")
            }
            return .evaluate(text)
        }
    }

    private func context(now: Date) -> ValidationContext {
        ValidationContext(knownCategories: knownCategories(),
                          knownAssignees: knownAssignees(),
                          pendingTitles: state.pendingTitles + state.drafts.items.map(\.title),
                          recentTitles: state.recentTitles(now: now),
                          now: now, calendar: .current)
    }

    // MARK: A long silence

    /// Never "Are you done?". With a pending draft the question is the one that draft is waiting on. With a dangling
    /// "Add a task to…" it is a real question about the missing task. Anything else is dropped quietly (nil).
    /// The question for an utterance that names an action but nothing to act on: a bare "clean", "Buy", "Add a task to
    /// clean", or an empty playbook or routine. Decided here, not by the model, so it is the same question every time.
    /// "Clean the" -> "Clean". "Buy milk and" -> "Buy milk". Words that only introduce something that never came.
    static func dropTrailingFiller(_ text: String) -> String {
        var words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        func bare(_ w: String) -> String { w.lowercased().filter { $0.isLetter || $0 == "'" } }
        while let last = words.last, LocalSemanticPrechecker.dangling.contains(bare(last)) || LocalSemanticPrechecker.determiners.contains(bare(last)) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    static func bareQuestion(for utterance: String) -> String? {
        let t = LocalSemanticPrechecker.tokens(utterance)
        // "clean the" is "clean": a trailing "the", "to", "my"... says nothing more.
        let rest = LocalSemanticPrechecker.tokens(dropTrailingFiller(BulkDetector.stripFrames(utterance)))
        if t.count <= 3, t.starts(with: ["create", "a", "playbook"]) || t.starts(with: ["add", "a", "playbook"]) { return "What should the playbook be for?" }
        if t.count <= 3, t.starts(with: ["create", "a", "routine"]) || t.starts(with: ["add", "a", "routine"]) { return "What should the routine be?" }
        if rest.count == 1, let verb = rest.first, ActionLexicon.verbs.contains(verb) { return "What should I \(verb)?" }
        return nil
    }

    func nudgeQuestion(for spoken: String) -> String? {
        let utterance = SpeechCleaner.clean(spoken).text
        if let p = state.pendingProposal, let q = p.prompt { return q }
        guard state.clarify.rounds < ClarificationStateManager.maxRounds else { return nil }
        let t = LocalSemanticPrechecker.tokens(utterance)
        var question = Self.bareQuestion(for: utterance)
        if question == nil, LocalSemanticPrechecker.announcesMore(utterance) {
            question = t.contains("project") || t.contains("tasks") || t.contains("task") ? "What's the first task?" : "What's the first one?"
        }
        if question == nil, ["add", "create", "make", "remind", "i"].contains(t.first ?? ""), t.count <= 5 {
            question = ClarificationStateManager.fallbackQuestion(for: .action)
        }
        guard let q = question else { return nil }
        if case .ask(let asked) = state.clarify.register(question: q, field: .action) {
            state.record(.question(asked))
            return asked
        }
        return nil
    }

    // MARK: One turn

    /// One model call at most for one likely-complete turn. The answer is validated before anything can be saved.
    /// `final` means the user has stopped (a long silence, or they typed it): a "wait" is no longer an answer.
    func decide(utterance spoken: String, now: Date = Date(), final: Bool = false) async -> TurnResult {
        let utterance = SpeechCleaner.clean(spoken).text      // idempotent: already-clean text passes through unchanged
        lastTrace = TurnTrace(utterance: utterance)
        var result = await route(utterance: utterance, now: now, final: final)
        if case .reply(let r) = result { result = .reply(offeringHintOnce(r)) }
        if case .reply(let r) = result, let shown = r.spec { state.lastView = shown }
        else if case .wait = result {} else { state.lastView = nil }
            state.record(result)
        switch result {
        case .question, .proposal: state.markProcessed(utterance)
        default: break
        }
        lastTrace.result = Self.describe(result)
            return result
        }

    /// A narrowing suggestion is spoken at most once per conversation. Later ones are dropped.
    func offeringHintOnce(_ reply: AgentReply) -> AgentReply {
        guard let hint = reply.hint else { return reply }
        var r = reply
        if state.hintOffered { r.hint = nil } else { state.hintOffered = true; r.message += " " + hint }
        return r
    }

    static func describe(_ r: TurnResult) -> String {
        switch r {
        case .wait: return "wait"
        case .question(let q): return "question: \(q)"
        case .proposal(let p): return "proposal: \(p.title)\(p.prompt.map { " | " + $0 } ?? "")"
        case .reply(let a): return "reply: \(a.message)"
        }
    }

    private func route(utterance: String, now: Date, final: Bool) async -> TurnResult {
        let delta = state.delta(for: utterance)
        lastTrace.delta = delta
        let ctx = context(now: now)
        let reply = ConfirmationManager.interpret(delta)

        // 0. "Did you say Rani?" is waiting for its answer.
        if let rb = state.readBack {
            switch readBackAnswer(rb, delta: delta, reply: reply) {
            case .apply(let name):
                state.readBack = nil
                lastTrace.route = "read-back-applied"
                return await applyReadBack(rb, name: name, now: now, final: final)
            case .askWho:
                state.readBack?.askedWho = true
                lastTrace.route = "read-back-no"
                return .question("Who did you mean?")
            case .cancel:
                state.readBack = nil
                lastTrace.route = "cancel"
                return .reply(AgentReply(message: "Okay, never mind.", didAdd: false))
            case .newSpeech:
                state.readBack = nil                     // they moved on: this is a new request
            }
        }

        // 0b. "Only tomorrow", "just the maid": narrow the list Kitty just showed instead of starting a new request.
        if let base = state.lastView, state.pendingProposal == nil, !state.drafts.hasContent, state.clarification == nil,
           TaskAgent.isViewRefinement(delta) {
            lastTrace.route = "view-refine"
            return .reply(await TaskAgent.askReply(delta, useModel: false, base: base))
        }

        // 1. Something is waiting for a yes or a no.
        if let p = state.pendingProposal {
            switch reply {
            case .yes:
                lastTrace.route = "confirm-yes"
                var go = p
                go.runImmediately = true                 // execute now, once. The ConfirmationManager lets it through one time.
                return .proposal(go)
            case .cancel:
                lastTrace.route = "cancel"
                return .reply(AgentReply(message: "Okay, I didn't save anything.", didAdd: false))
            case .no:
                lastTrace.route = "confirm-no"
                return .question(ClarificationStateManager.fallbackQuestion(for: .change))     // "No" means: what should change?
            case .other:
                break
            }
        } else if state.phase == .awaitingClarification, reply == .cancel {
            lastTrace.route = "cancel"
            return .reply(AgentReply(message: "Okay, never mind.", didAdd: false))
        } else if !state.drafts.hasContent, state.pendingList == nil, reply == .yes || reply == .no {
            lastTrace.route = "nothing-pending"          // a stray "yes": nothing to confirm, and nothing to ask
            return .reply(AgentReply(message: "All set.", didAdd: false))
        }

        // 2. A pending draft is being corrected item by item.
        if state.drafts.hasContent, let edit = DraftEditParser.parse(delta, hasPlaybook: state.drafts.playbook != nil) {
            lastTrace.route = "edit"
            return applyEdit(edit, ctx: ctx)
        }

        // 2b. A spoken list ("a list of tasks for the Kitty project, number one…, number two…"): read in Swift, never guessed.
        if state.pendingProposal == nil, !state.drafts.hasContent, let list = listTurn(utterance: utterance, delta: delta, ctx: ctx) {
            return list
        }

        // 3. The model decides what it means.
        let answering = state.phase == .awaitingClarification && !state.drafts.hasContent && state.clarify.lastQuestion != nil
        if answering { state.clarify.recordAnswer(delta) }
        // An action with nothing to act on ("clean", "Add a task to clean") is a question, whatever the model would say.
        if !answering, state.phase != .awaitingClarification, state.pendingProposal == nil, !state.drafts.hasContent,
           state.clarify.rounds < ClarificationStateManager.maxRounds, let q = Self.bareQuestion(for: utterance),
           case .ask(let asked) = state.clarify.register(question: q, field: .action) {
            lastTrace.route = "bare-action"
            return .question(asked)
        }
        let analysis = BulkDetector.analyze(answering ? delta : utterance, words: answering ? [] : heardWords, now: now)

        var lines: [String] = []
        let sentenceCount = utterance.filter { ".?!".contains($0) }.count
        if sentenceCount >= 2 {
            lines.append("This is one thought spoken over several sentences. Use all of it: what an earlier sentence says (the project, the person, the place, the day) applies to the sentences after it. Never ask for something already said.")
        }
        if answering, let q = state.clarify.lastQuestion {
            lines.append("You asked: “\(q)” They answered: “\(delta)”.")
        } else if state.pendingProposal != nil || state.drafts.hasContent, delta != utterance.trimmingCharacters(in: .whitespacesAndNewlines) {
            lines.append("New words: “\(delta)”.")
        }
        if state.drafts.hasContent { lines.append("Pending: \(state.drafts.labels).") }
        if analysis.kind == .playbook {
            lines.append("This is a playbook request.")
        } else if analysis.isBulk {
            lines.append("These look like \(analysis.segments.count) separate items: " + analysis.segments.joined(separator: " | ") + ".")
        }
        // A long turn: the model reads a digest of the action clauses (a few at a time), never the whole ramble.
        let longTurn: LongTurn? = answering ? nil : analysis.turn.flatMap { $0.actions.isEmpty ? nil : $0 }
        if analysis.isBulk, let turn = longTurn {
            return await longBulkTurn(turn, analysis: analysis, lines: lines, utterance: utterance, ctx: ctx, now: now)
        }
        let prompt = PromptBuilder.build(utterance: utterance, pendingTask: state.pendingTaskLabel, pendingPlaybook: state.pendingPlaybook,
                                         knownCategories: knownCategories(), now: now, context: lines.joined(separator: "\n"),
                                         digest: longTurn.map { LongTurnAnalyzer.digest(context: $0.context, actions: $0.actions) })
        lastTrace.prompt = prompt
        modelCalls += 1
        lastTrace.modelCallCount = 1

        if analysis.isBulk, let bulk = await engine.decideBulk(prompt: prompt) {
            lastTrace.route = "model-bulk"
            lastTrace.modelOutput = "\(bulk)"
            if let q = readBackQuestion(bulk: bulk, utterance: utterance) { lastTrace.route = "read-back"; return q }
            let validated = BulkValidator.validate(bulk, utterance: utterance, segments: analysis.segments, context: ctx)
            lastTrace.validation = "\(validated)"
            Breadcrumb.log("decision: bulk \(bulk.action)")
            return await bulkResult(validated, spoken: bulk.spokenResponse, utterance: utterance, ctx: ctx)
        }
        if var decision = await engine.decide(prompt: prompt) {
            lastTrace.route = "model-single"
            lastTrace.modelOutput = "\(decision)"
            Breadcrumb.log("decision: \(decision.action) wait=\(decision.wait)")
            var validated = TaskValidator.validate(decision, utterance: utterance, context: ctx)
            if case .wait = validated, !final, Self.modelMeantToCreate(decision, utterance: utterance) {
                // The on-device model sometimes sets wait=true on a plain, finished "Buy bread" while still choosing create_task
                // with an empty title (seen in real-model runs, and it varies run to run). The local gate already judged the
                // sentence finished, so ask once more; if it still waits, the rule-based path answers.
                modelCalls += 1
                if let again = await engine.decide(prompt: prompt) {
                    decision = again
                    lastTrace.route = "model-single-retry"
                    lastTrace.modelOutput = "\(again)"
                    validated = TaskValidator.validate(again, utterance: utterance, context: ctx)
                }
                if case .wait = validated, ruleFallbackEnabled {
                    lastTrace.route = "wait-overridden-create"
                    return await TaskAgent.propose(utterance)
                }
            }
            if case .wait = validated {} else if let q = readBackQuestion(single: decision, utterance: utterance) {
                lastTrace.route = "read-back"
                return q
            }
            lastTrace.validation = "\(validated)"
            if case .wait = validated, final {
                // The user has stopped and the model still says "wait": the rule-based path answers instead of silence.
                lastTrace.route = "wait-overridden"
                return await TaskAgent.propose(utterance)
            }
            return await singleResult(validated, decision: decision, utterance: utterance, ctx: ctx)
        }

        // No Apple Intelligence (or the call failed): the rule-based path, still behind the local gate.
        lastTrace.route = "no-model"
        guard ruleFallbackEnabled else {
            return .reply(AgentReply(message: "I couldn't reach the on-device model.", didAdd: false))
        }
        return await TaskAgent.propose(utterance)
    }

    /// Up to three model calls of at most four actions each, merged into one draft. What the model leaves out (or what does not
    /// fit in three calls) is added back from the action clauses by `BulkValidator`, so nothing the user asked for is lost.
    private func longBulkTurn(_ turn: LongTurn, analysis: BulkDetector.Analysis, lines: [String], utterance: String,
                              ctx: ValidationContext, now: Date) async -> TurnResult {
        let (groups, _) = LongTurnAnalyzer.chunks(turn.actions)
        lastTrace.chunks = groups.count
        var merged = BulkDecisionValue(action: "create_tasks")
        var answered = 0
        var outputs: [String] = []
        for (i, group) in groups.enumerated() {
            var chunkLines = lines.filter { !$0.hasPrefix("These look like") }
            chunkLines.append("These look like \(group.count) separate items: " + group.map(\.text).joined(separator: " | ") + ".")
            let prompt = PromptBuilder.build(utterance: "", pendingTask: state.pendingTaskLabel, pendingPlaybook: state.pendingPlaybook,
                                             knownCategories: knownCategories(), now: now, context: chunkLines.joined(separator: "\n"),
                                             digest: LongTurnAnalyzer.digest(context: turn.context, actions: group))
            if i == 0 { lastTrace.prompt = prompt }
            modelCalls += 1
            lastTrace.modelCallCount += 1
            guard let b = await engine.decideBulk(prompt: prompt) else { continue }
            outputs.append("\(b)")
            switch b.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
            case "create_tasks", "create_routines", "create_task", "create_routine":
                merged.tasks += b.tasks
                merged.routines += b.routines
                if merged.spokenResponse.isEmpty { merged.spokenResponse = b.spokenResponse }
                answered += 1
            default:
                break                                           // wait / clarify on a chunk: its actions come back from the clauses
            }
        }
        lastTrace.modelOutput = outputs.joined(separator: "\n")
        guard !outputs.isEmpty else {
            lastTrace.route = "no-model"
            guard ruleFallbackEnabled else { return .reply(AgentReply(message: "I couldn't reach the on-device model.", didAdd: false)) }
            return bulkFromClauses(turn, analysis: analysis, utterance: utterance, ctx: ctx)
        }
        lastTrace.route = "model-bulk-long"
        if let q = readBackQuestion(bulk: merged, utterance: utterance) { lastTrace.route = "read-back"; return q }
        let validated = BulkValidator.validate(merged, utterance: utterance, segments: analysis.segments, context: ctx)
        lastTrace.validation = "\(validated)"
        Breadcrumb.log("decision: long bulk, \(groups.count) chunk(s), \(answered) answered")
        return await bulkResult(validated, spoken: merged.spokenResponse, utterance: utterance, ctx: ctx)
    }

    /// No model at all: every action clause becomes a draft through the local rules.
    private func bulkFromClauses(_ turn: LongTurn, analysis: BulkDetector.Analysis, utterance: String, ctx: ValidationContext) -> TurnResult {
        let empty = BulkDecisionValue(action: "create_tasks")
        let validated = BulkValidator.validate(empty, utterance: utterance, segments: analysis.segments, context: ctx)
        lastTrace.validation = "\(validated)"
        if case .items(let items) = validated { return startDraft(items, ctx: ctx) }
        return .reply(AgentReply(message: "I couldn't work out the tasks. What would you like me to add?", didAdd: false))
    }

    /// A wait that comes with a create action on a sentence the local gate judged finished: the model meant to create it.
    static func modelMeantToCreate(_ d: AgentDecisionValue, utterance: String) -> Bool {
        guard d.wait, LocalSemanticPrechecker.check(utterance) == .mayBeComplete else { return false }
        switch d.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "create_task", "create_routine": return true
        default: return false
        }
    }

    // MARK: Read-back: "Did you say Rani?"

    private enum ReadBackAnswer { case apply(String), askWho, cancel, newSpeech }

    private func readBackAnswer(_ rb: ConversationStateManager.ReadBack, delta: String, reply: ConfirmationManager.Reply) -> ReadBackAnswer {
        if rb.askedWho {
            let name = ReadBackCheck.name(in: delta)
            return name.isEmpty ? .newSpeech : .apply(name)
        }
        switch reply {
        case .yes: return .apply(rb.suggestion)
        case .no: return .askWho
        case .cancel: return .cancel
        case .other:
            // Just the name, said again: "Rani".
            let words = LocalSemanticPrechecker.tokens(delta)
            if (1...2).contains(words.count), !ActionLexicon.verbs.contains(words[0]) { return .apply(ReadBackCheck.name(in: delta)) }
            return .newSpeech
        }
    }

    /// One question per turn, and only for names, numbers and dates.
    private func readBackVerdict(assignees: [String], utterance: String) -> ReadBackCheck.Verdict {
        guard !state.readBackUsed else { return .none }
        for a in assignees {
            let v = ReadBackCheck.assignee(a, utterance: utterance, known: knownAssignees(), words: heardWords)
            if v != .none { return v }
        }
        return ReadBackCheck.fact(utterance: utterance, words: heardWords)
    }

    private func readBackQuestion(single d: AgentDecisionValue, utterance: String) -> TurnResult? {
        guard case .ask(let heard, let suggestion) = readBackVerdict(assignees: [d.assignee], utterance: utterance) else { return nil }
        state.readBackUsed = true
        state.readBack = .init(heard: heard, suggestion: suggestion, utterance: utterance, single: d, bulk: nil)
        return .question("Did you say \(suggestion)?")
    }

    private func readBackQuestion(bulk b: BulkDecisionValue, utterance: String) -> TurnResult? {
        let people = b.tasks.map(\.assignee) + b.routines.map(\.assignee) + [b.playbook?.assignee ?? ""]
        guard case .ask(let heard, let suggestion) = readBackVerdict(assignees: people, utterance: utterance) else { return nil }
        state.readBackUsed = true
        state.readBack = .init(heard: heard, suggestion: suggestion, utterance: utterance, single: nil, bulk: b)
        return .question("Did you say \(suggestion)?")
    }

    /// Carries on with the model's answer from before the question, with the confirmed name in place of what was heard.
    private func applyReadBack(_ rb: ConversationStateManager.ReadBack, name: String, now: Date, final: Bool) async -> TurnResult {
        let utterance = ReadBackCheck.replacing(rb.heard, with: name, in: rb.utterance)
        let ctx = context(now: now)
        func fix(_ value: String) -> String { value.lowercased() == rb.heard.lowercased() ? name : value }
        if var d = rb.single {
            d.assignee = fix(d.assignee)
            let validated = TaskValidator.validate(d, utterance: utterance, context: ctx)
            lastTrace.validation = "\(validated)"
            if case .wait = validated, final { return await TaskAgent.propose(utterance) }
            return await singleResult(validated, decision: d, utterance: utterance, ctx: ctx)
        }
        if var b = rb.bulk {
            b.tasks = b.tasks.map { var t = $0; t.assignee = fix(t.assignee); return t }
            b.routines = b.routines.map { var r = $0; r.assignee = fix(r.assignee); return r }
            if var p = b.playbook { p.assignee = fix(p.assignee); b.playbook = p }
            let segments = BulkDetector.analyze(utterance, now: now).segments
            let validated = BulkValidator.validate(b, utterance: utterance, segments: segments, context: ctx)
            lastTrace.validation = "\(validated)"
            return await bulkResult(validated, spoken: b.spokenResponse, utterance: utterance, ctx: ctx)
        }
        return .reply(AgentReply(message: "Okay.", didAdd: false))
    }

    // MARK: Results from the model

    private func singleResult(_ validated: Validated, decision d: AgentDecisionValue, utterance: String,
                              ctx: ValidationContext) async -> TurnResult {
        let spoken = d.spokenResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        switch validated {
        case .clarify(let q):
            // A question about something optional is never needed: save what is clear instead.
            let enrichment = ClarificationStateManager.asksForDetail(q) && Self.isActionableTitle(d.title.isEmpty ? BulkDetector.stripFrames(utterance) : d.title)
            if ClarificationStateManager.asksForOptionalMetadata(q) || enrichment {
                var copy = d
                copy.action = "create_task"
                if copy.title.isEmpty { copy.title = TaskPlanner.tidyTitle(BulkDetector.stripFrames(utterance), removingDay: true) }
                let retry = TaskValidator.validate(copy, utterance: utterance, context: ctx)
                if case .clarify = retry {} else { return await singleResult(retry, decision: copy, utterance: utterance, ctx: ctx) }
            }
            return clarification(q, action: d.action, utterance: utterance, ctx: ctx)

        case .tasks(let tasks) where tasks.count > 1:
            return startDraft(tasks.map { DraftItem($0, kind: .task) }, ctx: ctx)

        case .playbook(let name, let steps, let stated):
            let pb = PlaybookDraftState(name: name,
                                        due: TaskValidator.resolveDate(d.dueDate, utterance: utterance, ctx: ctx),
                                        assignee: TaskValidator.resolveAssignee(d.assignee, utterance: utterance, known: ctx.knownAssignees),
                                        steps: steps.map { DraftItem(title: $0) }, stated: stated)
            state.setPending(titles: [], playbook: nil, planned: [])
            state.drafts.setPlaybook(pb)
            return draftProposal(ack: nil)

        case .update(let target, let changes) where state.drafts.hasContent && state.drafts.playbook == nil:
            return applyEdit(.changeFields(target: target, changes: changes), ctx: ctx)

        default:
            return await DecisionExecutor.turnResult(validated, decision: d, utterance: utterance, state: state, sink: sink)
        }
    }

    private func bulkResult(_ validated: BulkValidated, spoken: String, utterance: String, ctx: ValidationContext) async -> TurnResult {
        switch validated {
        case .wait:
            return .wait
        case .clarify(let q):
            return clarification(q, action: "bulk", utterance: utterance, ctx: ctx)
        case .unrelated(let reply):
            return .reply(AgentReply(message: reply.isEmpty ? "I can help with your tasks. What would you like to do?" : reply, didAdd: false))
        case .duplicate(let title):
            return .reply(AgentReply(message: "“\(title)” is already on your list.", didAdd: false))
        case .playbook(let pb):
            state.setPending(titles: [], playbook: nil, planned: [])
            state.drafts.setPlaybook(pb)
            return draftProposal(ack: nil)
        case .items(let items):
            if state.drafts.hasContent, state.drafts.playbook == nil {        // new items during confirmation join the pending draft
                let added = state.drafts.merge(items)
                return draftProposal(ack: added.isEmpty ? nil : "Added \(Words.list(added.map { $0.title.lowercased() })).")
            }
            if items.count == 1 {                                              // one item: same as a single task or routine
                return DecisionExecutor.addProposal([items[0].planned()], utterance: utterance, spoken: spoken, state: state, sink: sink)
            }
            return startDraft(items, ctx: ctx)
        }
    }

    /// Several items: a pending bulk draft that waits for an explicit yes.
    private func startDraft(_ items: [DraftItem], ctx: ValidationContext) -> TurnResult {
        state.setPending(titles: [], playbook: nil, planned: [])
        if state.drafts.hasContent, state.drafts.playbook == nil {
            let added = state.drafts.merge(items)
            return draftProposal(ack: added.isEmpty ? nil : "Added \(Words.list(added.map { $0.title.lowercased() })).")
        }
        state.drafts.setItems(items)
        return draftProposal(ack: nil)
    }

    private func draftProposal(ack: String?, question: String? = nil) -> TurnResult {
        if let pb = state.drafts.playbook { return .proposal(DraftProposals.playbook(pb, ack: ack, sink: sink)) }
        return .proposal(DraftProposals.bulk(state.drafts.items, question: question, ack: ack, sink: sink))
    }

    private func applyEdit(_ edit: DraftEdit, ctx: ValidationContext) -> TurnResult {
        switch state.drafts.apply(edit, context: ctx) {
        case .applied(let ack):
            return draftProposal(ack: ack)
        case .question(let q):
            return .question(q)
        case .emptied:
            state.drafts.clear()
            return .reply(AgentReply(message: "Okay, there's nothing left to save.", didAdd: false))
        }
    }

    // MARK: Asking: one required slot at a time

    /// A title that says what to do to what ("Write a strategy document"): nothing more is needed to save it.
    static func isActionableTitle(_ title: String) -> Bool {
        let t = LocalSemanticPrechecker.tokens(title)
        guard t.count >= 2 else { return false }
        return t.contains { ActionLexicon.verbs.contains($0) } || t.count >= 3
    }

    /// A spoken list becomes tasks: each numbered part is one task, the intro is not a task, and anything unclear is asked
    /// about, one specific question at a time, instead of being guessed.
    private func listTurn(utterance: String, delta: String, ctx: ValidationContext) -> TurnResult? {
        var outline: ListOutline.Outline
        if var waiting = state.pendingList {
            ListOutline.apply(answer: delta, to: &waiting)
            outline = waiting
        } else if let parsed = ListOutline.parse(utterance, knownPeople: knownAssignees()) {
            outline = parsed
        } else {
            return nil
        }
        while let q = outline.questions.first {
            switch state.clarify.register(question: q.text, field: ClarificationStateManager.field(for: q.text, action: "create_task")) {
            case .ask(let asked):
                state.pendingList = outline
                lastTrace.route = "list-question"
                return .question(asked)
            case .exhausted:
                ListOutline.finalize(&outline)                      // out of rounds: the most careful reading, then go on
            }
        }
        state.pendingList = nil
        outline.items.removeAll { $0.title.isEmpty }
        guard !outline.items.isEmpty else {
            return .question("Sorry, I couldn't make out the tasks. What would you like me to add?")
        }
        lastTrace.route = "list"
        let list = outline.name.map { TaskStore.cleanProfileName($0) }.flatMap { $0.isEmpty ? nil : $0 }
        let planned = outline.items.map { item -> PlannedTask in
            let due = TaskPlanner.ruleDue(item.title)
            let title = TaskPlanner.tidyTitle(item.title, removingDay: due != nil)
            let who = outline.assignee ?? Assignee.detect(in: item.title)
            var p = PlannedTask(title: title.isEmpty ? item.title : title, category: .guess(from: item.title), due: due, profile: list)
            p.notes = item.notes
            p.assignee = who
            return p
        }
        return TaskAgent.buildAddProposal(planned, usedAI: false, text: utterance, sink: sink)
    }

    private func clarification(_ question: String, action: String, utterance: String, ctx: ValidationContext) -> TurnResult {
        let q = ClarificationStateManager.oneQuestion(question)
        let field = ClarificationStateManager.field(for: q, action: action)
        switch state.clarify.register(question: q, field: field) {
        case .ask(let asked):
            return .question(asked)
        case .exhausted:
            return bestInterpretation(of: utterance, ctx: ctx)
        }
    }

    /// Three rounds are used: stop asking, propose the most likely reading, and let the user confirm or change it.
    private func bestInterpretation(of utterance: String, ctx: ValidationContext) -> TurnResult {
        if let item = BulkDraftManager.makeItem(from: BulkDetector.stripFrames(utterance), context: ctx) {
            state.setPending(titles: [], playbook: nil, planned: [])
            state.drafts.setItems([item])
            return .proposal(DraftProposals.bulk([item], question: "Should I save it this way, or would you like to change something?", sink: sink))
        }
        state.drafts.clear()
        state.clarify.reset()
        return .question("Sorry, I couldn't work that out. What would you like me to add?")
    }
}

// MARK: From a validated decision to something on screen

@MainActor
enum DecisionExecutor {
    static func turnResult(_ validated: Validated, decision: AgentDecisionValue, utterance: String,
                           state: ConversationStateManager, sink: SaveSink? = nil) async -> TurnResult {
        let spoken = decision.spokenResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        let sink = sink ?? StoreSaveSink()

        switch validated {
        case .wait:
            return .wait

        case .clarify(let question):
            return .question(question)

        case .duplicate(let title):
            return .reply(AgentReply(message: "“\(title)” is already on your list.", didAdd: false))

        case .unrelated(let reply):
            return .reply(AgentReply(message: reply.isEmpty ? "I can help with your tasks. What would you like to do?" : reply, didAdd: false))

        case .view:
            return .reply(await TaskAgent.askReply(utterance, useModel: false))

        case .complete(let target):
            return await TaskAgent.proposeChange(.complete, "mark \(target) as done", useModel: false)

        case .delete(let target):
            return await TaskAgent.proposeChange(.delete, "delete \(target)", useModel: false)

        case .tasks(let tasks):
            return addProposal(tasks.map { $0.planned() }, utterance: utterance, spoken: spoken, state: state, sink: sink)

        case .routine(let task):
            return addProposal([task.planned()], utterance: utterance, spoken: spoken, state: state, sink: sink)

        case .playbook:
            return .question("What should the playbook be for?")          // playbooks are drafted by VoiceTurnManager

        case .update(let target, let changes):
            return await updateResult(target: target, changes: changes, utterance: utterance, state: state, sink: sink)
        }
    }

    /// The model's reply is used when it is short and is not a question. Otherwise Swift words the confirmation.
    private static func usable(_ spoken: String) -> Bool {
        !spoken.isEmpty && !spoken.contains("?") && spoken.split(separator: " ").count <= 14
    }

    /// The preview for new tasks and routines. The model's one-line reply is used once they are saved.
    static func addProposal(_ planned: [PlannedTask], utterance: String, spoken: String,
                            state: ConversationStateManager, sink: SaveSink) -> TurnResult {
        let built = TaskAgent.buildAddProposal(planned, usedAI: true, text: utterance, sink: sink)
        guard case .proposal(var proposal) = built else { return built }
        let inner = proposal.apply
        proposal.apply = {
            var reply = await inner()
            if usable(spoken), !reply.created.isEmpty { reply.message = spoken }
            return reply
        }
        proposal.pendingTitle = planned.first?.title
        state.setPending(titles: planned.map(\.title), playbook: nil, planned: planned)
        return .proposal(proposal)
    }

    /// "Actually make it high priority": changes the item waiting to be saved, or the last one just saved, or a named task.
    private static func updateResult(target: String, changes: ValidatedTask, utterance: String,
                                     state: ConversationStateManager, sink: SaveSink) async -> TurnResult {
        let store = TaskStore.shared
        let targetKey = TaskValidator.key(target)
        let namesPending = !targetKey.isEmpty && state.pendingTitles.contains { TaskValidator.key($0) == targetKey }

        if (target.isEmpty || namesPending), !state.pendingPlanned.isEmpty {
            var planned = state.pendingPlanned
            for i in planned.indices {
                if let p = changes.priority { planned[i].priority = p }
                if let a = changes.assignee { planned[i].assignee = a }
                if let d = changes.due, planned[i].recurrence == nil { planned[i].due = d }
                if let m = changes.timeMinutes { planned[i].timeMinutes = m }
                if let n = changes.notes { planned[i].notes = n }
                if let c = changes.categoryName { planned[i].categoryName = c }
            }
            let rebuilt = TaskAgent.buildAddProposal(planned, usedAI: true, text: utterance, sink: sink)
            guard case .proposal(var proposal) = rebuilt else { return rebuilt }
            proposal.pendingTitle = planned.first?.title
            state.setPending(titles: planned.map(\.title), playbook: nil, planned: planned)
            return .proposal(proposal)
        }

        var targetID: UUID?
        if target.isEmpty {
            targetID = state.recentlyCreatedID()
            if targetID == nil { return .question("Which task should I change?") }
        } else {
            var cmd = TaskCommand()
            cmd.target = target
            switch TaskMatcher.resolve(target, cmd: cmd, status: .open, pickAll: false).first {
            case .found(let items)?: targetID = items[0].id
            case .ambiguous(_, let items)?:
                return .question("Which one: " + items.prefix(4).map(\.title).joined(separator: ", or ") + "?")
            default:
                return .question("I couldn't find a task called \(target). Which one do you mean?")
            }
        }
        guard let id = targetID, let task = store.tasks.first(where: { $0.id == id }) else {
            return .question("Which task should I change?")
        }

        var tags: [PreviewTag] = []
        if let p = changes.priority { tags.append(PreviewTag(text: p.capitalized + " priority", icon: "flag.fill", color: p == "high" ? .red : .orange)) }
        if let a = changes.assignee { tags.append(PreviewTag(text: a, icon: "person.fill", color: .person(a))) }
        if let d = changes.due { tags.append(PreviewTag(text: d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), icon: "calendar")) }
        if let m = changes.timeMinutes { tags.append(PreviewTag(text: DaySlot.clockLabel(m), icon: "clock", color: .indigo)) }
        if let c = changes.categoryName { tags.append(PreviewTag(text: c, icon: "tag.fill")) }
        let title = task.title
        return .proposal(Proposal(
            title: "Update “\(title)”",
            rows: [PreviewRow(icon: "pencil", title: title, tags: tags)],
            confirmLabel: "Update",
            apply: {
                store.applyChanges(id, with: changes)
                return AgentReply(message: "Updated \(title).", didAdd: false, didChange: true)
            }))
    }
}
