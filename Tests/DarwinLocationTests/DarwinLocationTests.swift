import CoreLocation
import DarwinHost
@testable import DarwinLocation
import DynamicLocation
import DynamicRuntime
import Foundation
import Testing

// MARK: - Fakes

/// Records what the implementation sends to the guest.
final class FakeLocationDelegate: LocationManagerDelegate {

    enum Event: Equatable {
        case authorization(status: Int32, accuracy: Int32)
        case locations([Double])
        case heading(Double)
        case failure(Int32)
    }

    var events: [Event] = []

    /// Everything but authorization reports, which CoreLocation also sends
    /// on its own when a manager is made.
    var nonAuthorization: [Event] {
        events.filter {
            if case .authorization = $0 { return false }
            return true
        }
    }

    var locations: [any Location] = []

    func didChangeAuthorization(_ manager: any LocationManager, status: Int32, accuracy: Int32) {
        events.append(.authorization(status: status, accuracy: accuracy))
    }

    func didUpdateLocations(_ manager: any LocationManager, locations: [any Location]) {
        self.locations = locations
        events.append(.locations(locations.map { $0.latitude() }))
    }

    func didUpdateHeading(_ manager: any LocationManager, heading: any Heading) {
        events.append(.heading(heading.magneticHeading()))
    }

    func didFail(_ manager: any LocationManager, error: Int32) {
        events.append(.failure(error))
    }
}

/// Records registrations.
final class RecordingRegistrar: ContractRegistrar {

    var registered: [(descriptor: ContractDescriptor, hasStatics: Bool)] = []

    func register(_ descriptor: ContractDescriptor, statics: StaticMethodTable?) {
        // Inspecting an optional typed-throws function needs macOS 15's
        // runtime; the package's minimum is lower.
        if #available(macOS 15, iOS 18, *) {
            registered.append((descriptor, statics != nil))
        } else {
            registered.append((descriptor, descriptor.kind == .contract))
        }
    }
}

/// A `CLHeading` with fixed values; CoreLocation has no public initializer
/// that sets them.
final class FixedHeading: CLHeading {

    override var magneticHeading: CLLocationDirection { 90 }

    override var trueHeading: CLLocationDirection { -1 }

    override var headingAccuracy: CLLocationDirection { 5 }

    override var timestamp: Date { Date(timeIntervalSince1970: 1_700_000_000.25) }
}

/// Lets main-queue work scheduled before this call run.
func nextMainTurn() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

func fix(latitude: Double, verticalAccuracy: Double = 3, timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000.5)) -> CLLocation {
    CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -122.25),
        altitude: 12,
        horizontalAccuracy: 5,
        verticalAccuracy: verticalAccuracy,
        course: 270,
        courseAccuracy: 10,
        speed: 1.5,
        speedAccuracy: 0.5,
        timestamp: timestamp
    )
}

// MARK: - Mapping

@Suite struct LocationMappingTests {

    @Test func authorization() {
        #expect(LocationMapping.authorization(.notDetermined) == .notDetermined)
        #expect(LocationMapping.authorization(.restricted) == .restricted)
        #expect(LocationMapping.authorization(.denied) == .denied)
        #expect(LocationMapping.authorization(.authorizedAlways) == .authorizedAlways)
    }

    @Test func accuracyAuthorization() {
        #expect(LocationMapping.accuracyAuthorization(.fullAccuracy) == .full)
        #expect(LocationMapping.accuracyAuthorization(.reducedAccuracy) == .reduced)
    }

    @Test func permission() {
        #expect(LocationMapping.permission(.notDetermined, accuracy: .fullAccuracy) == .notDetermined)
        #expect(LocationMapping.permission(.restricted, accuracy: .fullAccuracy) == .restricted)
        #expect(LocationMapping.permission(.denied, accuracy: .fullAccuracy) == .denied)
        #expect(LocationMapping.permission(.authorizedAlways, accuracy: .fullAccuracy) == .granted)
        #expect(LocationMapping.permission(.authorizedAlways, accuracy: .reducedAccuracy) == .limited, "approximate only")
    }

