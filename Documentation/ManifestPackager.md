# Manifest and packager — Design

**Status:** the portable stage (§1) is implemented in AppRuntime
(PureSwift/AppRuntime#32), and `darwin-app` (§2 on) here, except `dev` and
`xcodeproj`. Differences from the design below:

- **The host is built per app** from a generated SwiftPM package that links
  `DarwinHostApp` with the app's library, instead of a prebuilt
  `DarwinHost.a` (§5). The work directory is reused between builds.
  iOS builds cross-compile with `swift build --triple … --sdk …`, and pass
  `-platform_version` so the binary records the real SDK version.
- **Contracts the host lacks** are errors; `--allow-missing-contracts`
  makes them warnings, and the guest then sees them as absent.
- **Slice checks** read `LC_BUILD_VERSION` with `otool -l`, since `vtool`
  rejects archives.
- **The macOS icon** is an icon set rendered with `sips`: `actool` ignores a
  single-size icon on macOS.
- **NFC on macOS** is always an error, even when optional.
- **`dev`** waits on `DarwinWasmHost` (`HostRuntime.md` §11).

Packaging has two stages, in two repositories:

1. **Portable manifest (AppRuntime).** The app's `App.swift` (§7.1) becomes
   the portable keys of the universal bundle's `Info.plist`, and the build
   checks it against the contracts the guest uses (§7.3). Every host reads
   this; nothing in it is Apple-specific.
2. **Darwin packager (`darwin-app`, here).** A universal bundle becomes a
   signed iOS or macOS app: slice selection or wasm2c, linking with the host
   runtime, the translated `Info.plist`, entitlements, icons, the privacy
   manifest, signing (§7.6).

The app's build never produces a platform app, and the platform packager
never compiles guest Swift. That split is what lets apps and hosts update
independently (§7.5).

## 1. `App.swift`

The manifest is Swift, like `Package.swift`, so it's type-checked and
autocompleted:

```swift
import AppManifest

let app = App(
    id: "org.pureswift.blescanner",
    name: .localized("app.name"),
    version: "1.4.0", build: 42,
    languages: ["en", "es"],
    product: "BLEScanner",
    capabilities: [
        .bluetooth(usage: .localized("perm.bluetooth")),
        .location(.whenInUse, usage: .localized("perm.location")),
    ],
    platforms: [.iOS("15.0"), .macOS("12.0"), .android(minSDK: 26, targetSDK: 35), .linux],
    icon: "AppIcon.png",
    apple: .init(category: .utilities, extraInfoPlist: [:])
)
```

- **`AppManifest`** is a small, full-Swift library in AppRuntime with the
  manifest's types, with no dependencies, not even Foundation.
  Platform-only settings live in escape hatches: `apple:` (`category`,
  `extraInfoPlist`) and `android:` (`extraManifest`).
- **Reading it.** `guest.py bundle --manifest App.swift` compiles
  `App.swift` with `AppManifest` into a throwaway executable for the build
  machine, and runs it, the way SwiftPM evaluates `Package.swift`. The
  executable prints `app.manifestJSON()`: JSON with sorted keys. It runs
  sandboxed: on macOS under `sandbox-exec`, with no network and no writes
  outside a temporary directory; on Linux under `unshare --user --net`
  where that's allowed.
- **Localized strings.** `.localized("key")` refers to
  `resources/<language>.lproj/Manifest.strings` in the app's resources (by
  default, the `resources` folder next to `App.swift`). The stage fails if
  a key is missing for any language in `languages`.
- **The CLI flags** that `guest.py bundle` takes (`--id`, `--name`,
  `--version`, …) stay as a manifest-free path, and override the manifest's
  fields. `--capability` with a manifest is an error, since capabilities
  need usage texts.
- **Targets.** Without `--target`, the bundle has the slices of the
  manifest's platforms, plus `App.wasm`.

### 1.1 What the stage writes

The universal bundle's `Info.plist` gets the portable keys:

- `CFBundleIdentifier`, `CFBundleName`, `CFBundleDisplayName`;
- `CFBundleShortVersionString`, `CFBundleVersion`;
- `CFBundleLocalizations`, `CFBundleDevelopmentRegion` (the first
  language);
- `RTABIVersion`, `RTTargets`, `RTCapabilities`, `RTContracts`;
- `RTPlatforms`: per platform, `Minimum` (Apple) or `MinSDK` and
  `TargetSDK` (Android);
