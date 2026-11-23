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
| `DarwinNotifications` | `Notifications` and `PushNotifications`: AppRuntime's `HostNotifications` over `UNUserNotificationCenter` and APNs (§5.8) |
| `DarwinMedia` | `MediaPlayback`: AppRuntime's `HostMediaPlayback` over `AVPlayer`, what's playing in `MPNowPlayingInfoCenter`, and the `VideoPlayer` views (§5.9) |
| `DarwinBackgroundTasks` | `BackgroundTasks`: AppRuntime's `HostBackgroundTasks` over `BGTaskScheduler` (iOS) and `NSBackgroundActivityScheduler` (macOS) (§5.10) |
| `DarwinClipboard` | `Clipboard`: AppRuntime's `HostClipboard` over `UIPasteboard` (iOS) and `NSPasteboard` (macOS) (§5.11) |
| `DarwinText` | `TextStorage`: AppRuntime's `HostTextStorage` over `UITextView` (iOS) and `NSTextView` (macOS), and the `TextEditor` views (§5.12) |
| `DarwinSecrets` | `Secrets`: AppRuntime's `HostSecrets` over the Keychain (§5.13) |
| `DarwinAuthentication` | `WebAuthentication`: AppRuntime's `HostWebAuthentication` over `ASWebAuthenticationSession` (§5.13) |
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
| `Documents` | UIKit's document picker and PhotosUI's photo picker (iOS), `NSOpenPanel` and `NSSavePanel` (macOS), through AppRuntime's `HostDocuments` | §5.7. |
| `Notifications`, `PushNotifications` | UserNotifications, and APNs through the app delegate, through AppRuntime's `HostNotifications` | §5.8. |
| `MediaPlayback` | AVFoundation, AVKit and MediaPlayer, through AppRuntime's `HostMediaPlayback` | §5.9. |
| `BackgroundTasks` | BackgroundTasks and UIKit (iOS), Foundation (macOS), through AppRuntime's `HostBackgroundTasks` | §5.10. |
| `Clipboard` | UIKit's and AppKit's pasteboards, through AppRuntime's `HostClipboard` | §5.11. |
| `TextStorage` | UIKit's and AppKit's text views, through AppRuntime's `HostTextStorage` | §5.12. |
| `Secrets` | Security (Keychain Services), through AppRuntime's `HostSecrets` | §5.13. |
| `WebAuthentication` | AuthenticationServices, through AppRuntime's `HostWebAuthentication` | §5.13. |
| `Contacts` | Contacts (`CNContactStore`), through AppRuntime's `HostContacts` | §5.14. |
| `Photos` | Photos (PhotoKit), through AppRuntime's `HostPhotos` | §5.15. |
| `CameraCapture` | AVFoundation (`AVCaptureSession`), through AppRuntime's `HostCameraCapture` | §5.16. |
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
- **Scripts and schemes an app talks to its pages with** (`features()`
  says `userScripts`, `scriptMessages`, `messageReplies` and `urlSchemes`):
  - `make(_:dataStore:options:schemes:)` sets a `WKURLSchemeHandler` for
    each scheme on the configuration before the web view is made, as
    WebKit needs; one `WKWebView.handlesURLScheme` says it loads itself,
    such as `https`, is left to it and logged. A request reaches
    `startURLSchemeTask` with its headers sorted by name, and
    `stopURLSchemeTask` when WebKit stops it; answering a stopped task
    does nothing. A failed request fails the page's load with its
    `WebError.Code`, in the error domain `org.pureswift.web`.
  - User scripts are `WKUserScript`s. A one-way handler is a
    `WKScriptMessageHandler`, and a replying one a
    `WKScriptMessageHandlerWithReply`, both in the page's content world;
    a name is added once. A message's body is JSON text as script results
    are; a reply is parsed back with `JSONSerialization`, and nil resolves
    the page's promise to `undefined`.
  - Releasing the page rejects the replies it owes and fails its tasks.
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
| Photos | `PHPickerViewController`, filtered to images, videos or both, each pick copied to a folder of the host's own | `NSOpenPanel` for `image/*` and `video/*`, AppRuntime's default |
| Save | `forExporting:asCopy: false` on a copy the host makes, which moves the copy where the user says and gives its URL back | `NSSavePanel`, then `HostFiles.copy(file:to:)` over what's there |
| Bookmark | `bookmarkData()` | an app-scoped security bookmark |