    @Test func desiredAccuracy() {
        #expect(LocationMapping.desiredAccuracy(LocationAccuracy.best.rawValue) == kCLLocationAccuracyBest)
        #expect(LocationMapping.desiredAccuracy(LocationAccuracy.nearestTenMeters.rawValue) == kCLLocationAccuracyNearestTenMeters)
        #expect(LocationMapping.desiredAccuracy(LocationAccuracy.hundredMeters.rawValue) == kCLLocationAccuracyHundredMeters)
        #expect(LocationMapping.desiredAccuracy(LocationAccuracy.kilometer.rawValue) == kCLLocationAccuracyKilometer)
        #expect(LocationMapping.desiredAccuracy(LocationAccuracy.reduced.rawValue) == kCLLocationAccuracyReduced)
        #expect(LocationMapping.desiredAccuracy(99) == nil)
    }

    @Test func distanceFilter() {
        #expect(LocationMapping.distanceFilter(0) == kCLDistanceFilterNone)
        #expect(LocationMapping.distanceFilter(-5) == kCLDistanceFilterNone)
        #expect(LocationMapping.distanceFilter(25) == 25)
    }

    @Test func errors() {
        func clError(_ code: CLError.Code) -> NSError {
            NSError(domain: kCLErrorDomain, code: code.rawValue)
        }
        #expect(LocationMapping.error(clError(.locationUnknown), servicesEnabled: true) == .locationUnknown)
        #expect(LocationMapping.error(clError(.denied), servicesEnabled: true) == .denied)
        #expect(LocationMapping.error(clError(.denied), servicesEnabled: false) == .servicesDisabled)
        #expect(LocationMapping.error(clError(.network), servicesEnabled: true) == .network)
        #expect(LocationMapping.error(clError(.headingFailure), servicesEnabled: true) == .headingFailure)
        #expect(LocationMapping.error(clError(.geocodeFoundNoResult), servicesEnabled: true) == .unknown)
        #expect(LocationMapping.error(NSError(domain: NSURLErrorDomain, code: 1), servicesEnabled: true) == .unknown)
    }

    @Test func milliseconds() {
        #expect(LocationMapping.milliseconds(Date(timeIntervalSince1970: 0)) == 0)
        #expect(LocationMapping.milliseconds(Date(timeIntervalSince1970: 1_700_000_000.5)) == 1_700_000_000_500)
        #expect(LocationMapping.milliseconds(Date(timeIntervalSince1970: -1.5)) == -1_500)
    }
}

// MARK: - Values

@Suite struct LocationValueTests {

    @Test func location() {
        let location = DarwinLocationFix(fix(latitude: 37.5))
        #expect(location.latitude() == 37.5)
        #expect(location.longitude() == -122.25)
        #expect(location.altitude() == 12)
        #expect(location.horizontalAccuracy() == 5)
        #expect(location.verticalAccuracy() == 3)
        #expect(location.speed() == 1.5)
        #expect(location.speedAccuracy() == 0.5)
        #expect(location.course() == 270)
        #expect(location.courseAccuracy() == 10)
        #expect(location.timestamp() == 1_700_000_000_500)
        // CoreLocation gives even a constructed fix source information.
        #expect(location.isSimulated() == (location.location.sourceInformation == nil ? -1 : 0))
    }

    @Test func invalidAltitudeIsNaN() {
        let location = DarwinLocationFix(fix(latitude: 1, verticalAccuracy: -1))
        #expect(location.altitude().isNaN)
        #expect(location.verticalAccuracy() < 0)
    }

    @Test func unavailableValuesStayNegative() {
        let location = DarwinLocationFix(CLLocation(latitude: 1, longitude: 2))
        #expect(location.speed() < 0)
        #expect(location.course() < 0)
        #expect(location.speedAccuracy() < 0)
        #expect(location.courseAccuracy() < 0)
    }

    @Test func simulated() {
        func located(simulated: Bool) -> DarwinLocationFix {
            DarwinLocationFix(CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2),
                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                course: -1, courseAccuracy: -1, speed: -1, speedAccuracy: -1,
                timestamp: Date(),
                sourceInfo: CLLocationSourceInformation(softwareSimulationState: simulated, andExternalAccessoryState: false)
            ))
        }
        #expect(located(simulated: true).isSimulated() == 1)
        #expect(located(simulated: false).isSimulated() == 0)
    }

    @Test func heading() {
        let heading = DarwinHeading(FixedHeading())
        #expect(heading.magneticHeading() == 90)
        #expect(heading.trueHeading() == -1, "negative until a location is known")
        #expect(heading.headingAccuracy() == 5)
        #expect(heading.timestamp() == 1_700_000_000_250)
    }
}

