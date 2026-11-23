import CoreGraphics
import DynamicCalendar
import EventKit
import Foundation

/// Between EventKit's values and the guest's.
enum CalendarValues {

    // MARK: Access

    /// EventKit's status, by raw value: iOS 17 renamed `authorized` to
    /// `fullAccess` (3) and added `writeOnly` (4), newer than the
    /// deployment target.
    static func access(_ status: Int) -> EventStoreAccess {
        switch status {
        case 0: return .notDetermined
        case 1: return .restricted
        case 2: return .denied
        case 3: return .full
        case 4: return .writeOnly
        default: return .denied
        }
    }

    /// The manifest's `.calendars(.writeOnly, …)`:
    /// `RTCapabilityOptions.calendars.access`. Full is the default.
    static func declaredAccess(_ info: [String: Any]) -> EventStoreAccess {
        let options = info["RTCapabilityOptions"] as? [String: Any]
        let access = (options?["calendars"] as? [String: Any])?["access"] as? String
        return access == "writeOnly" ? .writeOnly : .full
    }

    // MARK: Calendars

    /// `0xAARRGGBB`, from a colour's sRGB components; opaque blue
    /// without one.
    static func argb(_ components: [CGFloat]) -> UInt32 {
        guard components.count >= 3 else { return 0xFF00_7AFF }
        func byte(_ value: CGFloat) -> UInt32 {
            UInt32((min(max(value, 0), 1) * 255).rounded())
        }
        let alpha = components.count >= 4 ? byte(components[3]) : 255
        return alpha << 24 | byte(components[0]) << 16 | byte(components[1]) << 8 | byte(components[2])
    }

    static func argb(_ color: CGColor?) -> UInt32 {
        guard let color, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components else {
            return argb([])
        }
        return argb(components)
    }

    static func calendar(_ calendar: EKCalendar) -> EventCalendar {
        // A calendar only on the device has no account to name.
        let source = calendar.source
        let account = source == nil || source?.sourceType == .local ? "" : source?.title ?? ""
        return EventCalendar(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            account: account,
            color: argb(calendar.cgColor),
            isWritable: calendar.allowsContentModifications
        )
    }

    // MARK: Days

