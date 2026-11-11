# Changes needed in AppRuntime

**Status:** proposed. The Darwin host can't be built as designed until
these land in PureSwift/AppRuntime. Each one also serves the Android and
Linux hosts.

## 1. Host builds of `DynamicRuntime`

**Problem.** A host links the app's sealed `libapp.a` together with its own
Swift code, which uses `DynamicRuntime` for delegate proxies and for
exporting host objects (`HostRuntime.md` §8). Today:

- `DynamicRuntime` defines the global `rt_dispatch` and `rt_finalize`
  (`Exported.swift`), and so does every slice: a duplicate symbol.
- Host objects are exported through the C `rt_implement` the guest also
  calls, so `HostRuntime` can't tell host contexts from guest contexts, and
  both sides number theirs from 1.
- `NativeGuest` dispatches everything through the C `rt_dispatch`.

AppRuntime's own tests don't hit this, because the test guest is compiled
into the same process as the host, with one `DynamicRuntime`.

**Change.**

1. **A package trait, `GuestExports` (on by default),** controls
   `DynamicRuntime`'s `@c(rt_dispatch)` / `@c(rt_finalize)`. Hosts depend on
   AppRuntime with the trait off; guests and AppRuntime's own tests keep it.
2. **A runtime binding.** `DynamicRuntime`'s calls go through
   `RuntimeBinding`: the C `rt_*` functions by default, or a direct binding
   to an in-process `HostRuntime`. A host sets the direct binding at start.
   The host's proxies and exports then never touch the C symbols.
3. **Two guests in `NativeRuntime`:**
   - the app, whose `dispatch` calls the slice's `rt_dispatch`, and which
     the C `rt_*` symbols serve;
   - the host's Swift layer, whose `dispatch` calls `Exported.dispatch`
     directly, and which the direct binding serves.

   `HostRuntime` already keys an `Implementation` by its `Guest`, so
   contexts stay separate.
4. **A test** that links a sealed slice built by `guest.py` (for example
   `ExampleApp` for the build machine) into a test executable, next to a
   host-mode `DynamicRuntime`. It proves the duplicate symbols and the
   mixed routing are gone.

## 2. Platform minimums

**Problem.** `Package.swift` declares macOS 15 / iOS 18, because of
WasmKit. A host package with lower minimums can't depend on it: SwiftPM
rejects a dependency whose minimum is higher than the client's. The Darwin
host targets iOS 13 / macOS 10.15, the same as the slices.

**Change.**

1. Lower the package to iOS 13 / macOS 10.15.
2. Put WasmKit and `RuntimeWasm` behind a package trait (`Wasm`, on by
   default), or move them to their own package. Hosts that ship only native
   and wasm2c engines don't depend on WasmKit; the development interpreter
   (`DarwinWasmHost`) does, at iOS 18 / macOS 15.
3. Audit the core modules for newer APIs:
   - `RuntimeCore`, `RuntimeNative`, `DynamicRuntime`, the contract modules,
     `DynamicUI`, `DynamicObservation`.
   - Swift Concurrency back-deploys to iOS 13 / macOS 10.15, `TaskLocal`
     included.

## 3. Built-in contracts

§7.4 lists `Permissions` and `Bundle` as built-ins, but neither exists.
The Darwin host also needs a way to tell the guest about the app's
lifecycle. Add these, like `Clock`: descriptors in `BuiltinContracts` and
guest-side wrappers in `DynamicRuntime`:

| Contract | Methods | Why |
|---|---|---|
| `Permissions` | `status(capability) -> Int32`, `request(capability, delegate)` | One way to ask for any capability (§7.4). The per-contract `request…` methods stay, for contract-specific options. |
| `Bundle` | `identifier()`, `version()`, `build()`, `preferredLanguages() -> [String]`, `localizedString(key, table) -> String?` | The guest reads its metadata and strings through the host, never from files (§7.4). |
| `Application` | `make(delegate)`, `state() -> Int32`; delegate: `didChangeState(state)`, `didReceiveMemoryWarning()`, `open(url) -> Bool` | Foreground, background and memory warnings; deep links. |

## 4. iOS Simulator slices

**Problem.** `ios-arm64` slices are stamped for iOS devices, and the iOS
Simulator rejects them, so a simulator build always falls back to wasm2c.

**Change.** `guest.py` adds `ios-simulator`: arm64 and x86_64 in one
archive, compiled for `arm64-apple-none-macho` / `x86_64-apple-macos`
like the other Apple slices, and stamped with the simulator platform
(`PLATFORM_IOSSIMULATOR`, 7) at seal time.

## 5. Manifest stage

`ManifestPackager.md` §1:

- an `AppManifest` library (full Swift, for the build machine);
- `guest.py bundle --manifest App.swift`, which compiles and runs the
  manifest sandboxed and runs the checks in §1.2;
- the new `Info.plist` keys (`RTPlatforms`, `RTCapabilityUsage`, `RTIcon`,
  `RTPlatformExtras`) and `resources/<language>.lproj/Manifest.strings`;
- the `rt.manifest` section in every slice (§10 lists it, but slices don't
  have it yet).

## 6. A shared wasm2c import shim

Every host without a native slice translates `App.wasm` with wasm2c and
needs the same import shim: guest offsets to pointers for each `rt_*`
import, plus the guest's allocator exports. `HostRuntime.md` and the
Android and Linux hosts would otherwise each write it. Generate it once,
from `rt.h`, in AppRuntime (`Scripts/wasm2c-shim.py`), along with a minimal
WASI preview 1, and test it against `ExampleApp` and `ExampleUI` the way
the WasmKit shim is tested.
