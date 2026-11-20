# Darwin host runtime — Design

**Status:** implemented, with these differences from the design below:

- **Modules** are `HostModule`s: each lists its contracts, registers its
  implementations, and answers `Permissions` for the capabilities its
  framework gates. `AppHost` registers only the modules whose contracts
  the app uses.
- **One window** shows the guest's first renderer (`RendererScenes`). A
  scene per renderer is still open (§11).
- **`requestAlwaysAuthorization`** checks the status first and asks iOS
  for the when-in-use → always upgrade once per install (iOS shows that
  prompt once). Every request gets an answer: when no prompt appears, or
  the user keeps when-in-use, the current status is reported after the
  prompt closes.
- **Hardware paths** (Bluetooth, NFC, motion, location fixes) are tested
  through their mappings and fake delegates; they haven't run on a device.

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
| iOS 15+ on device (`ios-arm64` slices) and in the Simulator (`ios-simulator` slices, arm64 and x86_64), macOS 12+ (`macos` slices, arm64 and x86_64) | iOS 6 armv7: Swift-iOS6's backend is a separate host |
| The Swift-registry backend: contracts implemented in Swift | The ObjC backend (§6): native-class bindings through `objc_msgSend`, for apps that call UIKit directly |
| Every contract AppRuntime declares today | tvOS, watchOS, visionOS: the slices exist; the hosts follow once iOS works |

iOS 15 and macOS 12 are the oldest deployment targets current Xcode
accepts, and AppRuntime's own minimums. `guest.py` stamps the slices lower
(`ios-arm64` and `ios-simulator` for iOS 13.0, `macos` for 10.15 / 11.0),
so every slice loads on every OS the host supports.

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
| **Native slice** | The bundle has a slice for the platform | iOS device, iOS Simulator, macOS | The packager links `libapp.a`. It's the fastest, and needs no translation. |
| **wasm2c** | No native slice: apps shipped without one for the platform | Everywhere | The packager runs AppRuntime's `Scripts/wasm2c-shim.py build`, which translates `App.wasm` to C with WABT's wasm2c and seals it, behind a generated `rt` import shim, into a `libapp.a` the host links like a slice. No interpreter ships, so App Store builds can use it (§14). |
| **WasmKit** | Development: hot reload and loading a new `App.wasm` without relinking | macOS 15+, iOS 18+ (WasmKit's own minimums) | Never in App Store builds. It lives in a separate package (`DarwinWasmHost`), since SwiftPM rejects a dependency whose minimum is higher than its client's (§11). |

All three use the same runtime core: the same handle table, contracts and
renderer. Only what implements `rt_dispatch` and the imports differs:

- **native:** the C symbols are direct calls;
- **wasm2c:** the generated shim copies between guest memory and the host
  with bounds checks, like `RuntimeWasm`'s import shim but in C, and
  exports the same `rt_main` / `rt_dispatch` / `rt_finalize` as a slice;
- **WasmKit:** `RuntimeWasm`.

## 3. Modules

One Swift package, `DarwinAppRuntime`, with a minimum of iOS 15 / macOS 12.
It depends on AppRuntime without the `GuestExports` trait (§8):

| Module | Contents |
|---|---|
| `DarwinHost` | Startup, bundle checks, engine selection, lifecycle, `HostClock`, the main-thread executor for callbacks, and the built-in contracts the core doesn't serve (`Permissions`, `AppBundle`, `Application`; §6) |
| `DarwinBluetooth` | `BluetoothCentral` and friends over CoreBluetooth |
| `DarwinLocation` | `LocationManager` over CoreLocation |
| `DarwinMotion` | `MotionManager`, `Pedometer`, `Altimeter`, `ActivityRecognizer` over CoreMotion |
| `DarwinNFC` | `NFCReader` over CoreNFC (iOS only) |
| `DarwinDevice` | `Device` over UIDevice, ProcessInfo and IOKit (macOS) |
| `DarwinNetworking` | `HTTPSession` over URLSession |
| `DarwinUI` | The SwiftUI player (`SwiftUIRenderer.md`) |
| `DarwinGraphics` | `Surface` over EAGL (iOS) and desktop OpenGL (macOS), and the `GLSurface` views (§5.2) |
| `DarwinWebKit` | `WebContent` over `WKWebView`, and the `WebView` views (§5.3) |
| `DarwinFiles` | `Files`: AppRuntime's `HostFiles` over the app container's directories (§5.4) |
| `DarwinDefaults` | `Defaults`: AppRuntime's `HostDefaults` over a `UserDefaults` suite (§5.5) |
| `DarwinModelStore` | `ModelStore`: AppRuntime's `HostModelStore` over CoreModel's Core Data store (§5.6) |
| `DarwinDocuments` | `Documents`: AppRuntime's `HostDocuments` over the platform's pickers and bookmarks (§5.7) |
| `CDarwinGL` | The `gl*` functions the app's executable defines over the system's, and the host's own GL calls (§5.2) |
| `DarwinHostApp` | The app's `main`: a SwiftUI `App`. It registers AppRuntime's `RuntimeFormatting` too (§5.1) |
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
   - `NativeRuntime.shared`, for the native and wasm2c engines, which both
     link a `libapp.a`; or a `WasmApp` over the same `HostRuntime` for
     WasmKit;
   - `native.bindDirectly()`, so the host's own proxies and exports bypass
     the C symbols (§8);
   - `capabilities` set from `RTCapabilities`.

   `rt_class` returns `0` for a contract whose capability the manifest
   doesn't declare (§7.3).
4. **Register the built-ins:**
   - `Clock`, served from a `HostClock` (§6);
   - `Permissions`, `AppBundle` and `Application`, with the generated
     helpers (`PermissionsProxy.register(DarwinPermissions.self, in: native)`);
   - `List`, `String` and `Bytes`, which `HostRuntime` serves itself.
5. **Register the contract implementations** for the contracts the app
   uses, from `RTContracts`. Contracts it doesn't use aren't registered, so
   the guest can't resolve them (§14's allowlist).