- **Types.** The wire's MIME types, groups and extensions become
  `UTType`s. A type the system doesn't know is a dynamic one for its tag;
  one that isn't any of the three forms widens the picker to any file.
- **Security scopes.** A picked URL's scope starts when it's handed to
  `HostDocuments`, and stops when the guest lets go of the document.
- **Writable** is what the app asked for, where the file allows it. A
  file the app is opened with is as writable as the file is.
- **Photos.** The photo picker asks for no access to the library, and
  lends each pick as a file that's gone once its callback returns. The
  host copies the item's own representation, so a HEIC photo stays HEIC,
  to a folder in its temporary directory, named for the item with its
  type's extension. `HostDocuments` makes the copy read-only and refuses
  to bookmark it; letting go of it removes the folder. An item that can't
  be read is left out, and a pick none of which could be is `unknown`. An
  empty pick is a cancel, as the document picker's is. macOS 12 has no
  photo picker, so the open panel shows images and videos there.
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

### 5.8 Notifications

`DarwinNotifications` registers AppRuntime's `HostNotifications` for the
notifications contracts (AppRuntime's
`Documentation/Contracts/Notifications.md`). `HostNotifications` checks
each request, refuses one the user hasn't allowed, and keeps what the user
did until the guest listens. `DarwinNotifications` gives it
`UNUserNotificationCenter`, `DarwinNotificationCenter`:

- **The system keeps and delivers** scheduled notifications, with the app
  closed and after a restart. A moment becomes an interval from now, so a
  change of time zone doesn't move it; calendar parts stay local time.
- **A category's sound and interruption** go on each request, since Apple
  has them per request. Its buttons are a `UNNotificationCategory`, which
  the system keeps across launches. A button opens the app unless it's
  `.background`.
- **64 pending requests**, as iOS keeps; past them `add` fails with
  `limitReached` where iOS would drop the request silently.
- **The delegate.** The app delegate makes `DarwinNotificationCenter` the
  center's delegate before the app finishes launching, so the response
  that launched it reaches the guest. `willPresent` reports the
  notification and answers with the guest's `foregroundPresentation`.
- **Permission.** `Permissions.status(.notifications)` is the status the
  center last read: at launch, whenever the app comes forward, and after
  every request through either contract.
- **Push.** `registerForRemoteNotifications` on `UIApplication` or
  `NSApplication`; the app delegate hands the token, a failure, and a push
  with data only to `DarwinNotifications`. The address is the token in
  lowercase hex. It's the sandbox's in the Simulator, and where the
  embedded provisioning profile says `aps-environment` is `development`.
  A failure for want of the entitlement is `unsupported`, any other
  `unavailable`. A new token while the app runs is a subscription change.
- **`declaresRemote`** is `RTCapabilityOptions.notifications.remote`, and
  the packager adds `aps-environment` for it, as before.

A `.background` button and a push with data only start a closed app in
the background, which starts the guest as any launch does (§5.10); the
packager adds `UIBackgroundModes: remote-notification` for `wakesApp`.
Not done: the time-sensitive entitlement, without which the system shows
a time-sensitive notification as an active one.

### 5.9 Media

`DarwinMedia` registers AppRuntime's `HostMediaPlayback` for the media
contracts (AppRuntime's `Documentation/Contracts/MediaPlayer.md` and
`NowPlaying.md`). `HostMediaPlayback` checks and finds each source, keeps
which player is the app's now-playing one, answers its buttons, and
applies the rules for the background and interruptions. `DarwinMedia`
gives it the platform's side:

- **An `AVPlayer` per player** (`AVMediaEngine`). AVFoundation decodes,
  keeps time and syncs sound to picture on its own threads; the engine
  reads what the player and its item say on the main thread and reports
  it.
  - A URL streams; a file is its path; `loadData`'s bytes are written to a
    temporary file named for their MIME type, since AVFoundation tells
    formats apart by the extension.
  - Waiting at the start of playback, which `AVPlayer` does every time,
    isn't buffering; waiting to minimize stalls is.
  - A pause the engine didn't ask for is the user's, from AVKit's
    controls. The player's change is read after what's queued on the main
    thread, so the background's or an interruption's reason arrives
    first.
  - Seeks are exact (zero tolerance). Rates keep the pitch (`spectral`).
    Looping seeks back to the start at the end, without ending.
  - A file or bytes that won't load are `unsupportedFormat`: AVFoundation
    says only that it stopped. Other failures follow the error's chain:
    URL loading errors are `network`, an HTTP 404 is `notFound`.
  - `canPlay` is `probably` for the formats every host plays, and
    otherwise what `AVURLAsset.isPlayableExtendedMIMEType` says: `maybe`
    for HTTP Live Streaming.
- **A source in the bundle or the app's files** is found through
  `HostFiles`, so `DarwinMedia` configures `DarwinFiles`' directories when
  the app doesn't use `Files` itself.
- **What's playing** (`NowPlayingCenter`) is `MPNowPlayingInfoCenter`,
  filled from what the app said and the player's position, duration and
  rate at each change of state. Artwork is decoded once. The
  `MPRemoteCommandCenter` buttons are enabled as the app offered them, and
  go to `HostMediaPlayback.remote`.
- **The audio session** (iOS) is `playback`: a player takes the sound from
  other apps and plays with the ring/silent switch on silent. It's made
  active before a player that isn't muted plays, and stays active.
  Interruptions and unplugged headphones go to `HostMediaPlayback`, and so
  does the app's move to the background.
- **The background.** With `.audio(background: true)` the packager adds
  `UIBackgroundModes: audio` on iOS, and every player is allowed to go on
  (`audiovisualBackgroundPlaybackPolicy`). `HostMediaPlayback` pauses the
  ones that don't play in the background. A Mac app isn't suspended, and
  its players go on when it isn't in front.
- **`VideoPlayer` nodes** show the player's `AVPlayer` in AVKit's player
  view, `AVPlayerViewController` or `AVPlayerView`, with the platform's
  controls or none, scaled as the node says. AVKit's own now-playing
  updates are off; the host's are the app's.

Not done: a muted player, or one with no sound, still makes the session
active when it plays, so it silences other apps; picture in picture and
AirPlay, beyond what AVKit's controls offer.

### 5.10 Background tasks

`DarwinBackgroundTasks` registers AppRuntime's `HostBackgroundTasks` for
the background contract (AppRuntime's
`Documentation/Contracts/BackgroundTasks.md`). `HostBackgroundTasks`
checks each request against the manifest's tasks, numbers runs and
activities, and remembers repeating requests, in the host's own folder
(`FileLocations.host`, which no `FileDirectory` reaches).
`DarwinBackgroundTasks` gives it the system's scheduler,
`DarwinBackgroundScheduler`:

- **A background launch is a launch.** The guest starts in
  `didFinishLaunching` as always, and its renderer is kept until there's a
  window (`RendererScenes`). `Application.state()` says `.background`.
  The same holds for a `.background` notification button and a push with
  data only.
- **iOS.**
  - The app delegate registers a launch handler for each of the manifest's
    tasks in `willFinishLaunching`, as `BGTaskScheduler` requires, and only
    for identifiers `BGTaskSchedulerPermittedIdentifiers` names:
    registering another is a crash. A handler starts a run, which
    completes the system's task; its `expirationHandler` expires the run.
  - A request is a `BGAppRefreshTaskRequest` or a
    `BGProcessingTaskRequest`, with `earliestBeginDate`, and for processing
    the network and power. The system runs it once, so
    `HostBackgroundTasks` asks again as a repeating one starts.
    `tooManyPendingTaskRequests` is `limitReached`; `unavailable`, which
    is what the Simulator says, is `unsupported`.
  - An activity is `beginBackgroundTask`; its expiration handler tells the
    guest, then ends the system's task. `timeRemaining` is
    `backgroundTimeRemaining`, unlimited while the app is in front.
    `status` is `backgroundRefreshStatus`.