- `RTCapabilityUsage`: each capability's usage-text key in
  `Manifest.strings`;
- `RTCapabilityOptions`: capability settings, such as location's `access`
  (`whenInUse` or `always`);
- `RTDisplayNameKey`: the name's key, when it's localized.
  `CFBundleDisplayName` holds its value in the first language;
- `RTIcon`: `icon.png`, when there's an icon;
- `RTPlatformExtras`: the escape hatches, passed through untouched.

Localized values stay in `resources/<language>.lproj/Manifest.strings`,
which hosts translate into their own string files. A usage text written out
in the manifest gets the key `RTCapabilityUsage.<capability>`, added to
every language's file. The same JSON is embedded in the `rt.manifest`
section of every slice (§10): a Mach-O or ELF section, or a wasm custom
section. A host can check the manifest before linking, even with only a
slice in hand.

### 1.2 Checks (§7.3)

| Check | Result |
|---|---|
| A contract in `rt.contracts` requires a capability the manifest doesn't declare | error: iOS kills an app that touches a protected API without its usage string |
| A declared capability that no contract requires | warning: unused permissions are a common App Review rejection |
| A usage string missing for a language | error |
| A platform's minimum OS below its slice's minimum (`ios-arm64` and `ios-simulator`: iOS 13; `macos`: 10.15) | error |
| `id` not a reverse-DNS identifier; `version` not 1–3 dot-separated integers; `build` not positive | error |
| An unknown or repeated platform; Android's `targetSDK` below its `minSDK` | error |
| No icon | warning |

### 1.3 Settings beyond the proposal

The packager reads some settings the proposal didn't have. `AppManifest`
writes them:

- the capabilities `.motion(usage:)`, `.nfc(usage:)` and
  `.localNetwork(usage:)` (§4.1);
- `.required()` on a capability (§4.1), the option `required`;
- `.notifications(remote: true)`, the option `remote`, for `aps-environment`;
- `apple: .init(privacy: […])`, the app's data collection and tracking
  (§6).

`Pedometer`, `Altimeter` and `ActivityRecognizer` require `motion`, and the
NFC `Reader` requires `nfc`. `MotionManager` requires nothing: raw sensor
data needs no permission.

## 2. `darwin-app`

`darwin-app` is a command-line tool (macOS) built from this repository:

```sh
darwin-app validate  App.rtapp --platform ios
darwin-app package   App.rtapp --platform ios --configuration release \
                     --sign "Apple Distribution: …" --profile App.mobileprovision --output App.ipa
darwin-app package   App.rtapp --platform macos --configuration release --sign "Developer ID Application: …" --notarize
darwin-app run       App.rtapp --platform ios-simulator   # build, install, launch, stream logs
darwin-app dev       App.rtapp --platform macos           # interpreter host with hot reload
darwin-app xcodeproj App.rtapp --platform ios             # an Xcode project for debugging the host and guest
```

It uses the Xcode toolchain through `xcrun` (`clang`, `swiftc`, `ld`,
`actool`, `ibtool`, `codesign`, `notarytool`). It never needs an Xcode
project to package. `xcodeproj` exists for debugging with Xcode's UI.

## 3. Pipeline

`package` works on a copy of the bundle:

1. **Verify.** Check every file against `_CodeSignature/CodeResources`,
   and the bundle's own signature when the bundle was signed.
2. **Check compatibility** with this host version:
   - `RTABIVersion` ≤ the host's ABI version;
   - each contract in `RTContracts` registered, with a version ≤ the
     host's;
   - every capability supported on the platform.

   For example, `nfc` on macOS is an error, unless the app marks NFC
   optional (§4).
3. **Choose the engine** (`HostRuntime.md` §2.1):

   | Platform | Native slice | No slice |
   |---|---|---|
   | `ios` (device) | `ios-arm64` | wasm2c |
   | `ios-simulator` | `ios-simulator` (arm64 + x86_64) | wasm2c |
   | `macos` | `macos` (arm64 + x86_64) | wasm2c |

   `--engine interpreter` (WasmKit) is accepted only with
   `--configuration debug`, and only for iOS 18+ / macOS 15+, which are
   WasmKit's minimums.
