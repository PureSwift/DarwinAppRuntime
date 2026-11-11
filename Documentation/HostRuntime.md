# Darwin host runtime — Design

**Status:** proposed. Nothing here is implemented yet.

The host runtime runs AppRuntime apps on iOS and macOS. It is everything
AppRuntime's design (§2.3, §7.6) assigns to the host:

- `main` and the run loop;
- the runtime core behind `rt.h`;
- the contract implementations over Apple frameworks;
- the UI player (see `SwiftUIRenderer.md`);
- the engine that runs the app's guest code.

An app's universal bundle contains only guest code. This repository turns
it into an app that runs. Packaging is in `ManifestPackager.md`, and the
changes this needs in AppRuntime are in `AppRuntimeChanges.md`.

References like §7.6 are to `Documentation/DynamicRuntime.md` in AppRuntime.

## 1. Scope

| In | Out (for now) |
|---|---|
| iOS 13+ on device (`ios-arm64` slices), iOS Simulator, macOS 10.15+ (`macos` slices, arm64 and x86_64) | iOS 6 armv7: Swift-iOS6's backend is a separate host |
| The Swift-registry backend: contracts implemented in Swift | The ObjC backend (§6): native-class bindings through `objc_msgSend`, for apps that call UIKit directly |
| Every contract AppRuntime declares today | tvOS, watchOS, visionOS: the slices exist; the hosts follow once iOS works |

The minimums match the slices. `guest.py` stamps `ios-arm64` slices for
iOS 13.0 and `macos` slices for 10.15, and SwiftUI needs iOS 13 / macOS
10.15.

## 2. Process model

An app is one process with one executable:

```
┌──────────────────────── App.app (one executable) ────────────────────────┐
│  host main (DarwinHost)                                                  │
│    ├── runtime core: RuntimeCore + RuntimeNative (rt_* symbols)          │
│    ├── contract implementations: DarwinBluetooth, DarwinLocation, …      │
│    ├── SwiftUI player: DarwinUI                                          │
│    └── engine                                                            │
│          native: libapp.a (sealed, linked in)   ← default                │
│          wasm2c: App.wasm translated to C, compiled in   ← no slice      │
│          WasmKit: App.wasm interpreted   ← development, iOS 18/macOS 15  │
└──────────────────────────────────────────────────────────────────────────┘
```

The guest calls the host through `rt.h`, and the host calls back through
`rt_dispatch`. Everything runs on the main thread (§6.4).

### 2.1 Engines