// MARK: - Manager

/// A manager with fixed authorization. A real one reports reduced accuracy
/// until CoreLocation finishes starting, then full accuracy, on its own
/// schedule.
final class FixedAuthorizationManager: CLLocationManager {

    var status = CLAuthorizationStatus.notDetermined

    /// `requestAlwaysAuthorization()` calls, which never reach CoreLocation.
    var alwaysRequests = 0

    override var authorizationStatus: CLAuthorizationStatus { status }

    override var accuracyAuthorization: CLAccuracyAuthorization { .fullAccuracy }

    override func requestAlwaysAuthorization() {
        alwaysRequests += 1
    }
}

/// The `CLLocationManagerDelegate` path into a fake guest delegate. On the
/// main actor: CoreLocation managers belong to the thread that made them.
@Suite @MainActor struct DarwinLocationManagerTests {

    let delegate = FakeLocationDelegate()

    let manager: DarwinLocationManager

    init() {
        manager = DarwinLocationManager(delegate: delegate, manager: FixedAuthorizationManager())
    }

    @Test func isTheFrameworkDelegate() {
        #expect(manager.manager.delegate === manager)
    }

    @Test func locationsArriveInOrder() throws {
        manager.locationManager(manager.manager, didUpdateLocations: [fix(latitude: 1), fix(latitude: 2)])
        #expect(delegate.nonAuthorization == [.locations([1, 2])])
        let last = try #require(delegate.locations.last as? DarwinLocationFix)
        #expect(last.location.coordinate.latitude == 2)
    }

    @Test func noLocationsSendsNothing() {
        manager.locationManager(manager.manager, didUpdateLocations: [])
        #expect(delegate.nonAuthorization.isEmpty)
    }

    @Test func errorsMapToContractCodes() {
        let codes: [(CLError.Code, LocationError)] = [
            (.locationUnknown, .locationUnknown),
            (.network, .network),
            (.headingFailure, .headingFailure),
            (.regionMonitoringFailure, .unknown),
        ]
        for (code, _) in codes {
            manager.locationManager(manager.manager, didFailWithError: NSError(domain: kCLErrorDomain, code: code.rawValue))
        }
        manager.locationManager(manager.manager, didFailWithError: NSError(domain: NSPOSIXErrorDomain, code: 1))
        #expect(delegate.nonAuthorization == codes.map { .failure($0.1.rawValue) } + [.failure(LocationError.unknown.rawValue)])
    }

    @Test func denialDependsOnLocationServices() {
        manager.locationManager(manager.manager, didFailWithError: NSError(domain: kCLErrorDomain, code: CLError.Code.denied.rawValue))
        let expected: LocationError = CLLocationManager.locationServicesEnabled() ? .denied : .servicesDisabled
        #expect(delegate.nonAuthorization == [.failure(expected.rawValue)])
    }

    @Test func authorizationIsReportedOncePerChange() {
        manager.locationManagerDidChangeAuthorization(manager.manager)
        manager.locationManagerDidChangeAuthorization(manager.manager)
        let current = FakeLocationDelegate.Event.authorization(
            status: LocationAuthorization.notDetermined.rawValue,
            accuracy: LocationAccuracyAuthorization.full.rawValue
        )
        #expect(delegate.events == [current], "a repeated value isn't sent again")
        manager.reportAuthorization(force: true)
        #expect(delegate.events == [current, current], "a request that can't prompt answers anyway")
    }

    @Test func makeReportsAuthorizationOnce() async {
        let delegate = FakeLocationDelegate()
        let manager = DarwinLocationManager.make(delegate)
        #expect(delegate.events.isEmpty, "not inside make")
        await nextMainTurn()
        // A real manager's accuracy can change while CoreLocation starts, so
        // later reports depend on its timing; duplicates are checked with a
        // fixed manager in `authorizationIsReportedOncePerChange`.
        guard case .authorization = delegate.events.first else {
            Issue.record("expected an authorization event, got \(delegate.events)")
            return
        }
        withExtendedLifetime(manager) { }
    }