4. **wasm2c, when there's no slice.** Run AppRuntime's
   `Scripts/wasm2c-shim.py build --wasm App.wasm --target … --sdk …`:
   - it translates `App.wasm` to C with WABT's wasm2c, so packaging needs
     WABT (`brew install wabt`);
   - it generates the import shim, which copies between guest memory and
     the host and calls the `rt_*` functions, plus a minimal WASI preview 1.
     The packager passes `--define RT_WASM2C_WRITE_FUNCTION=darwin_rt_write`,
     so the guest's stdout and stderr go to DarwinHost's `darwin_rt_write`,
     which logs them with `os_log` (category `app`), and echoes them to a
     terminal, such as `darwin-app run`'s console;
   - it compiles both with WABT's runtime at `-O2`, and seals them into a
     `libapp.a` with the same `rt_main` / `rt_dispatch` / `rt_finalize` and
     metadata sections as a native slice. The rest of the pipeline is the
     same.
5. **Link.** `swiftc` links the host runtime, its prebuilt static library
   `DarwinHost.a` (§5), with the slice or wasm2c objects, into the app's
   executable:
   - `-target arm64-apple-ios15.0` (`arm64-apple-ios15.0-simulator` and
     `x86_64-apple-ios15.0-simulator` for the simulator) /
     `-target arm64-apple-macos12.0` (plus x86_64 for a universal macOS
     executable, merged with `lipo`), or the manifest's higher minimum;
   - the SDK from `xcrun --show-sdk-path`;
   - `-dead_strip`.

   The guest's sealed object leaves only `rt_*` and a little libc
   undefined, so the link resolves it against the host runtime and
   libSystem. Before linking, the packager checks the slice's undefined
   symbols against the §7.5 set and its `LC_BUILD_VERSION` against the
   platform. Swift Concurrency is in the OS from iOS 15 / macOS 12, so no
   back-deployment libraries are copied.
6. **Assemble the app.**
   - iOS: a flat `App.app/`.
   - macOS: `App.app/Contents/{MacOS,Resources}`.
   - Write the translated `Info.plist` (§4), `PkgInfo` and the `.lproj`
     folders (§4.2).
   - Copy the bundle's `resources/`.
   - Compile the icon (§4.3).
   - Write the privacy manifest (§6).
7. **Sign.**
   - The entitlements are generated from the capabilities (§4.1).
   - iOS device builds embed the provisioning profile.
   - `codesign --entitlements … --sign …`. macOS builds add
     `--options runtime`, for the hardened runtime that notarization needs.
   - Simulator builds sign ad hoc (`-`).
8. **Package.**
   - iOS: an `.ipa` (`Payload/App.app`, zipped).
   - macOS: the `.app`, optionally notarized with `notarytool` and stapled.
   - Uploading to App Store Connect is out of scope; Transporter or
     `altool` takes the `.ipa`.

Output is reproducible for the same bundle, host version and signing
identity. The packager caches link results by the hash of the slice and the
host runtime.

## 4. Translation to Apple keys

| Portable | iOS `Info.plist` | macOS `Info.plist` |
|---|---|---|
| id | `CFBundleIdentifier` | same |
| name | `CFBundleDisplayName`, `CFBundleName`; localized in `InfoPlist.strings` | same |
| version / build | `CFBundleShortVersionString` / `CFBundleVersion` | same |
| languages | `CFBundleLocalizations`, `CFBundleDevelopmentRegion` (the first language) | same |
| executable | `CFBundleExecutable` | same |
| minimum OS | `MinimumOSVersion` | `LSMinimumSystemVersion` |
| — | `CFBundlePackageType` `APPL`, `UIDeviceFamily` [1, 2], `UIApplicationSceneManifest` (one scene), `UILaunchScreen` (§4.3), `UIRequiredDeviceCapabilities` (§4.1) | `CFBundlePackageType` `APPL`, `NSPrincipalClass` `NSApplication`, `LSApplicationCategoryType` (`apple.category`) |
| icon | `CFBundleIcons` from the asset catalog | `CFBundleIconFile` / `CFBundleIconName` |
| — | `RT…` keys, copied for the host's start-up checks (`HostRuntime.md` §4) | same |
| `apple.extraInfoPlist` | merged last; an extra key that conflicts with a generated key is an error | same |

### 4.1 Capabilities