| Engine | When | Where | Notes |
|---|---|---|---|
| **Native slice** | The bundle has a slice for the platform | iOS device, macOS | The packager links `libapp.a`. It's the fastest, and needs no translation. |
| **wasm2c** | No native slice: the iOS Simulator (until AppRuntime builds simulator slices), or apps shipped without native slices | Everywhere | The packager translates `App.wasm` to C and compiles it for the target, behind an `rt` import shim. No interpreter ships, so App Store builds can use it (§14). |
| **WasmKit** | Development: hot reload and loading a new `App.wasm` without relinking | macOS 15+, iOS 18+ (WasmKit's own minimums) | Never in App Store builds. It lives in a separate package (`DarwinWasmHost`), since SwiftPM won't mix platform minimums within a package. |

All three use the same runtime core: the same handle table, contracts and
renderer. Only what implements `rt_dispatch` and the imports differs:

- **native:** the C symbols are direct calls;
- **wasm2c:** a shim converts guest offsets to pointers, like `RuntimeWasm`'s
  import shim, but as generated C;
- **WasmKit:** `RuntimeWasm`.

## 3. Modules

One Swift package, `DarwinAppRuntime`, with a minimum of iOS 13 / macOS
10.15:

| Module | Contents |
|---|---|
| `DarwinHost` | Startup, bundle checks, engine selection, lifecycle, `HostClock`, the main-thread executor for callbacks, and the built-in contracts the core doesn't serve (`Permissions`, `Bundle`, `Application`; see `AppRuntimeChanges.md`) |
| `DarwinBluetooth` | `Central` and friends over CoreBluetooth |
| `DarwinLocation` | `LocationManager` over CoreLocation |
| `DarwinMotion` | `MotionManager`, `Pedometer`, `Altimeter`, `ActivityRecognizer` over CoreMotion |
| `DarwinNFC` | `NFCReader` over CoreNFC (iOS only) |
| `DarwinDevice` | `Device` over UIDevice, ProcessInfo and IOKit (macOS) |
| `DarwinNetworking` | `HTTPSession` over URLSession |
| `DarwinFormatting` | Number and date formatting over Foundation's formatters |
| `DarwinUI` | The SwiftUI player (`SwiftUIRenderer.md`) |
| `DarwinHostApp` | The app's `main`: the SwiftUI `App` (iOS 14+ / macOS 11+), or a UIKit / AppKit delegate with a hosting controller (iOS 13 / macOS 10.15) |
| `darwin-app` | The packager (`ManifestPackager.md`) |

`DarwinWasmHost` is a separate package (iOS 18 / macOS 15) with the WasmKit
engine, used by development builds.

Each contract module depends on the AppRuntime contract module it
implements (`DynamicBluetooth`, …), which provides the protocols, the proxies
and the registration helpers.

## 4. Startup

`DarwinHostApp`'s `main`, on the main thread:

1. **Read the bundle's `Info.plist`.** The packager copied the app's keys
   into the host app's own `Info.plist`: `RTABIVersion`, `RTTargets`,
   `RTCapabilities` and `RTContracts`.
2. **Check compatibility (§7.6):**
   - Refuse an app whose `RTABIVersion` is newer than the host's.
   - Refuse a contract version newer than the one registered.
   - A method added in a later contract version resolves as absent
     (`rt_method == 0`).
   - The packager already checked all of this, so a failure here means a
     corrupt or tampered app. The host reports it and exits.
3. **Make the runtime:**
   - one `HostRuntime`;
   - a `NativeRuntime` for the native engine, or a `WasmApp` / wasm2c
     instance;
   - `capabilities` set from `RTCapabilities`.

   `rt_class` returns `0` for a contract whose capability the manifest
   doesn't declare (§7.3).
4. **Register the built-ins:**
   - `Clock`, served from a `HostClock` (§6);
   - `Permissions`, `Bundle` and `Application`;
   - `List`, `String` and `Bytes`, which `HostRuntime` serves itself.
5. **Register the contract implementations** for the contracts the app
   uses, from `RTContracts`. Contracts it doesn't use aren't registered, so
   the guest can't resolve them (§14's allowlist).
6. **Call `rt_main`** inside an `@autoreleasepool`. The guest sets up and
   calls `Renderer.make`; the player creates its root view and installs it
   in the window. `rt_main` returns once the guest's first tree is out
   (`GuestExecutor.whenIdle`).
7. **Run the run loop.** From here, the guest runs only when the host calls
   it: events, delegate callbacks, timers.

If `rt_main` fails, or the app never makes a renderer, the window shows an
error view in debug builds. A release build logs the error and shows an
empty window rather than crashing. This is the case App Review would see.

## 5. Contract implementations

Each implementation is a Swift class that conforms to the contract's
protocol and is registered with the generated helper:

```swift
CentralProxy.register(DarwinCentral.self, in: native)
CentralDelegateProxy.registerInterface(in: native)
```

A delegate the guest passes in arrives as a proxy (`any CentralDelegate`),
and the implementation calls it like any Swift object. The contract
documents in AppRuntime (`Documentation/Contracts/*.md`) define the
behavior. These rules apply across all of them:

- **Permissions first.**
  - The static `authorizationStatus()` never prompts. `make` never prompts
    either. The `request…` call is the only prompt.
  - Some frameworks prompt as a side effect, so their implementations
    create the framework object lazily. **Creating a `CBCentralManager`
    prompts for Bluetooth on iOS 13+.** `DarwinCentral` doesn't create one
    until `requestAuthorization()`, or until `CBManager.authorization` says
    access is already decided. Until then, `state()` reports `unknown`.
  - `CLLocationManager` and the CoreMotion managers don't prompt on
    creation, so they're created in `make`.
