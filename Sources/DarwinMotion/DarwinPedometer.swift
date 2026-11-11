import CoreMotion
import DarwinHost
import DynamicMotion
import DynamicRuntime
import Foundation

/// The `Pedometer` contract over `CMPedometer`.
///
/// CoreMotion keeps seven days of history, so `query(from:to:)` works and
/// `startUpdates(from:)` can start in the past. `CMPedometer` would show the
/// Motion & Fitness prompt on its first query or update; to keep the
/// prompt in `requestAuthorization()`, both fail with `unauthorized` until
/// the status is `authorized`. Results arrive on CoreMotion's queue and
/// are passed to the delegate on the main queue.
///
/// macOS has no pedometer: the availability checks are `false`, the status
/// is `restricted`, and updates and queries fail with `unavailable`.
public final class DarwinPedometer: Pedometer {

    let delegate: any PedometerDelegate

    /// The token of the live updates. Updates queued before `stopUpdates()`
    /// carry an older token and are dropped.
    private(set) var updates: Int?

    private var nextToken = 0

    #if os(iOS)
    let pedometer = CMPedometer()
    #endif

    init(delegate: any PedometerDelegate) {
        self.delegate = delegate
    }

    deinit {
        #if os(iOS)
        if updates != nil {
            pedometer.stopUpdates()
        }
        #endif
    }

    public static func isStepCountingAvailable() -> Bool {
        #if os(iOS)
        CMPedometer.isStepCountingAvailable()
        #else
        false
        #endif
    }

    public static func isDistanceAvailable() -> Bool {
        #if os(iOS)
        CMPedometer.isDistanceAvailable()
        #else
        false
        #endif
    }

    public static func isFloorCountingAvailable() -> Bool {
        #if os(iOS)
        CMPedometer.isFloorCountingAvailable()
        #else
        false
        #endif
    }

    /// CoreMotion keeps seven days wherever it counts steps.
    public static func isHistoryAvailable() -> Bool {
        isStepCountingAvailable()
    }

    public static func authorizationStatus() -> Int32 {
        currentAuthorization().rawValue
    }

    static func currentAuthorization() -> MotionAuthorization {
        #if os(iOS)
        MotionConversions.authorization(CMPedometer.authorizationStatus().rawValue)
        #else
        .restricted
        #endif
    }

    public static func make(_ delegate: any PedometerDelegate) -> DarwinPedometer {
        DarwinPedometer(delegate: delegate)
    }

    /// Reports the outcome through `didChangeAuthorization`, also when
    /// nothing was asked.
    public func requestAuthorization() {
        MotionAuthorizationRequest.request { [weak self] _ in
            guard let self else { return }
            deliver {
                self.delegate.didChangeAuthorization(self, status: Self.authorizationStatus())
            }
        }
    }

    // MARK: Updates

    public func startUpdates(from start: Int64) {
        if let error = Self.precondition() {
            stopUpdates()
            return failLater(error)
        }
        #if os(iOS)
        if updates != nil {
            pedometer.stopUpdates()
        }
        nextToken += 1
        let token = nextToken
        updates = token
        pedometer.startUpdates(from: MotionConversions.date(milliseconds: start)) { [weak self] data, error in
            DispatchQueue.main.async {
                guard let self, self.updates == token else { return }
                if let error {
                    return self.fail(MotionConversions.reported(error, by: "CMPedometer updates"))
                }
                guard let data else { return }
                let counts = Self.counts(data)
                deliver {
                    self.delegate.didUpdate(
                        self, steps: counts.steps, distance: counts.distance,
                        floorsAscended: counts.floorsAscended, floorsDescended: counts.floorsDescended,
                        start: counts.start, end: counts.end
                    )
                }
            }
        }
        #endif
    }

    public func stopUpdates() {
        guard updates != nil else { return }
        updates = nil
        #if os(iOS)
        pedometer.stopUpdates()
        #endif
    }

    // MARK: Queries

    public func query(from start: Int64, to end: Int64) {
        if let error = Self.precondition() {
            return DispatchQueue.main.async { [weak self] in
                self?.sendQuery(nil, start: start, end: end, error: error)
            }
        }
        #if os(iOS)
        pedometer.queryPedometerData(
            from: MotionConversions.date(milliseconds: start),
            to: MotionConversions.date(milliseconds: end)
        ) { [weak self] data, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    return self.sendQuery(nil, start: start, end: end, error: MotionConversions.reported(error, by: "CMPedometer query"))
                }
                guard let data else {
                    return self.sendQuery(nil, start: start, end: end, error: .unknown)
                }
                self.sendQuery(Self.counts(data), start: start, end: end, error: nil)
            }
        }
        #endif
    }

    /// A query result. A failed query reports `-1` steps and floors, `nan`
    /// distance, and the requested dates.
    func sendQuery(_ counts: MotionConversions.PedometerCounts?, start: Int64, end: Int64, error: MotionError?) {
        let counts = counts ?? MotionConversions.PedometerCounts(
            steps: -1, distance: .nan, floorsAscended: -1, floorsDescended: -1, start: start, end: end
        )
        deliver {
            delegate.didQuery(
                self, steps: counts.steps, distance: counts.distance,
                floorsAscended: counts.floorsAscended, floorsDescended: counts.floorsDescended,
                start: counts.start, end: counts.end, error: error?.rawValue ?? 0
            )
        }
    }

    // MARK: Failures

    /// Why updates and queries can't run now: `unavailable` without step
    /// counting, `unauthorized` until the status is `authorized`.
    static func precondition() -> MotionError? {
        guard isStepCountingAvailable() else { return .unavailable }
        guard currentAuthorization() == .authorized else { return .unauthorized }
        return nil
    }

    /// Stops live updates and reports `error`.
    func fail(_ error: MotionError) {
        stopUpdates()
        deliver {
            delegate.didFail(self, error: error.rawValue)
        }
    }

    private func failLater(_ error: MotionError) {
        DispatchQueue.main.async { [weak self] in
            self?.fail(error)
        }
    }

    #if os(iOS)
    static func counts(_ data: CMPedometerData) -> MotionConversions.PedometerCounts {
        MotionConversions.pedometer(
            steps: data.numberOfSteps, distance: data.distance,
            floorsAscended: data.floorsAscended, floorsDescended: data.floorsDescended,
            start: data.startDate, end: data.endDate
        )
    }
    #endif
}
