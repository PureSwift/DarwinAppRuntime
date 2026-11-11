import CoreMotion
import DarwinHost
@testable import DarwinMotion
import DynamicMotion
import DynamicRuntime
import Foundation
import Testing

// MARK: - Fakes

final class FakeMotionDelegate: MotionManagerDelegate {

    var failures: [(sensor: Int32, error: Int32)] = []

    var samples = 0

    func didUpdateAcceleration(_ manager: any MotionManager, x: Double, y: Double, z: Double, timestamp: Int64) {
        samples += 1
    }

    func didUpdateRotationRate(_ manager: any MotionManager, x: Double, y: Double, z: Double, timestamp: Int64) {
        samples += 1
    }

    func didUpdateMagneticField(_ manager: any MotionManager, x: Double, y: Double, z: Double, accuracy: Int32, timestamp: Int64) {
        samples += 1
    }

    func didUpdateDeviceMotion(
        _ manager: any MotionManager,
        attitudeX: Double, attitudeY: Double, attitudeZ: Double, attitudeW: Double,
        gravityX: Double, gravityY: Double, gravityZ: Double,
        userAccelerationX: Double, userAccelerationY: Double, userAccelerationZ: Double,
        rotationRateX: Double, rotationRateY: Double, rotationRateZ: Double,
        timestamp: Int64
    ) {
        samples += 1
    }

    func didFail(_ manager: any MotionManager, sensor: Int32, error: Int32) {
        failures.append((sensor, error))
    }
}

final class FakePedometerDelegate: PedometerDelegate {

    var statuses: [Int32] = []

    var updates = 0

    var queries: [MotionConversions.PedometerCounts] = []

    var queryErrors: [Int32] = []

    var failures: [Int32] = []

    func didChangeAuthorization(_ pedometer: any Pedometer, status: Int32) {
        statuses.append(status)
    }

    func didUpdate(_ pedometer: any Pedometer, steps: Int64, distance: Double, floorsAscended: Int32, floorsDescended: Int32, start: Int64, end: Int64) {
        updates += 1
    }

    func didQuery(_ pedometer: any Pedometer, steps: Int64, distance: Double, floorsAscended: Int32, floorsDescended: Int32, start: Int64, end: Int64, error: Int32) {
        queries.append(.init(steps: steps, distance: distance, floorsAscended: floorsAscended, floorsDescended: floorsDescended, start: start, end: end))
        queryErrors.append(error)
    }

    func didFail(_ pedometer: any Pedometer, error: Int32) {
        failures.append(error)
    }
}

final class FakeAltimeterDelegate: AltimeterDelegate {

    var statuses: [Int32] = []

    var failures: [Int32] = []

    func didChangeAuthorization(_ altimeter: any Altimeter, status: Int32) {
        statuses.append(status)
    }

    func didUpdate(_ altimeter: any Altimeter, pressure: Double, relativeAltitude: Double, timestamp: Int64) { }

    func didFail(_ altimeter: any Altimeter, error: Int32) {
        failures.append(error)
    }
}

final class FakeActivityDelegate: ActivityRecognizerDelegate {

    var statuses: [Int32] = []

    var failures: [Int32] = []

    func didChangeAuthorization(_ recognizer: any ActivityRecognizer, status: Int32) {
        statuses.append(status)
    }

    func didUpdateActivity(_ recognizer: any ActivityRecognizer, activity: Int32, confidence: Int32, timestamp: Int64) { }

    func didFail(_ recognizer: any ActivityRecognizer, error: Int32) {
        failures.append(error)
    }
}

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

/// Lets main-queue work scheduled before this call run.
func nextMainTurn() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

// MARK: - Conversions

@Suite struct MotionTimestampTests {

    @Test func sampleAgeIsSubtractedFromHostNow() {
        let now: Int64 = 5_000_000_000_000
        #expect(MotionConversions.hostNanoseconds(uptime: 100, uptimeNow: 100, hostNow: now) == now)
        #expect(MotionConversions.hostNanoseconds(uptime: 99.5, uptimeNow: 100, hostNow: now) == now - 500_000_000)
        #expect(MotionConversions.hostNanoseconds(uptime: 100.001, uptimeNow: 100, hostNow: now) == now + 1_000_000, "a sample read just after now")
    }

    @Test func keepsMicrosecondsAfterLongUptimes() {
        // A month of uptime: the age is computed before scaling, so it keeps
        // its precision.
        let uptime: TimeInterval = 30 * 86_400
        let a = MotionConversions.hostNanoseconds(uptime: uptime - 0.010_001, uptimeNow: uptime, hostNow: 0)
        let b = MotionConversions.hostNanoseconds(uptime: uptime - 0.010_000, uptimeNow: uptime, hostNow: 0)
        #expect(b - a == 1_000)
    }