    @Test func settings() {
        manager.setDesiredAccuracy(LocationAccuracy.kilometer.rawValue)
        #expect(manager.manager.desiredAccuracy == kCLLocationAccuracyKilometer)
        manager.setDesiredAccuracy(42)
        #expect(manager.manager.desiredAccuracy == kCLLocationAccuracyKilometer, "unknown tiers are ignored")
        manager.setDistanceFilter(50)
        #expect(manager.manager.distanceFilter == 50)
        manager.setDistanceFilter(0)
        #expect(manager.manager.distanceFilter == kCLDistanceFilterNone)
    }

    #if os(macOS)
    @Test func headingIsUnavailableOnMacOS() async {
        #expect(!DarwinLocationManager.isHeadingAvailable())
        manager.startUpdatingHeading()
        #expect(delegate.events.isEmpty, "not inside the guest's call")
        await nextMainTurn()
        #expect(delegate.events == [.failure(LocationError.headingFailure.rawValue)])
    }
    #endif
}

// MARK: - Module

@Suite struct DarwinLocationModuleTests {

    @Test func contractsListEveryInterface() {
        #expect(DarwinLocation.contracts.map(\.name) == [
            "org.pureswift.location.LocationManager",
            "org.pureswift.location.LocationManagerDelegate",
            "org.pureswift.location.Location",
            "org.pureswift.location.Heading",
        ])
    }

    @Test func registersEveryContract() {
        let registrar = RecordingRegistrar()
        DarwinLocation.register(in: registrar)
        #expect(registrar.registered.map(\.descriptor) == DarwinLocation.contracts)
        #expect(registrar.registered.map(\.hasStatics) == [true, false, true, true], "the delegate is a callback interface")
    }

    @Test func usedByAnyOfItsContracts() {
        #expect(DarwinLocation.isUsed(by: ["org.pureswift.location.LocationManager"]))
        #expect(!DarwinLocation.isUsed(by: ["org.pureswift.motion.Pedometer"]))
    }

    @Test func providesLocationPermission() {
        let providers = DarwinLocation.permissionProviders()
        #expect(Array(providers.keys) == [.location])
        #expect(providers[.location] is LocationPermission)
    }
}

// MARK: - Always upgrade

/// Waits for `seconds` on the main queue.
@MainActor func wait(_ seconds: TimeInterval) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { continuation.resume() }
    }
}

/// `requestAlwaysAuthorization` checks the status first, asks iOS for the
/// upgrade only once per install, and always answers. Serialized: it
/// replaces `AlwaysUpgradePrompt`'s static settings.
@Suite(.serialized) @MainActor struct AlwaysUpgradeTests {

    let defaults: UserDefaults

    let center = NotificationCenter()

    init() {
        defaults = UserDefaults(suiteName: "DarwinLocationTests.\(UUID().uuidString)")!
        AlwaysUpgradePrompt.defaults = defaults
        AlwaysUpgradePrompt.notificationCenter = center
        AlwaysUpgradePrompt.promptDelay = 0.05
    }

    func manager(_ status: CLAuthorizationStatus) -> (DarwinLocationManager, FixedAuthorizationManager, FakeLocationDelegate) {
        let location = FixedAuthorizationManager()
        location.status = status
        let delegate = FakeLocationDelegate()
        return (DarwinLocationManager(delegate: delegate, manager: location), location, delegate)
    }

    // MARK: The prompt watch, on every platform

    @Test func watchWithoutAPromptAnswersAfterTheDelay() async {
        var calls = 0
        AlwaysUpgradePrompt.watch { calls += 1 }
        #expect(calls == 0)
        await wait(0.2)
        #expect(calls == 1)
    }

    @Test func watchWithAPromptAnswersWhenItCloses() async {
        var calls = 0
        AlwaysUpgradePrompt.watch { calls += 1 }
        center.post(name: AlwaysUpgradePrompt.resignActive, object: nil)
        await wait(0.2)
        #expect(calls == 0, "the prompt is still up")
        center.post(name: AlwaysUpgradePrompt.becomeActive, object: nil)
        center.post(name: AlwaysUpgradePrompt.becomeActive, object: nil)
        await wait(0.1)
        #expect(calls == 1, "once")
    }

