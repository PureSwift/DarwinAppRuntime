import CoreGraphics
import DynamicCalendar
import DynamicRuntime
import EventKit
import Foundation
import RuntimeCalendar
import Testing
@testable import DarwinCalendar

/// Between EventKit's values and the guest's. Nothing here reads the
/// user's calendars, or asks them for them.
@Suite("Calendar values")
struct CalendarValueTests {

    let dublin = TimeZone(identifier: "Europe/Dublin")!

    let auckland = TimeZone(identifier: "Pacific/Auckland")!

    let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    /// 5 March 2025, 00:00 UTC.
    let fifth = CivilDate(year: 2025, month: 3, day: 5).millisecondsSince1970

    @Test func readsTheUsersLeave() {
        #expect(CalendarValues.access(0) == .notDetermined)
        #expect(CalendarValues.access(1) == .restricted)
        #expect(CalendarValues.access(2) == .denied)
        #expect(CalendarValues.access(3) == .full)
        #expect(CalendarValues.access(4) == .writeOnly)
        #expect(CalendarValues.access(EKAuthorizationStatus.notDetermined.rawValue) == .notDetermined)
        #expect(CalendarValues.declaredAccess([:]) == .full)
        #expect(CalendarValues.declaredAccess(["RTCapabilityOptions": ["calendars": ["access": "full"]]]) == .full)
        #expect(CalendarValues.declaredAccess(["RTCapabilityOptions": ["calendars": ["access": "writeOnly"]]]) == .writeOnly)
    }

    @Test func readsACalendarsColour() {
        #expect(CalendarValues.argb([1, 0, 0, 1]) == 0xFFFF_0000)
        #expect(CalendarValues.argb([0, 0.5, 1]) == 0xFF00_80FF)
        #expect(CalendarValues.argb([0, 0, 0, 0.5]) == 0x8000_0000)
        #expect(CalendarValues.argb([]) == 0xFF00_7AFF)
        #expect(CalendarValues.argb(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)) == 0xFF00_FF00)
        #expect(CalendarValues.argb(nil) == 0xFF00_7AFF)
    }

    @Test func keepsADayADayInEveryZone() {
        for zone in [dublin, auckland, losAngeles] {
            let midnight = CalendarValues.midnight(of: fifth, in: zone)
            #expect(CalendarValues.day(of: midnight, in: zone) == fifth)
            // As the Calendar app writes a day: its midnight to 23:59:59.
            let one = CalendarValues.allDayDates(start: fifth, end: fifth + 86_400_000, in: zone)
            #expect(one.start == midnight)
            #expect(one.end == midnight.addingTimeInterval(86_399))
            #expect(CalendarValues.allDay(start: one.start, end: one.end, in: zone) == (fifth, fifth + 86_400_000))
            // Three days, ending at the next midnight instead.
            let next = CalendarValues.midnight(of: fifth + 3 * 86_400_000, in: zone)
            #expect(CalendarValues.allDay(start: midnight, end: next, in: zone) == (fifth, fifth + 3 * 86_400_000))
            // A day with no length is still a day.
            #expect(CalendarValues.allDay(start: midnight, end: midnight, in: zone) == (fifth, fifth + 86_400_000))
        }
    }

    @Test func readsAnEvent() throws {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = "Lunch"
        event.location = "Canteen"
        event.timeZone = dublin
        event.startDate = Date(timeIntervalSince1970: 1_741_176_000)
        event.endDate = Date(timeIntervalSince1970: 1_741_179_600)
        event.alarms = [EKAlarm(relativeOffset: -900), EKAlarm(absoluteDate: Date(timeIntervalSince1970: 1_741_172_400))]
        let value = try #require(CalendarValues.event(event))
        #expect(value.title == "Lunch")
        #expect(value.location == "Canteen")
        #expect(value.notes == "")
        #expect(value.start == 1_741_176_000_000)
        #expect(value.end == 1_741_179_600_000)
        #expect(!value.isAllDay)
        #expect(value.timeZone == "Europe/Dublin")
        #expect(value.recurrence == nil)
        #expect(value.occurrence == nil)
        // EventKit keeps alarms in an order of its own.
        #expect(value.alarms.map(\.minutesBefore).sorted() == [15, 60])
        // Outside a calendar, an event has no availability to hold.
        #expect(value.availability == .notSupported)

        // All day: EventKit keeps it to the device's days, as the store
        // writes them.
        event.isAllDay = true
        event.timeZone = nil
        let days = CalendarValues.allDayDates(start: fifth, end: fifth + 2 * 86_400_000, in: .current)
        event.startDate = days.start
        event.endDate = days.end
        let allDay = try #require(CalendarValues.event(event))
        #expect(allDay.isAllDay)
        #expect(allDay.start == fifth)
        #expect(allDay.end == fifth + 2 * 86_400_000)
        #expect(allDay.timeZone == nil)
    }

