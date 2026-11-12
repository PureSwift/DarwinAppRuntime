# Changes needed in AppRuntime

**Status:** landed. The Darwin host couldn't be built as designed until
these were in PureSwift/AppRuntime; all six are merged. Each one also serves
the Android and Linux hosts. Where
what landed differs from what was proposed, the section says so; AppRuntime's
`Documentation/Implementation.md` has the details.

| | Change | PR |
|---|---|---|
| 1 | Host builds of `DynamicRuntime` | PureSwift/AppRuntime#29 |
| 2 | Platform minimums | PureSwift/AppRuntime#28 |
| 3 | `Permissions`, `Bundle` and `Application` built-ins | PureSwift/AppRuntime#30 |
| 4 | iOS Simulator slices | PureSwift/AppRuntime#31 |
| 5 | Manifest stage | PureSwift/AppRuntime#32 |
| 6 | A shared wasm2c import shim | PureSwift/AppRuntime#33 |

## 1. Host builds of `DynamicRuntime`

**Problem.** A host links the app's sealed `libapp.a` together with its own
Swift code, which uses `DynamicRuntime` for delegate proxies and for
exporting host objects (`HostRuntime.md` §8). Before this change:

- `DynamicRuntime` defined the global `rt_dispatch` and `rt_finalize`
  (`Exported.swift`), and so does every slice: a duplicate symbol.
- Host objects were exported through the C `rt_implement` the guest also
  calls, so `HostRuntime` couldn't tell host contexts from guest contexts,
  and both sides numbered theirs from 1.
- `NativeGuest` dispatched everything through the C `rt_dispatch`.

**Landed, as proposed:**

1. **The `GuestExports` package trait** (on by default) controls
   `DynamicRuntime`'s `@c(rt_dispatch)` / `@c(rt_finalize)`. Hosts depend on
   AppRuntime with `traits: []`. `guest.py` passes each package's default
   traits to the compiler, so slices keep their exports.
2. **`RuntimeBinding`.** `Runtime` and `Exported` call through
   `Runtime.binding`: `CRuntimeBinding` (the C `rt_*` functions) by
   default, or `DirectRuntimeBinding` to an in-process `HostRuntime`. A host
   calls `NativeRuntime.bindDirectly()` at start.
3. **Two guests in `NativeRuntime`:**
   - `guest`, the app: a `NativeGuest` that calls the exports it's given,
     `native.start(rt_main, dispatch: rt_dispatch, finalize: rt_finalize)`;
   - `host`, the host's Swift layer: a `HostGuest` whose `dispatch` calls
     `Exported.dispatch` directly. It isn't limited by the app's
     capabilities.
4. **The test**, `Packages/LinkedSlice`, links `ExampleApp`'s sealed macOS
   slice into a host built with the trait off. With the trait on, SwiftPM's
   native build system fails the same link with duplicate symbols; Swift
   Build, the default, lists them but doesn't fail.

## 2. Platform minimums

**Problem.** `Package.swift` declared macOS 15 / iOS 18, because of WasmKit,
and SwiftPM rejects a dependency whose minimum is higher than its client's.

**Landed, with two differences:**

- **The minimums are iOS 15 / macOS 12**, not iOS 13 / macOS 10.15. Xcode's
  SDK deprecates `.v13` and `.v10_15`: they're no longer valid deployment
  targets. The Darwin host targets iOS 15 / macOS 12 too. The slices are
  still stamped iOS 13 / macOS 10.15, so they load on everything the host
  supports.
- **WasmKit moved to its own package**, `Packages/RuntimeWasm` (macOS 15 /
  iOS 18), which depends on AppRuntime by path. A trait wasn't enough:
  SwiftPM rejects WasmKit's product at the lower minimum even behind a
  trait. A nested package can't be a URL dependency, though, so how
  `DarwinWasmHost` reaches it is still open (`HostRuntime.md` §11).

The shared modules build at the new minimums without changes.

## 3. Built-in contracts