6. **Call `rt_main`** inside an `@autoreleasepool`, with the library's
   exports: `native.start(rt_main, dispatch: rt_dispatch, finalize:
   rt_finalize)`. The guest sets up and
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
BluetoothCentralProxy.register(DarwinCentral.self, in: native)
BluetoothCentralDelegateProxy.registerInterface(in: native)
```

A delegate the guest passes in arrives as a proxy (`any BluetoothCentralDelegate`),
and the implementation calls it like any Swift object. The contract
documents in AppRuntime (`Documentation/Contracts/*.md`) define the
behavior. These rules apply across all of them:

- **Permissions first.**
  - The static `authorizationStatus()` never prompts. `make` never prompts
    either. The `request…` call is the only prompt.
  - Some frameworks prompt as a side effect, so their implementations
    create the framework object lazily. **Creating a `CBCentralManager`
    prompts for Bluetooth.** `DarwinCentral` doesn't create one until
    `requestAuthorization()`, or until `CBManager.authorization` says access
    is already decided. Until then, `state()` reports `unknown`.
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
| `BluetoothCentral`, `BluetoothPeripheral`, … | CoreBluetooth | `BluetoothUUID` strings in any of the three forms (16-bit, 32-bit, 128-bit) map to `CBUUID`. `BluetoothPeripheral.identifier` is `CBPeripheral.identifier`; there is no MAC address. Scan modes map to `CBCentralManagerScanOptionAllowDuplicatesKey` (iOS has no power modes). `ScanMode` is accepted and ignored. Connection timeouts are enforced by the implementation with a main-queue timer, since CoreBluetooth has none. |
| `LocationManager` | CoreLocation | Accuracy constants map to `kCLLocationAccuracy…`. `requestFullAccuracy` uses `requestTemporaryFullAccuracyAuthorization(withPurposeKey:)`. |
| `MotionManager`, `Pedometer`, `Altimeter`, `ActivityRecognizer` | CoreMotion | Timestamps are converted to host monotonic nanoseconds (`Clock.now`). On macOS, `isAvailable` is false for most sensors. |
| `NFCReader` | CoreNFC | iOS only; on macOS the contract isn't registered, so `rt_class` returns `0`. An `NFCTagReaderSession` or `NFCNDEFReaderSession` is chosen by the requested tag types. The manifest's declared formats limit which sessions the entitlement allows. |
| `Device` | UIDevice, ProcessInfo; IOKit / IOPowerSources on macOS | Battery and orientation monitoring are on only while the guest asks for them. `vendorIdentifier` is `identifierForVendor` (`nil` on macOS). |
| `HTTPSession` | URLSession | One `URLSession` per contract session, whose delegate dispatches to the task delegates. Redirects and challenges ask the guest synchronously, on the main thread. |
| `LocaleInfo`, `NumberFormat`, `DateFormat` | Foundation, through AppRuntime's `RuntimeFormatting` | AppRuntime's `HostFormattingModule`, which the Linux host shares; this host has no formatting code of its own. Formatters are cached per locale, style and options. What a guest asks for that the contracts don't know, such as an unknown style or time zone, is replaced (decimal, the style left as it was, the user's time zone) and logged through `HostFormattingModule.log`. |
| `Surface` | OpenGLES (iOS), OpenGL (macOS) | §5.2. |
| `Files` | POSIX, through AppRuntime's `HostFiles` | §5.4. |
| `Defaults` | `UserDefaults`, through AppRuntime's `HostDefaults` | §5.5. |
| `ModelStore` | Core Data, through CoreModel's `CoreDataModel` and AppRuntime's `HostModelStore` | §5.6. |
| `Documents` | UIKit's document picker (iOS), `NSOpenPanel` and `NSSavePanel` (macOS), through AppRuntime's `HostDocuments` | §5.7. |
| `WebContent` | WebKit | §5.3. |

### 5.2 Graphics

`DarwinGraphics` implements `Surface` (AppRuntime's
`Documentation/Contracts/Graphics.md`, `DynamicRuntime.md` §8). The guest
calls OpenGL ES 2.0 itself: a native slice and wasm2c output both reference
the `gl*` symbols, and the app's executable links them, to
OpenGLES.framework on iOS and OpenGL.framework on macOS.

- **The surface.** `make` keeps the delegate and creates nothing. When a
  `GLSurface` node with the surface's `identifier()` appears, `DarwinUI`
  asks `GLSurfaceViews.provider`, which `DarwinGraphics` sets when it's
  registered, for the view. The first view makes the GL context, which then
  lives as long as the surface, so the guest's GL objects survive the view
  leaving and coming back. A second view showing the same surface takes it
  over.
- **iOS.** A `CAEAGLLayer` drawn by an `EAGLContext` through a framebuffer
  object with a 24-bit depth and 8-bit stencil buffer, at the screen's
  scale. A `CADisplayLink` drives frames.
- **macOS.** An `NSOpenGLView` on a legacy-profile context: desktop
  OpenGL 2.1, which has every GLES 2.0 function. Point sprites are on, as in
  GLES. A display link drives frames (a 60 Hz timer before macOS 14).
- **Frames** run while the view is in a window and the app is active.
  `resize` comes before the first frame of a new size, in pixels, with the
  scale. Each frame makes the context current, calls `frame`, presents and
  restores the context. Timestamps are `mach_continuous_time`, as
  `Clock.now()`. Contexts are never lost on these platforms, so
  `contextLost` isn't sent.
- **Input** (§8.6). Positions are pixels from the top left.
  - iOS: touches (IDs from 1), the pencil (`pen`), an iPad's pointer
    (`mouse`, ID 0, with its buttons and hovering), trackpad and wheel
    scrolling, and a hardware keyboard: `UIKey.keyCode` is a HID usage
    already. UIKit doesn't repeat presses. There's no pointer capture.
  - macOS: the mouse (ID 0; a second button is a `move` with the new
    buttons), the scroll wheel (lines are 16 points), and keys, mapped from
    `kVK_…` codes to HID usages; modifier keys come from `flagsChanged`.
    `setPointerCaptured` hides the cursor and holds it still, and mouse
    movement becomes `pointerDelta`.
  - Moves wait for the next frame, one per pointer, and captured movement
    is summed. Other events go at once, after their pointer's waiting move.
  - The view takes keyboard focus when it appears and when touched or
    clicked. Focus goes with the first responder, the key window on macOS,
    the app being active and the view being on screen. Before it goes,
    every pointer in contact gets `cancel`, and capture ends.
- **GLES 2.0 differences** are covered in `CDarwinGL`, by defining the
  `gl*` function in the executable, which wins over the framework's:
  - **Framebuffer 0** is the surface's: iOS has no default framebuffer,
    and AppKit may draw a layer-backed view into a framebuffer object.
    `glBindFramebuffer(_, 0)` binds the surface's during a frame.
  - **GLSL ES on macOS.** GLSL 1.20 rejects precision statements and
    `#version 100`, so `glShaderSource` blanks them and the `lowp`,
    `mediump` and `highp` qualifiers first. Line numbers stay the same.
  - `rt_gl_context_generation`, which the wasm2c shim asks, is the current
    context's own number, so switching between two surfaces counts as a
    new context.

### 5.3 Web views

`DarwinWebKit` implements `WebContent` over `WKWebView` (AppRuntime's
`Documentation/Contracts/WebKit.md`).

- **The page.** `make` creates the `WKWebView`, off screen, and keeps the
  delegate. When a `WebView` node with the page's `identifier()` appears,
  `DarwinUI` asks `WebViews.provider`, which `DarwinWebKit` sets when it's
  registered, for a view; the page's web view moves into it. When the node
  goes, the web view leaves and the page keeps loading, with its history
  and scroll position. A second node showing the page takes the web view.
  Releasing the `WebContent` stops and removes it.
- **The delegate.** Key-value observing reports `url`, `title`,
  `canGoBack` and `canGoForward` when they change, and `estimatedProgress`
  while loading. `didFinish` reports `didChangeLoading(false, 1)`, then
  `didFinishNavigation`; `didFail` and `didFailProvisionalNavigation`
  report `didFailNavigation`, then the loading state. A load that ends
  otherwise (stopped, refused, or replaced by another) reports only the
  loading state. The title can come just after `didFinishNavigation`.
- **Navigations.** `decidePolicyFor` asks `shouldNavigate` and answers with
  the guest's reply. The navigation the guest just started (`load`,
  `loadHTML`, `loadResource`, `reload`, `goBack`, `goForward`) isn't asked
  about. New windows load in the same page. If the web content process
  ends, the page reloads.
- **Without `network`:** `load` of an `http`, `https`, `ws` or `wss` URL
  fails at once with `notPermitted`, as does a page's navigation to one,
  without asking. A content rule list blocks remote subresources. It's
  compiled once; until it's ready, a page's loads wait.
- **`load`** refuses `file:` URLs (`badURL`): files come from
  `loadResource`, which resolves the path in the app's resources, refuses
  one that leaves them, and lets the page read the file's directory.
- **Scripts.** `evaluateJavaScript`'s value becomes JSON text with
  `JSONSerialization` (fragments allowed, keys sorted, dates as ISO 8601
  strings, as `JSON.stringify` writes them). `undefined` and functions are
  `nil`; an exception's message is the error.
- **Errors.** `NSURLErrorDomain` codes map to `network`, `timedOut`,
  `security` (certificates and App Transport Security) and `badURL`, and
  WebKit's "can't show URL" to `badURL`. A cancelled navigation, or one a
  policy refused, isn't a failure.
- **Dialogs.** `alert`, `confirm` and `prompt` show a `UIAlertController`
  (iOS) or a sheet (macOS); a page that isn't on screen gets the answer of
  a dismissed dialog. Camera and microphone requests are denied.

### 5.4 Files

`DarwinFiles` registers AppRuntime's `HostFiles` for `Files` (AppRuntime's
`Documentation/Contracts/Files.md`). `HostFiles` does the work with POSIX
calls on a serial queue. `DarwinFiles` says where the directories are, and
answers on the main queue inside an autorelease pool.

| `FileDirectory` | In a sandbox | Without one (macOS) |
|---|---|---|
| `documents` | `Documents` | `Library/Application Support/<bundle ID>/Documents` |
| `data` | `Library/Application Support` | `Library/Application Support/<bundle ID>/Data` |
| `caches` | `Library/Caches` | `Library/Caches/<bundle ID>` |
| `temporary` | the container's `tmp` | `<bundle ID>` in `NSTemporaryDirectory()` |
| `bundle` | the app's resources | the app's resources |

- **In a sandbox**, which is every iOS app and every packaged macOS app,
  the home directory is the app's container, so the paths are inside it.
- **Without a sandbox**, as in a development run on macOS, the home and
  temporary directories are the user's, and other apps share them. Each
  directory is the app's own there, so the app doesn't write to the user's
  Documents, and emptying `temporary` at start doesn't remove other apps'
  files.
- **When it's registered**, `DarwinFiles` makes the writable directories
  and empties `temporary`. If that fails, it logs the error, and every
  operation fails with `notFound`.
- `bundle` is the resources the packager copied into the app, the same
  directory `loadResource` reads web pages from.
- `documents` isn't shown in the Files app: that needs a manifest option
  for file sharing, which doesn't exist yet.

### 5.5 Defaults

`DarwinDefaults` registers AppRuntime's `HostDefaults` for `Defaults`
(AppRuntime's `Documentation/Contracts/Defaults.md`). `HostDefaults`
refuses empty keys and sorts the keys. `DarwinDefaults` gives it the
store, `UserDefaultsStorage`:

- **A suite of the app's own**, `<bundle identifier>.defaults`, apart from
  the host's standard defaults. A suite can't have the app's own name,
  since that's the standard defaults.
- **Reads see only the suite's own values** (`persistentDomain(forName:)`).
  A plain `UserDefaults` lookup also searches the global domain and the
  command line's arguments, which would show the app values it never set,
  such as `AppleLanguages`.
- **Strings are stored as strings, and bytes as `Data`**, so `defaults
  read` shows them as they are. A value of another kind, written by
  something other than the app, reads as missing.
- **A value over 64 KB is refused**, and the old value stays.
- `UserDefaults` keeps what's set across launches. Without a sandbox, the
  suite is in the user's `Library/Preferences`, named for the app as it
  is in a sandbox.

### 5.6 Model store

`DarwinModelStore` registers AppRuntime's `HostModelStore` for the model
store's contracts (AppRuntime's `Documentation/Contracts/Persistence.md`).
`HostModelStore` checks the guest's schemas, requests and records against
the model, runs each store's operations in order off the main thread, and
answers on the main queue, inside an autorelease pool. `DarwinModelStore`
gives it the stores, `CoreDataStores`: each one CoreModel's Core Data store,
an `NSPersistentContainer` on a SQLite file.

| | In a sandbox | Without one (macOS) |
|---|---|---|
| A store | `Library/Stores/<name>/Store.sqlite` | `Library/Application Support/<bundle ID>/Stores/<name>/Store.sqlite` |

- **Beside the file directories, not in one** (§5.4): the app's own files
  can't reach a store, or make a folder that collides with one. `Library`
  is backed up. On iOS the files are protected until the first unlock.
- **Each store keeps its model.** An app's model is built at run time, and
  Core Data migrates a store only from the model it was made with. So the
  `Model` and indexes a store was opened with are kept in its metadata, as
  JSON in the managed object model's version identifiers.
- **Opening with another model** migrates the store with a mapping Core
  Data infers, when AppRuntime's `canMigrate(from:to:)` says what the two
  models share is the same: added and removed entities and properties.
  Otherwise `open` fails with `migrationRequired`, or empties the store for
  `.reset`. A store with no model in its metadata is treated the same way.
- **Indexes** become Core Data fetch indexes.
- **A file that isn't a store** is `corrupted`, and a full disk is
  `outOfSpace`, when the store is opened.
- **Opening a store again with the same model** shares its container.
  Opening it with another, or destroying it, closes the one open before.

What's CoreModel's, and so not the contract's yet:

- Results without a sort, and objects that sort equal, come in Core
  Data's order, not in order of their IDs.
- An offset without a limit, and `IN` with a string (which the contract
  reads as "is a substring of"), raise exceptions in Core Data.
- A batch's changes are applied one after another, so one that fails
  leaves those before it.

### 5.7 Documents

`DarwinDocuments` registers AppRuntime's `HostDocuments` for the documents
contracts (AppRuntime's `Documentation/Contracts/Documents.md`).
`HostDocuments` makes each document the user gives a grant in `HostFiles`,
so the guest's `FileManager` reaches it, ends the grant when the guest
lets go, and shows one picker at a time. `DarwinDocuments` gives it the
pickers and bookmarks, `DarwinPickers`:

| | iOS | macOS |
|---|---|---|
| Open | `UIDocumentPickerViewController(forOpeningContentTypes:asCopy: false)`: the file where it is | `NSOpenPanel`, as a sheet on the app's window |
| Folder | the same, for `.folder` | `NSOpenPanel` choosing directories |
| Save | `forExporting:asCopy: false` on a copy the host makes, which moves the copy where the user says and gives its URL back | `NSSavePanel`, then `HostFiles.copy(file:to:)` over what's there |
| Bookmark | `bookmarkData()` | an app-scoped security bookmark |

- **Types.** The wire's MIME types, groups and extensions become
  `UTType`s. A type the system doesn't know is a dynamic one for its tag;
  one that isn't any of the three forms widens the picker to any file.
- **Security scopes.** A picked URL's scope starts when it's handed to
  `HostDocuments`, and stops when the guest lets go of the document.
- **Writable** is what the app asked for, where the file allows it. A
  file the app is opened with is as writable as the file is.
- **Bookmarks** are kept in the host's standard defaults, under
  `RTDocumentBookmarks`, by a UUID the guest holds: not in the guest's
  `Defaults` suite, which the app can read and clear. A stale one is made
  again when it's resolved. A bookmark whose file is gone is `notFound`;
  one that no longer resolves is `notPermitted`.
- **Opened with a file.** The app's `onOpenURL` hands a file URL to
  `DarwinDocuments.open`, and a link to `Application` as before.

The packager:

- **`userFiles`** adds `com.apple.security.files.user-selected.read-write`
  and `com.apple.security.files.bookmarks.app-scope` to a macOS app's
  sandbox. It adds nothing on iOS, and prompts for nothing.
- **`RTDocumentTypes`** becomes `CFBundleDocumentTypes`, with the role and
  `LSHandlerRank` `Alternate`, so the app is offered for those files
  without claiming them. On iOS, `LSSupportsOpeningDocumentsInPlace` too. A
  type the system doesn't know is declared in `UTImportedTypeDeclarations`
  as `<bundle ID>.type.<tag>`. A localized type name goes in
  `InfoPlist.strings`, keyed by the development language's name.

Not done: iOS file coordination around reads and writes, which the
contract's iOS notes ask for. `HostFiles` reads and writes with POSIX
calls.

## 6. Built-in contracts

- **`Clock`.** `HostClock` is implemented with `mach_continuous_time()`
  for `now`, and `DispatchQueue.main.asyncAfter` for `schedule`. Timers keep
  running while the app is suspended and fire late, which matches "after at
  least". Because the host reads system boot time, its privacy manifest has
  to declare it (`ManifestPackager.md` §6).
- **`Permissions`, `Bundle`, `Application`.** AppRuntime declares them in
  `DynamicRuntime` (`Bundle` is `AppBundle` in Swift, so `DarwinHost` can
  still write `Bundle` for Foundation's), and `HostRuntime` registers their
  descriptors. `DarwinHost` registers the implementations:
  - `Permissions` maps each capability to its framework's authorization
    (`CBManager.authorization`, `CLLocationManager`, `AVCaptureDevice`,
    `UNUserNotificationCenter`, …). A capability the manifest doesn't
    declare is `denied`; one the device lacks is `unavailable`.
  - `Application` reports lifecycle (active, inactive, background, the
    raw values of `UIApplication.State`), memory warnings and opened URLs.
    A guest has no other way to learn about these.
  - `AppBundle` serves the app's id, version, build, preferred languages
    and localized strings, from `Bundle.main`. Its resources are the
    bundle's `.lproj` folders, copied into the app.

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

AppRuntime solves both (`AppRuntimeChanges.md` §1):

- The host depends on AppRuntime with `traits: []`, which leaves out the
  `GuestExports` trait, so its `DynamicRuntime` defines no `rt_*` exports.
- `native.bindDirectly()` binds the host's `DynamicRuntime` to the
  `HostRuntime` in-process, as `native.host` (a `HostGuest`, whose
  `dispatch` calls `Exported.dispatch` in Swift).
- The app keeps the C symbols: `native.start(rt_main, dispatch:
  rt_dispatch, finalize: rt_finalize)` gives `NativeGuest` the slice's
  exports.

One `HostRuntime` then serves two guests, the app and the host's own Swift
layer, each with its own context numbers. AppRuntime's `Packages/LinkedSlice`
tests exactly this setup.

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
    (§2.4). AppRuntime's `Packages/LinkedSlice` already runs `ExampleApp`
    and `ExampleUI` both as slices and through wasm2c.
- **UI.**
  - XCUITest on the simulator drives `ExampleUI` through the accessibility
    identifiers it puts in the IR.
  - Player unit tests run without a guest (`SwiftUIRenderer.md` §10).

## 11. Open questions

- **Where `RuntimeWasm` lives.** AppRuntime moved its WasmKit engine to a
  nested package, `Packages/RuntimeWasm`, to keep WasmKit's minimums out of
  the root package. SwiftPM can only depend on a repository's root package
  by URL, so `DarwinWasmHost` can't reach it as it stands: it would have to
  use a local path (a checkout next to this one), or `RuntimeWasm` would
  move to a repository of its own.

- **ObjC backend.** Apps that call UIKit directly need a native-binding
  layer (§6, §14), which brings App Review risk and doesn't fit the
  allowlist model. It's probably best as a separate, opt-in package.
- **Background modes.** Bluetooth and location in the background need
  `UIBackgroundModes` and contract support for state restoration. The
  Bluetooth contract deliberately left state restoration out.
- **Multiple windows.** iPad scenes and macOS windows would each need their
  own renderer instance. The `Renderer` contract allows that: a guest can
  call `Renderer.make` once per scene. Telling the guest about scenes needs
  scene events, which the `Application` contract doesn't have yet.
