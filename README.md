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

**Status:** design. Nothing here is implemented yet. The changes it needed
in AppRuntime have landed, including the portable manifest stage.

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