| Capability | iOS `Info.plist` | iOS entitlements | macOS |
|---|---|---|---|
| `bluetooth` | `NSBluetoothAlwaysUsageDescription` | — | the same key; sandbox: `com.apple.security.device.bluetooth` |
| `location(.whenInUse)` | `NSLocationWhenInUseUsageDescription` | — | `NSLocationUsageDescription`; sandbox: `com.apple.security.personal-information.location` |
| `location(.always)` | the when-in-use key and `NSLocationAlwaysAndWhenInUseUsageDescription` | — | the same as when-in-use |
| `motion` | `NSMotionUsageDescription` | — | — |
| `nfc` | `NFCReaderUsageDescription`; `com.apple.developer.nfc.readersession.iso7816.select-identifiers` and `….felica.systemcodes` from `apple:` extras | `com.apple.developer.nfc.readersession.formats` (`TAG`, plus `NDEF` when NDEF is used) | not supported |
| `network` | — (App Transport Security defaults) | — | sandbox: `com.apple.security.network.client` |
| `localNetwork` | `NSLocalNetworkUsageDescription`, `NSBonjourServices` from extras | — | — |
| `camera` | `NSCameraUsageDescription` | — | `NSCameraUsageDescription`; sandbox: `com.apple.security.device.camera` |
| `notifications` | — | `aps-environment` when remote | `com.apple.developer.aps-environment` |

- **Required or optional.** A capability is optional unless the manifest
  says `.required()`. A required one adds `UIRequiredDeviceCapabilities`
  (`bluetooth-le`, `nfc`, …), so the App Store hides the app from devices
  without the hardware.
- **Missing hardware.** An optional capability that the device lacks still
  packages; its contract reports unavailable at run time.
- **macOS sandbox.** macOS apps are always sandboxed (`com.apple.security.app-sandbox`),
  as the Mac App Store requires.
- **Background modes** are not generated. Apps that need them declare
  `UIBackgroundModes` in `apple.extraInfoPlist` until the contracts support
  background operation (`HostRuntime.md` §11).

### 4.2 Strings

Each language gets `<language>.lproj/InfoPlist.strings`, holding the display
name and every usage string, translated from the bundle's `Manifest.strings`
through `RTDisplayNameKey` and `RTCapabilityUsage`.
The app's own `Localizable.strings` and other resources are copied as they
are; the guest reads them through the `Bundle` contract.

### 4.3 Icon and launch screen

- **Icon.** The manifest's icon is one 1024×1024 PNG. `actool` builds an
  asset catalog from it, using the single-size app icon format.
- **Launch screen.** An empty `UILaunchScreen` dictionary (the system
  background).

## 5. The host runtime as a prebuilt library

The packager doesn't compile the host for each app. A release of this
repository ships `DarwinHost.a` per platform: iOS device, iOS Simulator and
macOS. It contains:

- every host module (`HostRuntime.md` §3), compiled for the minimum OS with
  Xcode's toolchain;
- a version number, written into the app as `RTHostVersion`, and the list of
  contract versions it implements, which `validate` and step 2 use.

App Store builds have to be linked with Xcode's toolchain and a current SDK.
The guest's objects are fine either way: they're sealed and carry no SDK
dependency, so the SDK version in the app comes from this link.

## 6. Privacy manifest

Apps need a `PrivacyInfo.xcprivacy` when they or their libraries use
"required reason" APIs. The packager writes one that merges:

- **The host runtime's declarations**, shipped with `DarwinHost.a`:
  - `NSPrivacyAccessedAPICategorySystemBootTime` (`35F9.1`), for `Clock.now`;
  - `NSPrivacyAccessedAPICategoryUserDefaults` (`CA92.1`), if the host keeps
    settings.
- **The app's data collection and tracking**, from `apple.privacy` in
  `App.swift`. The guest can't reach required-reason APIs except through
  contracts, so the host's declarations cover the rest.

## 7. Development loop

`darwin-app dev`:

1. builds a development host once, with `DarwinWasmHost` (WasmKit; macOS 15
   / iOS 18 Simulator), and launches it;
2. watches the app's `.build/guest/<product>/wasm32/App.wasm`;
3. sends a new module to the running host over a local socket;
4. the host tears down the guest and the renderer and starts the new
   module. There's no relink and no reinstall.

Guest state doesn't survive a reload in this version.

## 8. Open questions

- **Manifest location.** Should `App.swift` be a section of `Package.swift`
  (a custom product) instead of its own file? A separate file keeps
  `Package.swift` plain SwiftPM, but adds a second manifest.
- **Universal bundle signing.** Today `CodeResources` lists hashes without
  a signature. Signing the bundle itself would let a store or distributor
  check it before packaging.
- **The App Store and wasm2c output.** Translated code is ordinary compiled
  C, so §14's concerns don't apply. Keeping the interpreter out of release
  builds is enforced by the packager (step 3), not by convention.