    private static func gregorian(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// The contract's moment for the day `date` is on in `zone`: 00:00 UTC.
    static func day(of date: Date, in zone: TimeZone) -> Int64 {
        let parts = gregorian(zone).dateComponents([.year, .month, .day], from: date)
        return CivilDate(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1).millisecondsSince1970
    }

    /// Midnight in `zone` of the day the contract's moment names.
    static func midnight(of day: Int64, in zone: TimeZone) -> Date {
        let civil = CivilDate(millisecondsSince1970: day)
        let parts = DateComponents(year: civil.year, month: civil.month, day: civil.day)
        return gregorian(zone).date(from: parts) ?? Date(timeIntervalSince1970: TimeInterval(day) / 1000)
    }

    /// An all-day event's days, from EventKit's dates: its end is the
    /// last day's 23:59:59, or else the next day's midnight.
    static func allDay(start: Date, end: Date, in zone: TimeZone) -> (start: Int64, end: Int64) {
        let first = day(of: start, in: zone)
        var last = end
        let calendar = gregorian(zone)
        if end > start, calendar.startOfDay(for: end) == end {
            last = end.addingTimeInterval(-1)
        }
        let lastDay = max(day(of: last, in: zone), first)
        return (first, lastDay + 86_400_000)
    }

    /// EventKit's dates for an all-day event's days, as the Calendar app
    /// writes them: the first day's midnight to the last day's 23:59:59.
    static func allDayDates(start: Int64, end: Int64, in zone: TimeZone) -> (start: Date, end: Date) {
        let first = midnight(of: start, in: zone)
        let last = midnight(of: max(end - 86_400_000, start), in: zone)
        return (first, last.addingTimeInterval(86_399))
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    // MARK: Events

    /// The guest's value of an EventKit event. `nil` for one with no
    /// dates, which EventKit can hold half made.
    static func event(_ event: EKEvent, zone: TimeZone = .current) -> Event? {
        guard let startDate = event.startDate, let endDate = event.endDate else { return nil }
        let start: Int64, end: Int64
        if event.isAllDay {
            (start, end) = allDay(start: startDate, end: endDate, in: event.timeZone ?? zone)
        } else {
            start = milliseconds(startDate)
            end = max(milliseconds(endDate), start)
        }
        var value = Event(title: event.title ?? "", start: start, end: end, isAllDay: event.isAllDay)
        value.id = event.eventIdentifier
        value.calendar = event.calendar?.calendarIdentifier
        value.location = event.location ?? ""
        value.notes = event.notes ?? ""
        value.url = event.url?.absoluteString ?? ""
        value.timeZone = event.isAllDay ? nil : event.timeZone?.identifier
        value.recurrence = event.recurrenceRules?.first.flatMap(rule)
        if event.hasRecurrenceRules || event.isDetached, let original = event.occurrenceDate {
            value.occurrence = event.isAllDay ? day(of: original, in: event.timeZone ?? zone) : milliseconds(original)
        }
        value.isDetached = event.isDetached
        value.alarms = alarms(event.alarms ?? [], start: startDate)
        value.availability = EventAvailability(rawValue: Int32(event.availability.rawValue)) ?? .notSupported
        return value
    }

    // MARK: Alarms

    /// Minutes before the start: an alarm at a fixed time is said as one
    /// relative to it, and one after the start is at it.
    static func alarms(_ alarms: [EKAlarm], start: Date) -> [EventAlarm] {
        alarms.map { alarm in
            let before = alarm.absoluteDate.map { start.timeIntervalSince($0) } ?? -alarm.relativeOffset
            return EventAlarm(minutesBefore: Int((before / 60).rounded()))
        }
    }

    static func ekAlarms(_ alarms: [EventAlarm]) -> [EKAlarm] {
        alarms.map { EKAlarm(relativeOffset: -TimeInterval($0.minutesBefore) * 60) }
    }

    static func availability(_ availability: EventAvailability) -> EKEventAvailability {
        EKEventAvailability(rawValue: Int(availability.rawValue)) ?? .notSupported
    }

    // MARK: Rules

    /// The guest's rule for EventKit's.
    static func rule(_ rule: EKRecurrenceRule) -> RecurrenceRule? {
        let frequency: RecurrenceRule.Frequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: return nil
        }
        let days = (rule.daysOfTheWeek ?? []).compactMap { day -> RecurrenceRule.DayOfWeek? in
            RecurrenceRule.Weekday(rawValue: day.dayOfTheWeek.rawValue).map { RecurrenceRule.DayOfWeek($0, week: day.weekNumber) }
        }
        var end = RecurrenceRule.End.never
        if let recurrenceEnd = rule.recurrenceEnd {
            if let date = recurrenceEnd.endDate {
                // To the second, as a rule's text says it.
                end = .until(Int64(date.timeIntervalSince1970.rounded(.down)) * 1000)
            } else if recurrenceEnd.occurrenceCount > 0 {
                end = .count(recurrenceEnd.occurrenceCount)
            }
        }
        var value = RecurrenceRule(
            frequency, interval: rule.interval, daysOfWeek: days,
            daysOfMonth: ints(rule.daysOfTheMonth), monthsOfYear: ints(rule.monthsOfTheYear),
            setPositions: ints(rule.setPositions), end: end
        )
        // What the rule has no property for is kept as its parts.
        var extra: [String] = []
        if !ints(rule.weeksOfTheYear).isEmpty {
            extra.append("BYWEEKNO=" + ints(rule.weeksOfTheYear).map(String.init).joined(separator: ","))
        }
        if !ints(rule.daysOfTheYear).isEmpty {
            extra.append("BYYEARDAY=" + ints(rule.daysOfTheYear).map(String.init).joined(separator: ","))
        }
        if !extra.isEmpty, let withExtra = RecurrenceRule(rrule: ([value.rrule] + extra).joined(separator: ";")) {
            value = withExtra
        }
        return value
    }

    /// EventKit's rule for the guest's, or `unsupportedRecurrence` for one
    /// EventKit can't hold as it is.
    static func ekRule(_ rule: RecurrenceRule) throws(EventStoreError) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        case .hourly, .minutely, .secondly: throw .unsupportedRecurrence
        }
        var weeksOfYear: [Int] = [], daysOfYear: [Int] = []
        for part in rule.otherParts {
            if part.hasPrefix("BYWEEKNO="), let values = Self.ints(part.dropFirst(9)) {
                weeksOfYear = values
            } else if part.hasPrefix("BYYEARDAY="), let values = Self.ints(part.dropFirst(10)) {
                daysOfYear = values
            } else if part == "WKST=MO" {
                // EventKit's week starts where the user's does; Monday is
                // the rule's own default.
                continue
            } else {
                throw .unsupportedRecurrence
            }
        }
        // EventKit ignores the parts that don't go with the frequency:
        // refused, rather than saved as another rule.
        let yearly = frequency == .yearly
        guard rule.daysOfMonth.isEmpty || frequency == .monthly,
              rule.monthsOfYear.isEmpty || yearly,
              weeksOfYear.isEmpty || yearly,
              daysOfYear.isEmpty || yearly,
              rule.daysOfWeek.isEmpty || frequency != .daily,
              rule.daysOfWeek.allSatisfy({ $0.week == 0 }) || frequency == .monthly || yearly else {
            throw .unsupportedRecurrence
        }
        let days = rule.daysOfWeek.compactMap { day -> EKRecurrenceDayOfWeek? in
            guard let weekday = EKWeekday(rawValue: day.weekday.rawValue) else { return nil }
            return day.week == 0 ? EKRecurrenceDayOfWeek(weekday) : EKRecurrenceDayOfWeek(weekday, weekNumber: day.week)
        }
        let end: EKRecurrenceEnd?
        switch rule.end {
        case .never: end = nil
        case .count(let count): end = EKRecurrenceEnd(occurrenceCount: max(count, 1))
        case .until(let until): end = EKRecurrenceEnd(end: date(until))
        }
        func numbers(_ values: [Int]) -> [NSNumber]? {
            values.isEmpty ? nil : values.map { NSNumber(value: $0) }
        }
        return EKRecurrenceRule(
            recurrenceWith: frequency, interval: rule.interval, daysOfTheWeek: days.isEmpty ? nil : days,
            daysOfTheMonth: numbers(rule.daysOfMonth), monthsOfTheYear: numbers(rule.monthsOfYear),
            weeksOfTheYear: numbers(weeksOfYear), daysOfTheYear: numbers(daysOfYear),
            setPositions: numbers(rule.setPositions), end: end
        )
    }

    private static func ints(_ numbers: [NSNumber]?) -> [Int] {
        (numbers ?? []).map(\.intValue)
    }

    private static func ints(_ text: Substring) -> [Int]? {
        let values = text.split(separator: ",").map { Int($0) }
        guard !values.isEmpty, !values.contains(nil) else { return nil }
        return values.compactMap { $0 }
    }

    // MARK: Errors

    /// What the guest is told of EventKit's refusal.
    static func error(_ error: any Error) -> EventStoreError {
        let error = error as NSError
        guard error.domain == EKErrorDomain else { return .unknown }
        switch EKError.Code(rawValue: error.code) {
        case .eventNotMutable?, .calendarReadOnly?, .calendarIsImmutable?, .calendarDoesNotAllowEvents?,
             .sourceDoesNotAllowEvents?, .invitesCannotBeMoved?:
            return .readOnly
        case .noStartDate?, .noEndDate?, .datesInverted?, .durationGreaterThanRecurrence?,
             .startDateTooFarInFuture?, .startDateCollidesWithOtherOccurrence?:
            return .invalidDates
        case .noCalendar?, .calendarHasNoSource?:
            return .notFound
        case .invalidSpan?:
            return .invalidSpan
        case .eventStoreNotAuthorized?:
            return .notAuthorized
        default:
            return .unknown
        }
    }
}
