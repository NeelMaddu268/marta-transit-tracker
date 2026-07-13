import Foundation
import UserNotifications
import Combine

/// "Time to leave" departure reminders: a local notification a few minutes
/// before a specific predicted departure. Reminders are keyed by the serving
/// trip+stop (stable across polls), so while the app is running they re-aim
/// themselves when the live prediction drifts.
@MainActor
final class ReminderService: ObservableObject {
    /// Stable reminder keys with a pending notification (drives bell state).
    @Published private(set) var scheduled: Set<String> = []

    /// Minutes of warning before the departure.
    static let leadMinutes = 5

    private let center = UNUserNotificationCenter.current()

    init() {
        Task { await reloadPending() }
    }

    /// Identity that survives prediction changes: the physical bus at the stop.
    nonisolated static func stableKey(_ arrival: Arrival) -> String {
        "rem:\(arrival.tripId ?? arrival.route)|\(arrival.stopId)"
    }

    func isScheduled(_ arrival: Arrival) -> Bool {
        scheduled.contains(Self.stableKey(arrival))
    }

    /// Toggle a reminder for a departure. Returns false when notification
    /// permission was denied.
    @discardableResult
    func toggle(for arrival: Arrival, title: String, bay: String?) async -> Bool {
        let key = Self.stableKey(arrival)
        if scheduled.contains(key) {
            center.removePendingNotificationRequests(withIdentifiers: [key])
            scheduled.remove(key)
            return true
        }
        guard let time = arrival.predictedTime else { return false }

        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Time to leave · Route \(arrival.route)"
        var body = title
        if let bay { body += " · Wait at \(bay)" }
        content.body = body
        content.sound = .default

        let fireIn = max(5, time.timeIntervalSinceNow - Double(Self.leadMinutes * 60))
        let request = UNNotificationRequest(
            identifier: key, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: fireIn, repeats: false))
        do {
            try await center.add(request)
            scheduled.insert(key)
            return true
        } catch {
            return false
        }
    }

    /// Re-aim pending reminders at the latest predictions: if a tracked
    /// departure drifted by more than a minute, reschedule its notification
    /// (same content, corrected fire time). Called after each feed refresh.
    func reconcile(departures: [Arrival]) async {
        guard !scheduled.isEmpty else { return }
        let byKey = Dictionary(departures.map { (Self.stableKey($0), $0) },
                               uniquingKeysWith: { first, _ in first })
        let pending = await center.pendingNotificationRequests()
        for request in pending {
            guard let arrival = byKey[request.identifier],
                  let predicted = arrival.predictedTime,
                  let trigger = request.trigger as? UNTimeIntervalNotificationTrigger,
                  let currentFire = trigger.nextTriggerDate() else { continue }
            let desiredFire = predicted.addingTimeInterval(-Double(Self.leadMinutes * 60))
            guard abs(desiredFire.timeIntervalSince(currentFire)) > 60 else { continue }
            let fireIn = max(5, desiredFire.timeIntervalSinceNow)
            let updated = UNNotificationRequest(
                identifier: request.identifier, content: request.content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: fireIn, repeats: false))
            try? await center.add(updated)   // same id replaces the pending one
        }
    }

    /// Re-sync bell state with what's actually pending (past reminders fall off).
    func reloadPending() async {
        let pending = await center.pendingNotificationRequests()
        scheduled = Set(pending.map { $0.identifier })
    }
}
