import Foundation
import Combine
import UserNotifications

// MARK: - Reminders: a task with a day (and maybe a time) reminds you

/// Local reminders for saved tasks, on the phone. A task reminds you only if it has a day, and the day only exists when the words said
/// one (see `EvidenceGate`). With a time it reminds at that time; with only a day, at 9 in the morning of that day. Done tasks, tasks
/// in the past, and the daily copies of a routine do not remind. The list follows the tasks: add, change, finish or delete a task
/// and its reminder follows a moment later.
///
/// The system asks for permission the first time there is something to remind about, not before. If it is refused, nothing is
/// scheduled and nothing else changes.
@MainActor
final class Reminders {
    static let shared = Reminders()

    /// A task with a day and no time reminds at this hour.
    static let defaultHour = 9
    /// iOS keeps at most 64 pending notifications: the soonest ones are kept.
    static let maxPending = 60
    private static let prefix = "kitty.task."

    private var cancellable: AnyCancellable?
    private var asked = false

    func start(with store: TaskStore) {
        guard cancellable == nil else { return }
        cancellable = store.$tasks
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] tasks in Task { await self?.apply(tasks) } }
    }

    /// When this task should remind, or nil if it should not.
    static func fireDate(for task: TaskItem, calendar: Calendar = .current, now: Date = .now) -> Date? {
        guard !task.isDone, task.routineID == nil, let day = task.dueDate else { return nil }
        let minutes = task.timeMinutes ?? defaultHour * 60
        guard let fire = calendar.date(byAdding: .minute, value: minutes, to: calendar.startOfDay(for: day)), fire > now else { return nil }
        return fire
    }

    private func apply(_ tasks: [TaskItem]) async {
        let center = UNUserNotificationCenter.current()
        let wanted = tasks.compactMap { t in Self.fireDate(for: t).map { (task: t, date: $0) } }
            .sorted { $0.date < $1.date }
            .prefix(Self.maxPending)
        let wantedIDs = Set(wanted.map { Self.prefix + $0.task.id.uuidString })

        // Reminders of tasks that are gone, done or moved away.
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        let stale = pending.filter { !wantedIDs.contains($0) }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        guard !wanted.isEmpty else { return }

        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined, !asked {
            asked = true
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }

        let calendar = Calendar.current
        for item in wanted {
            let content = UNMutableNotificationContent()
            content.title = item.task.title
            content.body = item.task.timeMinutes != nil ? "It's time." : "Due today."
            content.sound = .default
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: item.date)
            let request = UNNotificationRequest(identifier: Self.prefix + item.task.id.uuidString, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            try? await center.add(request)        // the same identifier replaces the earlier reminder
        }
    }
}