    @Test func activeWithoutResigningIsNotTheEnd() async {
        var calls = 0
        AlwaysUpgradePrompt.watch { calls += 1 }
        center.post(name: AlwaysUpgradePrompt.becomeActive, object: nil)
        await nextMainTurn()
        #expect(calls == 0, "only after a prompt appeared")
        await wait(0.2)
        #expect(calls == 1)
    }

    @Test func theRequestIsRemembered() {
        #expect(!AlwaysUpgradePrompt.alreadyRequested)
        AlwaysUpgradePrompt.alreadyRequested = true
        #expect(defaults.bool(forKey: AlwaysUpgradePrompt.requestedKey))
    }

    // MARK: The manager, on iOS (macOS has no when-in-use)

    #if os(iOS)
    var whenInUse: FakeLocationDelegate.Event {
        .authorization(status: LocationAuthorization.authorizedWhenInUse.rawValue, accuracy: LocationAccuracyAuthorization.full.rawValue)
    }

    @Test func decidedStatusesAnswerWithoutAsking() async {
        for status in [CLAuthorizationStatus.denied, .restricted, .authorizedAlways] {
            let (manager, location, delegate) = self.manager(status)
            manager.requestAlwaysAuthorization()
            #expect(delegate.events.isEmpty, "not inside the call")
            await nextMainTurn()
            #expect(location.alwaysRequests == 0, "\(status.rawValue)")
            #expect(delegate.events.count == 1, "\(status.rawValue)")
        }
    }

    @Test func notDeterminedAsks() {
        let (manager, location, _) = self.manager(.notDetermined)
        manager.requestAlwaysAuthorization()
        #expect(location.alwaysRequests == 1)
        #expect(!AlwaysUpgradePrompt.alreadyRequested, "only the upgrade is limited to once")
    }

    @Test func upgradeWithoutAPromptIsAnsweredAfterTheDelay() async {
        let (manager, location, delegate) = self.manager(.authorizedWhenInUse)
        manager.requestAlwaysAuthorization()
        #expect(location.alwaysRequests == 1)
        #expect(AlwaysUpgradePrompt.alreadyRequested)
        await wait(0.2)
        #expect(delegate.events == [whenInUse], "no prompt: the unchanged status is the answer")
    }

    @Test func upgradeWithAPromptIsAnsweredWhenItCloses() async {
        let (manager, _, delegate) = self.manager(.authorizedWhenInUse)
        manager.requestAlwaysAuthorization()
        center.post(name: AlwaysUpgradePrompt.resignActive, object: nil)
        await wait(0.2)
        #expect(delegate.events.isEmpty, "the prompt is still up")
        center.post(name: AlwaysUpgradePrompt.becomeActive, object: nil)
        await nextMainTurn()
        await nextMainTurn()
        #expect(delegate.events == [whenInUse], "the user kept when-in-use")
    }

    @Test func upgradeTheUserAcceptsIsReportedOnce() async {
        let (manager, location, delegate) = self.manager(.authorizedWhenInUse)
        manager.requestAlwaysAuthorization()
        center.post(name: AlwaysUpgradePrompt.resignActive, object: nil)
        // CoreLocation reports the change before the app is active again.
        location.status = .authorizedAlways
        manager.locationManagerDidChangeAuthorization(location)
        center.post(name: AlwaysUpgradePrompt.becomeActive, object: nil)
        await wait(0.2)
        #expect(delegate.events == [.authorization(
            status: LocationAuthorization.authorizedAlways.rawValue,
            accuracy: LocationAccuracyAuthorization.full.rawValue
        )])
    }

    @Test func aSecondUpgradeAnswersWithoutAsking() async {
        AlwaysUpgradePrompt.alreadyRequested = true
        let (manager, location, delegate) = self.manager(.authorizedWhenInUse)
        manager.requestAlwaysAuthorization()
        await nextMainTurn()
        #expect(location.alwaysRequests == 0, "iOS wouldn't show the prompt again")
        #expect(delegate.events == [whenInUse])
    }
    #endif
}