- **Main thread.** Framework objects are created with the main queue, as
  with `CBCentralManager(delegate:queue: .main)`. Callbacks that arrive
  elsewhere hop to `DispatchQueue.main` first:
  - URLSession tasks use a delegate queue on the main `OperationQueue`.
  - CoreMotion handlers use `OperationQueue.main`.

  Every host→guest call is wrapped in an `@autoreleasepool`.
- **Ownership** (§6.3):
  - An implementation keeps its delegate proxy strongly; the guest's
    `rt_finalize` happens when the proxy is released.
  - Framework objects keep their implementation through Apple's own weak
    `delegate` properties, so there are no cycles.
- **Errors.** Framework errors map to the contract's `Int32` error codes,
  using each contract's table. Anything unmapped is `unknown` (1). A
  failure the contract has no slot for is logged, never dropped silently.
- **Identity.** A framework object maps to one implementation object for
  as long as both live. The implementation keeps a map from
  `CBPeripheral.identifier` and similar keys to its wrapper. Guest-side
  wrappers compare objects with `rt_same` (`DynamicObject.same`), so
  handing out two handles for one object is fine, but two wrapper objects
  for one peripheral would break delegate routing.

### 5.1 Per contract

| Contract | Framework | Notes |
|---|---|---|
| Bluetooth `Central`, `Peripheral`, … | CoreBluetooth | `BluetoothUUID` strings in any of the three forms (16-bit, 32-bit, 128-bit) map to `CBUUID`. `Peripheral.identifier` is `CBPeripheral.identifier`; there is no MAC address. Scan modes map to `CBCentralManagerScanOptionAllowDuplicatesKey` (iOS has no power modes). `ScanMode` is accepted and ignored. Connection timeouts are enforced by the implementation with a main-queue timer, since CoreBluetooth has none. |
| `LocationManager` | CoreLocation | Accuracy constants map to `kCLLocationAccuracy…`. `requestFullAccuracy` uses `requestTemporaryFullAccuracyAuthorization(withPurposeKey:)` on iOS 14+; on iOS 13, accuracy is always full. |
| `MotionManager`, `Pedometer`, `Altimeter`, `ActivityRecognizer` | CoreMotion | Timestamps are converted to host monotonic nanoseconds (`Clock.now`). On macOS, `isAvailable` is false for most sensors. |
| `NFCReader` | CoreNFC | iOS only; on macOS the contract isn't registered, so `rt_class` returns `0`. An `NFCTagReaderSession` or `NFCNDEFReaderSession` is chosen by the requested tag types. The manifest's declared formats limit which sessions the entitlement allows. |
| `Device` | UIDevice, ProcessInfo; IOKit / IOPowerSources on macOS | Battery and orientation monitoring are on only while the guest asks for them. `vendorIdentifier` is `identifierForVendor` (`nil` on macOS). |
| `HTTPSession` | URLSession | One `URLSession` per contract session, whose delegate dispatches to the task delegates. Redirects and challenges ask the guest synchronously, on the main thread. |
| Formatting | Foundation | Cached formatters per locale and style. |

## 6. Built-in contracts

- **`Clock`.** `HostClock` is implemented with `mach_continuous_time()`
  for `now`, and `DispatchQueue.main.asyncAfter` for `schedule`. Timers keep
  running while the app is suspended and fire late, which matches "after at
  least". Because the host reads system boot time, its privacy manifest has
  to declare it (`ManifestPackager.md` §6).
- **`Permissions`, `Bundle`, `Application`.** They aren't in AppRuntime
  yet; `AppRuntimeChanges.md` proposes them.
  - `Application` reports lifecycle (active, inactive, background), memory
    warnings and opened URLs. A guest has no other way to learn about these.
  - `Bundle` serves the app's id, version, preferred languages and
    localized strings. Its resources are the bundle's `.lproj` folders,
    copied into the app.