    @Test func corruptSamplesUseNow() {
        #expect(MotionConversions.hostNanoseconds(uptime: .nan, uptimeNow: 1, hostNow: 42) == 42)
        #expect(MotionConversions.hostNanoseconds(uptime: -.infinity, uptimeNow: 1, hostNow: 42) == 42)
    }

    @Test func matchesTheHostClock() {
        // A sample stamped now is now on the built-in Clock's timeline.
        let converted = MotionConversions.hostNanoseconds(uptime: ProcessInfo.processInfo.systemUptime)
        let now = DispatchClock().now()
        #expect(abs(now - converted) < 50_000_000)
    }

    @Test func wallClockMilliseconds() {
        #expect(MotionConversions.milliseconds(Date(timeIntervalSince1970: 1_700_000_000.123)) == 1_700_000_000_123)
        #expect(MotionConversions.date(milliseconds: 1_700_000_000_123).timeIntervalSince1970 == 1_700_000_000.123)
    }
}

@Suite struct MotionSampleTests {

    @Test func accelerationBecomesMetersPerSecondSquaredWithAndroidsSign() {
        // At rest, face up: CoreMotion reports z = -1 g.
        #expect(MotionConversions.acceleration(-1) == standardGravity)
        #expect(MotionConversions.acceleration(0.5) == -0.5 * standardGravity)
        #expect(MotionConversions.acceleration(0) == 0)
    }

    @Test func attitudeIsNormalized() {
        let q = MotionConversions.attitude(x: 0, y: 0, z: 0, w: 2)
        #expect(q == (0, 0, 0, 1))
        let zero = MotionConversions.attitude(x: 0, y: 0, z: 0, w: 0)
        #expect(zero == (0, 0, 0, 1), "a degenerate quaternion becomes identity")
    }

    /// The attitude rotates device coordinates into the reference frame:
    /// rotating the converted gravity gives straight up.
    @Test(arguments: [0.0, 0.3, 1.0, Double.pi / 2])
    func attitudeAndGravityAgree(pitch: Double) {
        // CoreMotion, top edge raised by `pitch` about the device's x axis.
        let coreMotionQuaternion = (x: sin(pitch / 2), y: 0.0, z: 0.0, w: cos(pitch / 2))
        let coreMotionGravity = (x: 0.0, y: -sin(pitch), z: -cos(pitch))

        let q = MotionConversions.attitude(x: coreMotionQuaternion.x, y: coreMotionQuaternion.y, z: coreMotionQuaternion.z, w: coreMotionQuaternion.w)
        let attitude = Quaternion(x: q.x, y: q.y, z: q.z, w: q.w)
        let gravity = Vector3(
            x: MotionConversions.acceleration(coreMotionGravity.x),
            y: MotionConversions.acceleration(coreMotionGravity.y),
            z: MotionConversions.acceleration(coreMotionGravity.z)
        )
        let up = attitude.rotate(gravity)
        #expect(abs(up.x) < 1e-9)
        #expect(abs(up.y) < 1e-9)
        #expect(abs(up.z - standardGravity) < 1e-9)
    }

    @Test func magneticFieldAccuracy() {
        #expect(MotionConversions.magneticFieldAccuracy(-1) == .uncalibrated)
        #expect(MotionConversions.magneticFieldAccuracy(0) == .low)
        #expect(MotionConversions.magneticFieldAccuracy(1) == .medium)
        #expect(MotionConversions.magneticFieldAccuracy(2) == .high)
        #expect(MotionConversions.magneticFieldAccuracy(7) == .uncalibrated)
    }
}

@Suite struct MotionServiceConversionTests {

    @Test func activityFlags() {
        let none = MotionConversions.activity(stationary: false, walking: false, running: false, automotive: false, cycling: false, unknown: false)
        #expect(none == 0)
        let redLight = MotionConversions.activity(stationary: true, walking: false, running: false, automotive: true, cycling: false, unknown: false)
        #expect(MotionActivity(rawValue: redLight) == [.stationary, .automotive])
        let all = MotionConversions.activity(stationary: true, walking: true, running: true, automotive: true, cycling: true, unknown: true)
        #expect(MotionActivity(rawValue: all) == [.stationary, .walking, .running, .automotive, .cycling, .unknown])
    }

    @Test func confidence() {
        #expect(MotionConversions.confidence(0) == .low)
        #expect(MotionConversions.confidence(1) == .medium)
        #expect(MotionConversions.confidence(2) == .high)
        #expect(MotionConversions.confidence(9) == .low)
    }

