# DarwinAppRuntime

The iOS and macOS host for [AppRuntime](https://github.com/PureSwift/AppRuntime)
apps. An AppRuntime app is guest code only: a universal bundle with
`App.wasm` and native `libapp.a` slices. This repository is everything that
turns one into an app that runs on Apple platforms:

- the **host runtime**: `main`, the runtime core behind `rt.h`, the engines
  (native slice, wasm2c, and WasmKit for development) and the contract
  implementations over CoreBluetooth, CoreLocation, CoreMotion, CoreNFC,
  UIKit, URLSession and Foundation;
- the **SwiftUI renderer**, the player that turns the SwiftUI frontend's
  render IR into native views and sends user input back;
- the **packager**, `darwin-app`, which turns a universal bundle into a
  signed `.app` or `.ipa`.

**Status:** implemented. AppRuntime's `ExampleUI` packages with `darwin-app`
and runs in the iOS Simulator: it renders, and taps, typing, the lazy list
and navigation all reach the guest and back. It also packages and launches on
macOS. Framework paths that need hardware (Bluetooth, NFC, motion, location
fixes) are unit-tested through their mappings, and haven't run on a device.
Each design document lists where the implementation differs.

| Document | |
|---|---|
| [Host runtime](Documentation/HostRuntime.md) | Process model, engines, modules, start-up, contract implementations, threading, security |
| [SwiftUI renderer](Documentation/SwiftUIRenderer.md) | How the player maps the render IR to SwiftUI: store, nodes, modifiers, events and control sync, lazy rows, navigation |
| [Manifest and packager](Documentation/ManifestPackager.md) | `App.swift`, the portable manifest stage, and `darwin-app`'s pipeline: engine choice, linking, `Info.plist` and entitlements, signing |
| [Changes needed in AppRuntime](Documentation/AppRuntimeChanges.md) | What landed in AppRuntime first: host builds of `DynamicRuntime`, lower platform minimums, built-in contracts, simulator slices, the manifest stage, a shared wasm2c shim |

Targets iOS 15+ and macOS 12+, the oldest deployment targets current Xcode
accepts and AppRuntime's own minimums. AppRuntime's `ios-arm64`,
`ios-simulator` and `macos` slices are stamped lower, so they load on all of
them.

## Modules

| Module | |
|---|---|
| `DarwinHost` | Startup (`AppHost`), the app's `Info.plist` keys, the `Clock`, and the `Permissions`, `Bundle` and `Application` built-ins |
| `DarwinBluetooth`, `DarwinLocation`, `DarwinMotion`, `DarwinNFC`, `DarwinDevice`, `DarwinNetworking`, `DarwinFormatting` | The contract implementations over CoreBluetooth, CoreLocation, CoreMotion, CoreNFC, UIKit / IOKit, URLSession and Foundation |
| `DarwinUI` | The SwiftUI renderer |
| `DarwinHostApp` | The app's `main`: a SwiftUI app that starts the guest and shows its renderer |
| `DarwinPackager`, `darwin-app` | The packager |

## Building

The Swift 6.4.2 toolchain is pinned in `.swift-version`. AppRuntime comes
from GitHub; to build against a local checkout instead:

```sh
export APPRUNTIME_PATH=~/Developer/AppRuntime
```

```sh
swift build
swift test
```

## Packaging an app

Build a universal bundle with AppRuntime's `Scripts/guest.py bundle`, then:

```sh
swift build --product darwin-app
.build/out/Products/Debug/darwin-app validate App.app --platform ios-simulator
.build/out/Products/Debug/darwin-app run App.app --platform ios-simulator
.build/out/Products/Debug/darwin-app package App.app --platform ios --sign "Apple Distribution: …" --profile App.mobileprovision
```

`run` needs a booted simulator. Packaging builds the host for the platform
in `.build/darwin-app/<platform>` (about 1.3 GB). `--engine wasm2c`
translates `App.wasm` instead of using a native slice, which needs WABT
(`brew install wabt`) and AppRuntime's checkout (`APPRUNTIME_PATH` or
`--appruntime`).