## 7. Threading and re-entrancy

- The guest is single-threaded (§6.4). The host only enters it from the
  main thread: delegate callbacks, UI events and timers all arrive there.
- Calls nest: the guest calls the host, whose implementation calls back
  into the guest synchronously. Examples are a `should…` delegate method,
  or URLSession asking about a redirect. `HostRuntime` and the guest
  executor already handle this (§5.4: no draining inside a nested call).
- Work that has to happen off the main thread stays inside the
  implementation (URLSession's networking, CoreMotion's sampling), and
  only its results cross to the main thread.

## 8. The host's own Swift objects

The host's Swift code uses AppRuntime's `DynamicRuntime` as well:

- delegate proxies that call into the guest;
- host objects exported through `rt_implement`.

In native mode the app's sealed slice is linked into the same executable,
which raises two problems:

1. **Duplicate symbols.** Both `DynamicRuntime` and every slice define
   `rt_dispatch` and `rt_finalize`.
2. **Mixed routing.** Host objects are exported through the same C
   `rt_implement` the guest uses, so `HostRuntime` can't tell host contexts
   from guest contexts. Both are numbered from 1, and `NativeGuest`
   dispatches every call through the one C `rt_dispatch`.

The fix is in AppRuntime (`AppRuntimeChanges.md` §1). A host build of
`DynamicRuntime` (a package trait) defines no `rt_*` exports, and talks to
the runtime core in-process: its calls bind directly to a `HostRuntime`,
under a separate `Guest` whose `dispatch` calls `Exported.dispatch` in Swift.
The app's guest keeps the C symbols, and `NativeGuest` calls the slice's
`rt_dispatch`. One `HostRuntime` then serves two guests, the app and the
host's own Swift layer, each with its own context numbers.

## 9. Security

- **No downloaded code** (§14). The guest ships inside the app; the host
  never loads `App.wasm` from anywhere else in release builds. `DarwinWasmHost`
  (the interpreter) is a development-only dependency.
- **Allowlist.**
  - Only the contracts in the app's `RTContracts` are registered.
  - `rt_class` refuses contracts whose capability isn't declared.
  - The Swift-registry backend has no way to reach an arbitrary ObjC
    class or selector, and native bindings (the ObjC backend) aren't part
    of this design.
- **Capabilities are enforced twice:** by the packager (a contract without
  its capability is a build error) and by `rt_class` at run time.

## 10. Testing

- **Contract implementations:**
  - unit tests with fake framework objects where Apple allows it, such as
    URLSession with a custom `URLProtocol`;
  - integration tests on device for CoreBluetooth and CoreNFC, which have
    no simulator support.
- **Engines.**
  - A test executable links fixture slices that `guest.py` builds:
    AppRuntime's `ExampleApp` and `ExampleUI`. It checks the startup
    sequence, contract resolution and that `rt_main` runs.
  - The same fixtures run as wasm2c output and, on macOS 15, under WasmKit,
    and must give identical traces: the "same test app in both modes" rule
    (§2.4).
- **UI.**
  - XCUITest on the simulator drives `ExampleUI` through the accessibility
    identifiers it puts in the IR.
  - Player unit tests run without a guest (`SwiftUIRenderer.md` §10).

## 11. Open questions

- **ObjC backend.** Apps that call UIKit directly need a native-binding
  layer (§6, §14), which brings App Review risk and doesn't fit the
  allowlist model. It's probably best as a separate, opt-in package.
- **Background modes.** Bluetooth and location in the background need
  `UIBackgroundModes` and contract support for state restoration. The
  Bluetooth contract deliberately left state restoration out.
- **Multiple windows.** iPad scenes and macOS windows would each need their
  own renderer instance. The `Renderer` contract allows that: a guest can
  call `Renderer.make` once per scene. Telling the guest about scenes needs
  the `Application` contract.