§7.4 listed `Permissions` and `Bundle` as built-ins, but neither existed,
and the Darwin host also needs to tell the guest about the app's lifecycle.

**Landed**, as `@DynamicRuntime` protocols in `DynamicRuntime`. Their
descriptors are in `BuiltinContracts`, and `HostRuntime` registers them at
start, so they resolve before the host registers its implementations. Until
then, calls fail with `.notFound`, and every method throws `RuntimeError`.
Contracts in the `org.pureswift.runtime.` namespace get no `rt.contracts`
record, since every host provides them.

| Contract | Swift | Methods |
|---|---|---|
| `Permissions` | `Permissions` | `status(_ capability: Capability) -> Int32` (`PermissionStatus`), `request(_:delegate:)`; delegate: `didRequest(_:status:)` |
| `Bundle` | `AppBundle` | `identifier()`, `version()`, `build()`, `preferredLanguages() -> [String]`, `localizedString(_:table:) -> String?` |
| `Application` | `Application` | `make(_ delegate:)`, `state() -> Int32` (`ApplicationState`); delegate: `didChangeState(_:state:)`, `didReceiveMemoryWarning(_:)`, `open(_:url:) -> Bool` |

Differences from the proposal:

- `Bundle` is `AppBundle` in Swift, so a host that imports Foundation can
  still write `Bundle`.
- The delegates take their object first, like the provider contracts'
  delegates.
- `ApplicationState`'s raw values match `UIApplication.State`.

## 4. iOS Simulator slices

**Problem.** `ios-arm64` slices are stamped for iOS devices, and the
simulator's linker rejects them, so a simulator build had to fall back to
wasm2c.

**Landed:** `guest.py`'s `ios-simulator` target, arm64 and x86_64 in one
archive, stamped `PLATFORM_IOSSIMULATOR` (7), minimum 13.0. It's part of the
`ios` group.

- arm64 is compiled for `arm64-apple-none-macho`, like the other Apple slices.
- x86_64 has no simulator stdlib, so it's compiled for macOS, and
  `guest.py` rewrites each object's `LC_BUILD_VERSION` before sealing.

The arm64 slice ran in the iOS Simulator. The x86_64 one links, but hasn't
run: simulators on Apple silicon run arm64.

## 5. Manifest stage

`ManifestPackager.md` §1, landed:

- `AppManifest`, a full-Swift library for the build machine with no
  dependencies;
- `guest.py bundle --manifest App.swift`, which compiles and runs the
  manifest sandboxed and runs the checks in §1.2;
- the `Info.plist` keys `RTPlatforms`, `RTCapabilityUsage`, `RTIcon` and
  `RTPlatformExtras`, plus `RTCapabilityOptions` and `RTDisplayNameKey`,
  which the proposal didn't have;
- `resources/<language>.lproj/Manifest.strings`;
- the `rt.manifest` section in every slice, and in `App.wasm`.

`AppManifest` also has what the packager reads beyond the proposal
(`ManifestPackager.md` §1.3): `.required()`, `.notifications(remote:)`,
`.motion`, `.nfc` and `.localNetwork`, and `apple.privacy`.

## 6. A shared wasm2c import shim

Every host without a native slice translates `App.wasm` to C and needs the
same import shim. Generating it once, from `rt.h`, saves each host writing
its own.

**Landed:** `Scripts/wasm2c-shim.py`.

- `shim` generates the shim from `rt.h`, plus a minimal WASI preview 1.
- `build` translates `App.wasm`, compiles it with the shim, and seals the
  result into a `libapp.a` with the same exports, imports and metadata
  sections as a native slice. `--define` passes C macros to the build;
  `RT_WASM2C_WRITE_FUNCTION=name` sends the guest's stdout and stderr to a
  host function, which this host uses to log them.

It targets WABT's wasm2c, not w2c2, whose generated API differs.
`Packages/LinkedSlice` runs `ExampleApp` and `ExampleUI` both as native
slices and through it, with the same checks.