- **macOS.** An `NSBackgroundActivityScheduler` per request runs it while
  the app is open, and repeats it itself. One that runs once is put off
  until its earliest time. Nothing keeps them when the app quits, so the
  repeating ones `HostBackgroundTasks` remembers are scheduled again at
  launch. A Mac app isn't suspended: an activity only keeps the system
  from terminating it (`ProcessInfo.beginActivity`), and never runs out.
- **The packager** writes `BGTaskSchedulerPermittedIdentifiers` from
  `RTBackgroundTasks`, and `UIBackgroundModes`: `fetch` for a refresh
  task, `processing` for a processing task, and `remote-notification` for
  `wakesApp`.

Not done: a request that runs once doesn't survive a Mac app quitting,
and the network and power requirements aren't kept on macOS.

### 5.11 Clipboard

`DarwinClipboard` registers AppRuntime's `HostClipboard` for the clipboard
contract (AppRuntime's `Documentation/Contracts/Clipboard.md`).
`HostClipboard` tells a PNG from a JPEG, reads and writes image files
through `HostFiles` off the main thread, and answers each callback once.
`DarwinClipboard` gives it the general pasteboard, `SystemPasteboard`:

- **Looking** uses what the pasteboard says it holds, which never asks:
  `hasStrings`, `hasURLs` and `hasImages` on iOS, the types on macOS. A
  URL counts as text, since a text read gives its text.
- **Writing** puts one item there. A URL goes with its text, as the
  platform's URL kind and as text.
  - On iOS a sensitive copy is `.localOnly`, kept off the user's other
    devices.
  - On macOS it's marked `org.nspasteboard.ConcealedType`, which clipboard
    managers leave out.
- **Reading on iOS** asks the user, from iOS 16, unless they allowed the
  app in Settings.
  - Each read touches the pasteboard once, so there's one question.
  - A refusal reads as nothing. When the pasteboard said it held the kind,
    that's `notAllowed`.
  - An image is read as PNG or JPEG where it's there as one, and otherwise
    converted to PNG.
- **Reading on macOS** asks nothing. An image held as TIFF, as most Mac
  apps copy one, is converted to PNG.
- **Files:** an image is copied from a file and pasted into one through
  `HostFiles`. `DarwinClipboard` configures `DarwinFiles`' directories when
  the app doesn't use `Files` itself.
- **`textSelection`** in the renderer is SwiftUI's own modifier
  (`SwiftUIRenderer.md` §4).

### 5.12 Text editing

`DarwinText` registers AppRuntime's `HostTextStorage` for the text
contract (AppRuntime's `Documentation/Contracts/TextEditor.md`).
`HostTextStorage` reads and writes files off the main thread, decodes and
encodes them, keeps `\n` as the only line break, moves positions out of
surrogate pairs, keeps whether the text is modified, and searches.
`DarwinText` gives it a text view per text, `TextViewEngine`:

- **The text is a text view's storage:** a `UITextView` or an `NSTextView`
  in its scroll view. It lives as long as the guest's `TextStorage`, on
  screen or not. A `TextEditor` node shows it by moving the view into its
  container; a second node naming the same text takes the view.
- **Every change is heard from the storage's delegate,** whoever made it.
  The storage reports a range widened by the attributes it fixes, so the
  exact change is taken from the view's should-change callback or the
  engine's own call when the lengths agree.
  - It's reported once the storage has finished processing, so the guest
    can edit again from its handler.
  - A change from somewhere that doesn't say when it's done, such as the
    platform's own undo menu, is reported on the next turn.
- **Undo:** the engine keeps the history itself, in an `UndoManager` of
  its own: each change with the text it removed, the user's and the
  guest's. UIKit's own typing undo doesn't stay on a history it's given
  (on the iOS Simulator it emptied it), so the text views register none.
  - A run of keystrokes is one step, up to a line break.
  - A guest's `replace` is a step of its own.
  - Undoing puts the selection back as it was before the step.
  - `setText` and a load empty the history, and so does a change the
    engine can't undo exactly.
  - On macOS the menu's Undo reaches the history through the text view's
    delegate. On iOS shaking to undo does nothing.
- **Line breaks:** what the user types or pastes with `\r\n` or `\r` is
  put in with `\n`, as the user's own edit.
- **Encodings** beyond the five are Foundation's, by IANA name through Core
  Foundation's table. Bytes that aren't valid, and characters the encoding
  lacks, are refused rather than replaced.
- **`maximumLength`** is 16 Mi UTF-16 units on iOS and 64 Mi on macOS.
- **The view** follows the node's `editable` and `wraps`, the inherited
  font (`FontSpec.platformFont`), and the keyboard modifiers through the
  environment. Its `focused` modifier makes it the first responder or
  resigns it, by the renderer's sync rule, and reports the user's moves.
- **The renderer** gains the `TextEditor` node, `focused` for every view
  SwiftUI focuses, and `autocorrection` and `autocapitalization`
  (`SwiftUIRenderer.md` §4).

Not done: `foregroundColor` and `tint` on a text view, which SwiftUI's
environment doesn't expose; wrapping turned off on iOS isn't checked with
TextKit 2.

### 5.13 Secrets and sign-in

Two modules, as AppRuntime has two (`Documentation/Contracts/Secrets.md`),
so an app that only keeps a password doesn't ask for a browser.

`DarwinSecrets` registers `HostSecrets`, which checks keys and sizes, runs
the store off the main thread in order, and answers on the main thread.
Its store, `KeychainStore`:

- **Generic passwords,** with the app's identifier as the service and the
  key as the account.
- **This device only:** `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
  or `…AfterFirstUnlockThisDeviceOnly`, so a secret isn't in a backup or
  synced. A `set` replaces the item whole, accessibility included.
- **Gone with the app:** iOS keeps Keychain items after an app is
  removed, so a marker in the host's own folder (`FileLocations.host`),
  which goes with the app, says whether this is the first run since
  installing. The store is emptied then.
- **macOS:** the data protection keychain, as on iOS, where the app is
  signed for it. Otherwise the login keychain, where accessibility doesn't
  apply. Which one is found on first use: deleting an item that isn't
  there is refused with `errSecMissingEntitlement` when it's not allowed.
- **Errors:** the user refusing is `notAllowed`; anything else, a locked
  device included, is `unavailable`.

`DarwinAuthentication` registers `HostWebAuthentication`, which refuses a
URL that isn't `https` and a redirect whose scheme the manifest doesn't
declare (`RTAuthenticationSchemes`), and shows one page at a time. Its
presenter, `SystemBrowser`:

- **`ASWebAuthenticationSession`,** over the app's key window, called back
  on the redirect's scheme, with `prefersEphemeralWebBrowserSession` for
  an ephemeral page. The redirect is the default, `scheme:/path`.
- **The result** is the whole callback URL. Closing the page is
  `canceledLogin`; a session that won't start, or has no window, is
  `notAllowed`.

The packager accepts `.secrets`, which needs no entitlement on a signed
app. A Simulator build gets the identifier the Simulator's Keychain wants
linked into its executable (`ManifestPackager.md`, step 7). A scheme needs
nothing in `Info.plist`: the session is given it when it starts.

### 5.14 Contacts

`DarwinContacts` registers `HostContacts` (`Documentation/Contracts/Contacts.md`),
which checks access before every call, refuses a write by an app that
declared reading alone (`RTCapabilityOptions.contacts.access` is
`readOnly`), refuses a contact with nothing in it, runs the directory off
the main thread in order, and gathers a burst of changes into one. Its
directory, `SystemAddressBook`, is the user's address book through
`CNContactStore`:

- **Everyone** comes from `enumerateContacts`, as unified people, with
  `sortOrder = .userDefault`: by family or given name, as the user set
  it.
- **A name** is `CNContactFormatter`'s `.fullName`. Without one, it's the
  organization, then an email address, then a phone number.
- **A search** is `predicateForContacts(matchingName:)`, the system's own,
  and then whoever has an email address that starts with the text.
- **A save** is a `CNSaveRequest`. A new person goes to the default
  account. A change is made on the person as fetched, so what a `Contact`
  doesn't carry, such as the photo and the note, is kept. A value that's
  there already with the same label and text is kept as it is, with its
  identifier and the platform's own label.
- **Labels:** the eight the contract names are `CNLabelHome` and its
  neighbours, both ways. The system's others, such as `iPhone`, reach the
  guest as the system's word for them. The user's own are their text.
- **Notes** need an entitlement Apple grants on request, so they're never
  fetched.
- **Errors:** `CNError` codes become `notAuthorized`, `notFound`,
  `readOnly` (a record or account that can't be written) and
  `invalidContact` (a validation error); anything else is `unknown`.

Access is `CNContactStore.authorizationStatus(for: .contacts)`, iOS 18's
`.limited` included, and the question is `requestAccess(for:)`. The app
reads the status again when it becomes active, as the user may have
changed it in Settings; when it changed, the guest is told the store did.
`CNContactStoreDidChange` is `storeChanged`.

The packager accepts `.contacts`, with `NSContactsUsageDescription` on
both platforms, and the macOS sandbox's
`com.apple.security.personal-information.addressbook`. `.readOnly`
changes nothing there: the host refuses the writes.

### 5.15 Photo library

`DarwinPhotos` registers `HostPhotos` (`Documentation/Contracts/Photos.md`),
which checks access before every call, keeps an app that declared adding
alone from reading (`RTCapabilityOptions.photoLibrary.access` is
`addOnly`), tells a photo from a video by the file's first bytes, holds
each fetch's identifiers and reads its assets a page at a time, makes an
original a read-only grant in `HostFiles`, and gathers a burst of changes
into one. Its store, `SystemPhotoLibrary`, is the user's library through
PhotoKit:

- **Adding** is a `PHAssetCreationRequest` with one resource, `.photo` or
  `.video`, copied from the file, which keeps its name. What PhotoKit
  refuses is `invalidData`.
- **A fetch** is `PHAsset.fetchAssets`, in an album or in the whole
  library, by `creationDate`, newest first, of images, videos or both:
  never audio, and never the hidden photos. Its identifiers are the
  assets' `localIdentifier`s, which last across launches.
- **An asset's** size is its `pixelWidth` and `pixelHeight`, and its
  duration is 0 for a photo.
- **Albums** are the user's own (regular, and those synced from a Mac) as
  `.user`, and the system's smart albums with something in them as
  `.smart`. Shared albums, the albums a sync makes of events and faces,
  Recents (the whole library) and the hidden photos aren't listed.
- **An original** is the asset's `.photo` or `.video` resource, not an
  edit of it and not a Live Photo's movie, written by
  `PHAssetResourceManager.writeData(for:toFile:options:)`, with network
  access allowed, to a folder of its own in the host's temporary
  directory. It keeps the library's name for it. Releasing it removes the
  folder.
- **Deleting** is `PHAssetChangeRequest.deleteAssets`, whose question is
  the system's. An identifier that's gone fails the whole deletion with
  `notFound`.
- **Errors:** PhotoKit's codes become `cancelledByUser`, `notAuthorized`,
  `unavailable` (a download that needs the network, or a library that went
  away), `notFound` and `invalidData`; anything else is `unknown`.

Access is `PHPhotoLibrary.authorizationStatus(for:)` at both levels: an
app that browses is `.addOnly` while it has been given adding and not yet
asked for reading, and one that only adds is never more. The question is
`requestAuthorization(for:)` at the level the manifest declares. The app
reads the status again when it becomes active; when it changed, the guest
is told the library did. A `PHPhotoLibraryChangeObserver` is registered
once the app may read, and its changes are `libraryChanged`.

**`Photo` nodes** are `PhotoViews`, which `DarwinPhotos` provides to the
renderer. Each asks a shared `PHCachingImageManager` for the asset at the
node's size in pixels, filling and cropping unless the node says `fit`,
in the opportunistic mode, which gives a small copy first and replaces it.
A node takes the space it's offered. One the app may not see, or whose
asset is gone, draws nothing.

The packager accepts `.photoLibrary`: `NSPhotoLibraryUsageDescription` and
`NSPhotoLibraryAddUsageDescription` for `.readWrite`, the add text alone
for `.addOnly`, on both platforms, and the macOS sandbox's
`com.apple.security.personal-information.photos-library`.

### 5.16 Camera

`DarwinCamera` registers `HostCameraCapture`
(`Documentation/Contracts/Camera.md`), which finds each file through
`HostFiles` and makes the folders above it, keeps one camera on, one photo
at a time and one recording, answers each request once, refuses sound
without `.microphone` in the manifest, clamps the zoom, remembers the
flash, and turns the camera off for the background and back on. Its
platform, `AVCameraPlatform`, is AVFoundation's cameras:

- **Positions** are the devices an `AVCaptureDevice.DiscoverySession`
  finds. On iOS the back camera is the widest virtual device there
  (`builtInTripleCamera`, `builtInDualWideCamera`, `builtInDualCamera`,
  then `builtInWideAngleCamera`), the front is the TrueDepth or wide angle
  camera, and an external camera is iPadOS 17's. On a Mac the built-in
  camera is the front one; any other, plugged in, a display's or an
  iPhone's through Continuity, is external. A Mac has no back camera.
- **Access** is `AVCaptureDevice.authorizationStatus(for:)`, for `.video`
  and for `.audio`, and the question is `requestAccess(for:)`. The
  module's permission providers replace the host's own camera one, and
  add the microphone's.

Each `CameraCapture` gets an `AVCameraEngine`: one `AVCaptureSession`,
configured, started and stopped on a queue of its own.

- **Starting** puts the position's device in the session with the
  `.photo` preset and an `AVCapturePhotoOutput`. Starting another
  position replaces the device.
- **Zoom:** the guest's 1 is the main lens. On a virtual device with an
  ultra wide, that's its first switch-over factor, so the range starts
  at 0.5; zooming crosses lenses by itself. The range ends at the
  device's maximum or 15 times the main lens, whichever is less. A Mac's
  camera doesn't zoom.
- **Photos** are JPEG, at the largest size the device's format makes
  (`maxPhotoDimensions`), with the flash if the camera has one. The
  output's connection is turned to how the device is held, so the file
  displays upright, and it isn't mirrored. The size reported is the
  upright picture's, read back from the file.
- **Video** adds an `AVCaptureMovieFileOutput` with the `.high` preset,
  and the microphone if sound was asked for, for as long as the
  recording lasts. On iOS the video is H.264. The movie is written to a
  temporary file, then rewrapped as MP4 at the place asked for, without
  being encoded again; one that can't be rewrapped is kept as a
  QuickTime movie, and `mimeType` says so. A recording the system cut
  short (an interruption, a camera unplugged, a full disk) is still
  kept, with the reason.
- **Interruptions** (`AVCaptureSessionWasInterrupted` and
  `InterruptionEnded`) are the system taking the camera: a call, another
  app, Split View. Leaving the front isn't one of them: the module
  reports that itself from `UIApplication`'s background and foreground
  notifications. A Mac app isn't suspended: its camera goes off while
  the app is hidden. A session runtime error fails the camera, except
  the media services restarting, which restarts the session.

**`CameraPreview` nodes** are `CameraPreviews`, which `DarwinCamera`
provides to the renderer: an `AVCaptureVideoPreviewLayer` on the
camera's session, filling and cropping unless the node says `fit`, and
turned with the interface. AVFoundation mirrors the front camera's
picture. A tap sets the focus and exposure point; on iOS a pinch zooms,
and the camera reports the zoom to the guest. The preview shows nothing
while the camera is off.

The packager accepts `.microphone`: `NSMicrophoneUsageDescription`, the
`microphone` device capability when it's required, and the macOS
sandbox's `com.apple.security.device.audio-input`. `.camera` was there
already.

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