    @Test func turnsAlarmsIntoMinutesBefore() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let alarms = [
            EKAlarm(relativeOffset: 0),
            EKAlarm(relativeOffset: -3600),
            EKAlarm(relativeOffset: 600),
            EKAlarm(absoluteDate: start.addingTimeInterval(-1800)),
        ]
        #expect(CalendarValues.alarms(alarms, start: start) == [.atStart, .before(minutes: 60), .atStart, .before(minutes: 30)])
        let written = CalendarValues.ekAlarms([.before(minutes: 15), .atStart])
        #expect(written.map(\.relativeOffset) == [-900, 0])
        #expect(CalendarValues.availability(.busy) == .busy)
        #expect(CalendarValues.availability(.notSupported) == .notSupported)
    }

    @Test func carriesRulesBothWays() throws {
        let rules = [
            RecurrenceRule(.daily),
            RecurrenceRule(.weekly, interval: 2, daysOfWeek: [.monday, .wednesday]),
            RecurrenceRule(.weekly, daysOfWeek: [.tuesday], end: .count(10)),
            RecurrenceRule(.monthly, daysOfMonth: [1, 15], end: .until(1_767_225_600_000)),
            RecurrenceRule(.monthly, daysOfWeek: [.friday], setPositions: [-1]),
            RecurrenceRule(.monthly, daysOfWeek: [.nth(2, .tuesday)]),
            RecurrenceRule(.yearly, monthsOfYear: [3], end: .count(5)),
            try #require(RecurrenceRule(rrule: "FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO")),
            try #require(RecurrenceRule(rrule: "FREQ=YEARLY;BYYEARDAY=1,100")),
        ]
        for rule in rules {
            let ek = try CalendarValues.ekRule(rule)
            #expect(CalendarValues.rule(ek) == rule, "\(rule.rrule)")
        }
        // The week's start is the rule's own default, and goes unsaid.
        let mondays = try #require(RecurrenceRule(rrule: "FREQ=WEEKLY;BYDAY=MO;WKST=MO"))
        #expect(CalendarValues.rule(try CalendarValues.ekRule(mondays))?.rrule == "FREQ=WEEKLY;BYDAY=MO")
    }

    @Test func refusesARuleEventKitCantHold() throws {
        func refused(_ rule: RecurrenceRule) -> Bool {
            do {
                _ = try CalendarValues.ekRule(rule)
                return false
            } catch {
                return error == .unsupportedRecurrence
            }
        }
        #expect(refused(RecurrenceRule(.hourly)))
        #expect(refused(RecurrenceRule(.daily, daysOfWeek: [.monday])))
        #expect(refused(RecurrenceRule(.weekly, daysOfMonth: [1])))
        #expect(refused(RecurrenceRule(.monthly, monthsOfYear: [3])))
        #expect(refused(RecurrenceRule(.weekly, daysOfWeek: [.nth(2, .tuesday)])))
        #expect(refused(try #require(RecurrenceRule(rrule: "FREQ=DAILY;BYHOUR=9"))))
        #expect(refused(try #require(RecurrenceRule(rrule: "FREQ=WEEKLY;WKST=SU"))))
        #expect(refused(try #require(RecurrenceRule(rrule: "FREQ=MONTHLY;BYWEEKNO=2"))))
        #expect(!refused(RecurrenceRule(.monthly, daysOfMonth: [-1])))
    }

    @Test func saysWhyEventKitRefused() {
        func error(_ code: EKError.Code) -> EventStoreError {
            CalendarValues.error(NSError(domain: EKErrorDomain, code: code.rawValue))
        }
        #expect(error(.calendarReadOnly) == .readOnly)
        #expect(error(.eventNotMutable) == .readOnly)
        #expect(error(.datesInverted) == .invalidDates)
        #expect(error(.noCalendar) == .notFound)
        #expect(error(.invalidSpan) == .invalidSpan)
        #expect(error(.eventStoreNotAuthorized) == .notAuthorized)
        #expect(error(.internalFailure) == .unknown)
        #expect(CalendarValues.error(NSError(domain: NSCocoaErrorDomain, code: 1)) == .unknown)
    }
}

/// The module as the host registers it. It changes `HostCalendars`'
/// settings, so it runs alone.
@Suite("Calendar module", .serialized)
struct CalendarModuleTests {

    @Test func listsTheContracts() {
        #expect(DarwinCalendar.contracts.map(\.name).contains("org.pureswift.calendar.Calendars"))
        #expect(Set(DarwinCalendar.permissionProviders().keys) == [.calendars])
    }

    @Test func hasNoCalendarsWithoutAStore() {
        HostCalendars.reset()
        defer { HostCalendars.reset() }
        let permission = DarwinCalendar.permissionProviders()[.calendars]
        #expect(permission?.status() == .unavailable)
        var answered: PermissionStatus?
        permission?.request { answered = $0 }
        #expect(answered == .unavailable)
    }

    @Test func reportsWriteOnlyAsLimited() {
        HostCalendars.reset()
        defer { HostCalendars.reset() }
        HostCalendars.store = MemoryCalendarStore()
        HostCalendars.access = .full
        HostCalendars.declaredAccess = .writeOnly
        #expect(DarwinCalendar.permissionProviders()[.calendars]?.status() == .limited)
        HostCalendars.declaredAccess = .full
        #expect(DarwinCalendar.permissionProviders()[.calendars]?.status() == .granted)
    }
}
