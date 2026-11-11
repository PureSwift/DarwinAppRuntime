import DynamicBluetooth
import Foundation

/// A weak reference, for maps that mustn't keep wrappers alive.
final class Weak<Value: AnyObject> {

    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

/// Wrappers by key, held weakly. Entries whose wrapper is gone are dropped
/// every few insertions.
struct WeakMap<Key: Hashable, Value: AnyObject> {

    private var entries: [Key: Weak<Value>] = [:]

    private var insertions = 0

    /// Insertions between sweeps of dead entries.
    let sweepInterval: Int

    init(sweepInterval: Int = 32) {
        self.sweepInterval = sweepInterval
    }

    subscript(key: Key) -> Value? {
        entries[key]?.value
    }

    mutating func set(_ value: Value, for key: Key) {
        entries[key] = Weak(value)
        insertions += 1
        if insertions >= sweepInterval {
            insertions = 0
            entries = entries.filter { $0.value.value != nil }
        }
    }

    /// Entries, including dead ones not swept yet.
    var count: Int {
        entries.count
    }
}

/// Requests waiting for a CoreBluetooth callback, in the order they were
/// made. `key` names the CoreBluetooth object the callback is about, and
/// `target` is the wrapper to report it with.
///
/// CoreBluetooth answers each request once, in order per attribute, but
/// never answers requests outstanding when the link drops. The peripheral
/// fails what's left here instead, so every call gets exactly one callback.
struct PendingOperations<Target: AnyObject> {

    private var entries: [(key: ObjectIdentifier, target: Target)] = []

    mutating func add(_ target: Target, key: ObjectIdentifier) {
        entries.append((key, target))
    }

    /// Removes and returns the oldest request about `key`.
    mutating func take(_ key: ObjectIdentifier) -> Target? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else {
            return nil
        }
        return entries.remove(at: index).target
    }

    /// Removes and returns every request, oldest first.
    mutating func takeAll() -> [Target] {
        defer { entries = [] }
        return entries.map(\.target)
    }

    var count: Int {
        entries.count
    }
}

/// One central's scan parameters.
///
/// The process has one `CBCentralManager`, so concurrent scans from several
/// centrals run as one combined scan, and each central filters what it
/// receives back to what it asked for.
struct ScanRequest: Equatable {

    /// Only peripherals advertising one of these; all if empty.
    var services: [BluetoothUUID]

    var allowDuplicates: Bool

    /// The scan that satisfies every request: all peripherals if any
    /// request wants all, otherwise the union of their services; with
    /// duplicates if any request wants them. `nil` if there are none.
    static func combined(_ requests: [ScanRequest]) -> ScanRequest? {
        guard !requests.isEmpty else { return nil }
        let allowDuplicates = requests.contains { $0.allowDuplicates }
        if requests.contains(where: { $0.services.isEmpty }) {
            return ScanRequest(services: [], allowDuplicates: allowDuplicates)
        }
        var services: [BluetoothUUID] = []
        for uuid in requests.flatMap(\.services)
        where !services.contains(where: { CoreBluetoothMapping.sameUUID($0, uuid) }) {
            services.append(uuid)
        }
        return ScanRequest(services: services, allowDuplicates: allowDuplicates)
    }

    /// Whether a central with this request reports an advertisement that
    /// the running scan, `active`, found.
    ///
    /// - Parameters:
    ///   - advertised: The advertisement's service UUIDs.
    ///   - isRepeat: Whether this central already reported the peripheral
    ///     during this scan.
    func accepts(advertised: [BluetoothUUID], isRepeat: Bool, active: ScanRequest) -> Bool {
        // Without duplicates CoreBluetooth reports a peripheral again only
        // when its advertisement changes (a scan response, say); only drop
        // repeats that another central's duplicates let through.
        if isRepeat, !allowDuplicates, active.allowDuplicates {
            return false
        }
        // CoreBluetooth already filtered for exactly these services.
        if services.isEmpty || active.services == services {
            return true
        }
        return advertised.contains { uuid in
            services.contains { CoreBluetoothMapping.sameUUID($0, uuid) }
        }
    }
}

/// Connection timeouts, since `CBCentralManager.connect` never times out.
/// Main thread only.
final class ConnectionTimeouts {

    /// Runs `body` after `milliseconds`; returns what cancels it.
    typealias Schedule = (_ milliseconds: Int32, _ body: @escaping () -> Void) -> () -> Void

    private let schedule: Schedule

    private var timers: [UUID: (token: Int, cancel: () -> Void)] = [:]

    private var nextToken = 0

    init(schedule: @escaping Schedule = ConnectionTimeouts.mainQueue) {
        self.schedule = schedule
    }

    deinit {
        cancelAll()
    }

    /// Calls `onTimeout` after `milliseconds` unless cancelled first.
    /// Replaces any timer for `peripheral`. `0` or less means no timeout.
    func start(_ peripheral: UUID, milliseconds: Int32, onTimeout: @escaping () -> Void) {
        cancel(peripheral)
        guard milliseconds > 0 else { return }
        nextToken += 1
        let token = nextToken
        let cancel = schedule(milliseconds) { [weak self] in
            // A replaced or cancelled timer that fires anyway does nothing.
            guard let self, self.timers[peripheral]?.token == token else { return }
            self.timers[peripheral] = nil
            onTimeout()
        }
        timers[peripheral] = (token, cancel)
    }

    func cancel(_ peripheral: UUID) {
        timers.removeValue(forKey: peripheral)?.cancel()
    }

    func cancelAll() {
        let cancelled = timers.values
        timers = [:]
        for timer in cancelled {
            timer.cancel()
        }
    }

    func isRunning(_ peripheral: UUID) -> Bool {
        timers[peripheral] != nil
    }

    /// A main-queue timer.
    static func mainQueue(_ milliseconds: Int32, _ body: @escaping () -> Void) -> () -> Void {
        let item = DispatchWorkItem(block: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(milliseconds)), execute: item)
        return { item.cancel() }
    }
}
