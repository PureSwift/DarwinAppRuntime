import DynamicCalendar
import EventKit
import Foundation
import RuntimeCalendar

/// The user's calendars through EventKit: the `CalendarStore` behind
/// `HostCalendars`.
///
/// `HostCalendars` calls it off the main thread, one call at a time, once
/// it has checked access, dates and spans. Occurrences are EventKit's
/// own expansion. A save changes only what the guest's value changed,
/// so what EventKit holds that an `Event` doesn't carry (attendees,
/// attachments, an alarm at a fixed time) stays as it was.
final class SystemCalendarStore: CalendarStore, @unchecked Sendable {

    let store: EKEventStore

    private let lock = NSLock()

    /// Set when the user's leave changed: a store made before it was
    /// given reads nothing until it's reset.
    private var needsReset = false

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    func accessChanged() {
        lock.lock()
        needsReset = true
        lock.unlock()
    }

    /// The store, reset first if it must be.
    private var events: EKEventStore {
        lock.lock()
        let reset = needsReset
        needsReset = false
        lock.unlock()
        if reset {
            store.reset()
        }
        return store
    }

    // MARK: Reading

    func calendars() throws(EventStoreError) -> [EventCalendar] {
        events.calendars(for: .event).map(CalendarValues.calendar)
    }

    func defaultCalendar() throws(EventStoreError) -> EventCalendar? {
        events.defaultCalendarForNewEvents.map(CalendarValues.calendar)
    }

    func events(from start: Int64, to end: Int64, in calendars: [String]) throws(EventStoreError) -> [Event] {
        let store = events
        var named: [EKCalendar]?
        if !calendars.isEmpty {
            named = calendars.compactMap { store.calendar(withIdentifier: $0) }
            if named?.isEmpty == true { return [] }
        }
        // A day wider each side: an all-day event's days are UTC's in the
        // contract and the device's in EventKit.
        let predicate = store.predicateForEvents(
            withStart: CalendarValues.date(start - 86_400_000), end: CalendarValues.date(end + 86_400_000), calendars: named
        )
        return store.events(matching: predicate)
            .compactMap { CalendarValues.event($0) }
            .filter { $0.overlaps(start, end) }
    }

    func event(withID identifier: String) throws(EventStoreError) -> Event? {
        events.event(withIdentifier: identifier).flatMap { CalendarValues.event($0) }
    }

    /// The event an identifier and an occurrence name: for one that
    /// repeats, the occurrence whose original start is `occurrence`.
    private func find(_ identifier: String, occurrence: Int64?, in store: EKEventStore) -> EKEvent? {
        guard let first = store.event(withIdentifier: identifier) else { return nil }
        guard first.hasRecurrenceRules, let occurrence, CalendarValues.event(first)?.occurrence != occurrence else {
            return first
        }
        // Near its original start, and then, for one that was moved far,
        // a year each way.
        for days: Int64 in [2, 366] {
            let predicate = store.predicateForEvents(
                withStart: CalendarValues.date(occurrence - days * 86_400_000),
                end: CalendarValues.date(occurrence + days * 86_400_000),
                calendars: first.calendar.map { [$0] }
            )
            let match = store.events(matching: predicate).first {
                $0.eventIdentifier == identifier && CalendarValues.event($0)?.occurrence == occurrence
            }
            if let match {
                return match
            }
        }
        return nil
    }

    // MARK: Writing

    func save(_ event: Event, span: EventSpan) throws(EventStoreError) -> Event {
        let store = events
        let target: EKEvent
        let existing: Event?
        if let identifier = event.id {
            guard let found = find(identifier, occurrence: event.occurrence, in: store) else {
                throw .notFound
            }
            target = found
            existing = CalendarValues.event(found)
        } else {
            target = EKEvent(eventStore: store)
            existing = nil
        }
        do {
            try apply(event, to: target, existing: existing, span: span, in: store)
            try store.save(target, span: Self.span(span), commit: true)
        } catch {
            // Nothing half made is left for the next call.
            store.reset()
            throw (error as? EventStoreError) ?? CalendarValues.error(error)
        }
        guard let saved = CalendarValues.event(target) else {
            throw .unknown
        }
        return saved
    }

    func remove(_ event: Event, span: EventSpan) throws(EventStoreError) {
        let store = events
        guard let identifier = event.id, let target = find(identifier, occurrence: event.occurrence, in: store) else {
            throw .notFound
        }
        do {
            try store.remove(target, span: Self.span(span), commit: true)
        } catch {
            store.reset()
            throw CalendarValues.error(error)
        }
    }

    private static func span(_ span: EventSpan) -> EKSpan {
        span == .futureEvents ? .futureEvents : .thisEvent
    }

    /// Writes the guest's value into EventKit's event: all of it for a new
    /// one, and for one the store has, what changed.
    private func apply(_ event: Event, to target: EKEvent, existing: Event?, span: EventSpan, in store: EKEventStore) throws {
        func changed<Value: Equatable>(_ value: (Event) -> Value) -> Bool {
            existing.map { value($0) != value(event) } ?? true
        }
        // One occurrence stays in its series' calendar.
        let isOneOccurrence = existing?.recurrence != nil && span == .thisEvent
        if changed(\.calendar), !isOneOccurrence {
            guard let identifier = event.calendar, let calendar = store.calendar(withIdentifier: identifier) else {
                throw EventStoreError.notFound
            }
            target.calendar = calendar
        }
        if changed(\.title) { target.title = event.title }
        if changed(\.location) { target.location = event.location.isEmpty ? nil : event.location }
        if changed(\.notes) { target.notes = event.notes.isEmpty ? nil : event.notes }
        if changed(\.url) { target.url = event.url.isEmpty ? nil : URL(string: event.url) }
        if changed(\.start) || changed(\.end) || changed(\.isAllDay) || changed(\.timeZone) {
            if event.isAllDay {
                let dates = CalendarValues.allDayDates(start: event.start, end: event.end, in: .current)
                target.isAllDay = true
                target.timeZone = nil
                target.startDate = dates.start
                target.endDate = dates.end
            } else {
                target.isAllDay = false
                // No zone in the contract is the device's: EventKit's `nil`
                // would float the event to whatever zone it's read in.
                target.timeZone = event.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
                target.startDate = CalendarValues.date(event.start)
                target.endDate = CalendarValues.date(event.end)
            }
        }
        if changed(\.recurrence) {
            if let rule = event.recurrence {
                target.recurrenceRules = [try CalendarValues.ekRule(rule)]
            } else {
                target.recurrenceRules = nil
            }
        }
        if changed(\.alarms) {
            target.alarms = event.alarms.isEmpty ? nil : CalendarValues.ekAlarms(event.alarms)
        }
        if changed(\.availability), event.availability != .notSupported {
            target.availability = CalendarValues.availability(event.availability)
        }
    }
}