    @Test func pedometerCounts() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_000_600.5)
        let full = MotionConversions.pedometer(steps: 1200, distance: 900.5, floorsAscended: 3, floorsDescended: 1, start: start, end: end)
        #expect(full == .init(steps: 1200, distance: 900.5, floorsAscended: 3, floorsDescended: 1, start: 1_700_000_000_000, end: 1_700_000_600_500))
        let stepsOnly = MotionConversions.pedometer(steps: 10, distance: nil, floorsAscended: nil, floorsDescended: nil, start: start, end: end)
        #expect(stepsOnly.distance.isNaN, "distance the device can't measure is nan")
        #expect(stepsOnly.floorsAscended == -1)
        #expect(stepsOnly.floorsDescended == -1)
    }

    @Test func authorization() {
        #expect(MotionConversions.authorization(CMAuthorizationStatus.notDetermined.rawValue) == .notDetermined)
        #expect(MotionConversions.authorization(CMAuthorizationStatus.restricted.rawValue) == .restricted)
        #expect(MotionConversions.authorization(CMAuthorizationStatus.denied.rawValue) == .denied)
        #expect(MotionConversions.authorization(CMAuthorizationStatus.authorized.rawValue) == .authorized)
        #expect(MotionConversions.authorization(17) == .notDetermined)
    }

    @Test func permission() {
        #expect(MotionConversions.permission(.notDetermined) == .notDetermined)
        #expect(MotionConversions.permission(.restricted) == .restricted)
        #expect(MotionConversions.permission(.denied) == .denied)
        #expect(MotionConversions.permission(.authorized) == .granted)
    }

    @Test func errors() {
        func cmError(_ code: CMError) -> NSError {
            NSError(domain: CMErrorDomain, code: Int(code.rawValue))
        }
        #expect(MotionConversions.error(cmError(CMErrorMotionActivityNotAuthorized)) == .unauthorized)
        #expect(MotionConversions.error(cmError(CMErrorNotAuthorized)) == .unauthorized)
        #expect(MotionConversions.error(cmError(CMErrorMotionActivityNotEntitled)) == .unauthorized)
        #expect(MotionConversions.error(cmError(CMErrorNotEntitled)) == .unauthorized)
        #expect(MotionConversions.error(cmError(CMErrorMotionActivityNotAvailable)) == .unavailable)
        #expect(MotionConversions.error(cmError(CMErrorNotAvailable)) == .unavailable)
        #expect(MotionConversions.error(cmError(CMErrorDeviceRequiresMovement)) == .unknown)
        #expect(MotionConversions.error(NSError(domain: NSCocoaErrorDomain, code: Int(CMErrorNotAuthorized.rawValue))) == .unknown, "other domains")
    }
}

// MARK: - Implementations

/// The implementations on this test host. Tests run on macOS, where
/// CoreMotion has none of these services.
@Suite @MainActor struct MotionImplementationTests {

    @Test func intervalsAreClamped() {
        #expect(DarwinMotionManager.clamp(1.0 / 60) == 1.0 / 60)
        #expect(DarwinMotionManager.clamp(0.001) == DarwinMotionManager.minimumInterval)
        #expect(DarwinMotionManager.clamp(-1) == DarwinMotionManager.minimumInterval)
        #expect(DarwinMotionManager.clamp(.nan) == DarwinMotionManager.minimumInterval)
        let manager = DarwinMotionManager.make(FakeMotionDelegate())
        #expect(manager.minimumInterval(MotionSensor.accelerometer.rawValue) == 0.01)
    }

    @Test func unknownSensorFails() async {
        let delegate = FakeMotionDelegate()
        let manager = DarwinMotionManager.make(delegate)
        #expect(!DarwinMotionManager.isAvailable(42))
        manager.start(42, interval: 0.1)
        await nextMainTurn()
        #expect(delegate.failures.map(\.sensor) == [42])
        #expect(delegate.failures.map(\.error) == [MotionError.unavailable.rawValue])
        #expect(!manager.isActive(42))
    }

    #if os(macOS)
    @Test func noSensorsOnMacOS() async {
        let delegate = FakeMotionDelegate()
        let manager = DarwinMotionManager.make(delegate)
        for sensor in MotionSensor.allCases {
            #expect(!DarwinMotionManager.isAvailable(sensor.rawValue))
            manager.start(sensor.rawValue, interval: 0.02)
        }
        #expect(delegate.failures.isEmpty, "not inside the guest's call")
        await nextMainTurn()
        #expect(delegate.failures.map(\.sensor) == MotionSensor.allCases.map(\.rawValue))
        #expect(delegate.failures.allSatisfy { $0.error == MotionError.unavailable.rawValue })
        #expect(MotionSensor.allCases.allSatisfy { !manager.isActive($0.rawValue) })
        manager.suspend()
        #expect(delegate.failures.count == MotionSensor.allCases.count, "nothing was running")
    }

    @Test func pedometerIsUnavailableOnMacOS() async {
        #expect(!DarwinPedometer.isStepCountingAvailable())
        #expect(!DarwinPedometer.isDistanceAvailable())
        #expect(!DarwinPedometer.isFloorCountingAvailable())
        #expect(!DarwinPedometer.isHistoryAvailable())
        #expect(DarwinPedometer.authorizationStatus() == MotionAuthorization.restricted.rawValue)

        let delegate = FakePedometerDelegate()
        let pedometer = DarwinPedometer.make(delegate)
        pedometer.requestAuthorization()
        pedometer.startUpdates(from: 0)
        pedometer.query(from: 1_000, to: 2_000)
        await nextMainTurn()
        #expect(delegate.statuses == [MotionAuthorization.restricted.rawValue], "answers without a prompt")
        #expect(delegate.failures == [MotionError.unavailable.rawValue])
        #expect(pedometer.updates == nil)
        #expect(delegate.queryErrors == [MotionError.unavailable.rawValue])
        #expect(delegate.queries == [.init(steps: -1, distance: .nan, floorsAscended: -1, floorsDescended: -1, start: 1_000, end: 2_000)])
    }

    @Test func altimeterIsUnavailableOnMacOS() async {
        #expect(!DarwinAltimeter.isAvailable())
        #expect(DarwinAltimeter.authorizationStatus() == MotionAuthorization.restricted.rawValue)
        let delegate = FakeAltimeterDelegate()
        let altimeter = DarwinAltimeter.make(delegate)
        altimeter.requestAuthorization()
        altimeter.startUpdates()
        await nextMainTurn()
        #expect(delegate.statuses == [MotionAuthorization.restricted.rawValue])
        #expect(delegate.failures == [MotionError.unavailable.rawValue])
        #expect(altimeter.updates == nil)
    }

    @Test func activityIsUnavailableOnMacOS() async {
        #expect(!DarwinActivityRecognizer.isAvailable())
        #expect(DarwinActivityRecognizer.authorizationStatus() == MotionAuthorization.restricted.rawValue)
        let delegate = FakeActivityDelegate()
        let recognizer = DarwinActivityRecognizer.make(delegate)
        recognizer.requestAuthorization()
        recognizer.startUpdates()
        await nextMainTurn()
        #expect(delegate.statuses == [MotionAuthorization.restricted.rawValue])
        #expect(delegate.failures == [MotionError.unavailable.rawValue])
        #expect(recognizer.updates == nil)
    }

    @Test func motionPermissionIsUnavailableOnMacOS() async {
        let permission = MotionPermission()
        #expect(permission.status() == .unavailable)
        var answered: [PermissionStatus] = []
        permission.request { answered.append($0) }
        #expect(answered == [.unavailable])
    }
    #endif

    @Test func failingAServiceReportsOnce() {
        let delegate = FakePedometerDelegate()
        let pedometer = DarwinPedometer.make(delegate)
        pedometer.fail(.suspended)
        #expect(delegate.failures == [MotionError.suspended.rawValue])
        pedometer.stopUpdates()
        #expect(delegate.failures.count == 1, "stopping again reports nothing")
    }
}

// MARK: - Module

@Suite struct DarwinMotionModuleTests {

    @Test func contractsListEveryInterface() {
        #expect(DarwinMotion.contracts.map(\.name) == [
            "org.pureswift.motion.MotionManager",
            "org.pureswift.motion.MotionManagerDelegate",
            "org.pureswift.motion.Pedometer",
            "org.pureswift.motion.PedometerDelegate",
            "org.pureswift.motion.Altimeter",
            "org.pureswift.motion.AltimeterDelegate",
            "org.pureswift.motion.ActivityRecognizer",
            "org.pureswift.motion.ActivityRecognizerDelegate",
        ])
    }

    @Test func registersEveryContract() {
        let registrar = RecordingRegistrar()
        DarwinMotion.register(in: registrar)
        #expect(registrar.registered.map(\.descriptor) == DarwinMotion.contracts)
        #expect(registrar.registered.map(\.hasStatics) == [true, false, true, false, true, false, true, false])
    }

    @Test func capabilities() {
        let byName = Dictionary(uniqueKeysWithValues: DarwinMotion.contracts.map { ($0.name, $0.capability) })
        #expect(byName["org.pureswift.motion.MotionManager"] == .some(nil), "raw sensors need no permission")
        #expect(byName["org.pureswift.motion.Pedometer"] == Capability("motion"))
    }

    @Test func providesMotionPermission() {
        let providers = DarwinMotion.permissionProviders()
        #expect(Array(providers.keys) == [Capability("motion")])
        #expect(providers[Capability("motion")] is MotionPermission)
    }
}
