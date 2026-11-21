// swift-tools-version:6.4
import Foundation
import PackageDescription

/// The iOS and macOS host for AppRuntime apps (`Documentation/HostRuntime.md`).
///
/// AppRuntime comes without its `GuestExports` trait: the app's library, a
/// sealed slice or wasm2c output, defines `rt_dispatch` and `rt_finalize`,
/// and the host's own `DynamicRuntime` binds to the runtime directly.
///
/// `APPRUNTIME_PATH` points at a local AppRuntime checkout instead of
/// GitHub, for developing both at once.
let appRuntime: Package.Dependency = {
    if let path = ProcessInfo.processInfo.environment["APPRUNTIME_PATH"] {
        return .package(name: "AppRuntime", path: path, traits: [])
    }
    return .package(url: "https://github.com/PureSwift/AppRuntime.git", branch: "master", traits: [])
}()

func runtime(_ product: String) -> Target.Dependency {
    .product(name: product, package: "AppRuntime")
}

/// Host code is single-threaded on the main thread (§6.4), and the contract
/// protocols are nonisolated, so it uses the Swift 5 language mode, like
/// AppRuntime's own host-side targets.
let host: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "DarwinAppRuntime",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "DarwinHost", targets: ["DarwinHost"]),
        .library(name: "DarwinBluetooth", targets: ["DarwinBluetooth"]),
        .library(name: "DarwinLocation", targets: ["DarwinLocation"]),
        .library(name: "DarwinMotion", targets: ["DarwinMotion"]),
        .library(name: "DarwinNFC", targets: ["DarwinNFC"]),
        .library(name: "DarwinDevice", targets: ["DarwinDevice"]),
        .library(name: "DarwinNetworking", targets: ["DarwinNetworking"]),
        .library(name: "DarwinUI", targets: ["DarwinUI"]),
        .library(name: "DarwinWebKit", targets: ["DarwinWebKit"]),
        .library(name: "DarwinGraphics", targets: ["DarwinGraphics"]),
        .library(name: "DarwinFiles", targets: ["DarwinFiles"]),
        .library(name: "DarwinDefaults", targets: ["DarwinDefaults"]),
        .library(name: "DarwinModelStore", targets: ["DarwinModelStore"]),
        .library(name: "DarwinDocuments", targets: ["DarwinDocuments"]),
        .library(name: "DarwinNotifications", targets: ["DarwinNotifications"]),
        .library(name: "DarwinMedia", targets: ["DarwinMedia"]),
        .library(name: "DarwinBackgroundTasks", targets: ["DarwinBackgroundTasks"]),
        .library(name: "DarwinClipboard", targets: ["DarwinClipboard"]),
        // The app's main: links every module. The packager links it with
        // the app's library.
        .library(name: "DarwinHostApp", type: .static, targets: ["DarwinHostApp"]),
        .executable(name: "darwin-app", targets: ["DarwinAppTool"]),
    ],
    dependencies: [
        appRuntime,
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // The model store's Core Data backend, `CoreDataModel`. AppRuntime
        // depends on CoreModel itself.
        .package(url: "https://github.com/PureSwift/CoreModel.git", from: "2.11.1"),
    ],
    targets: [

        // MARK: - Host runtime

        .target(
            name: "DarwinHost",
            dependencies: [runtime("RuntimeCore"), runtime("RuntimeNative"), runtime("DynamicRuntime")],
            swiftSettings: host
        ),
        .target(
            name: "DarwinBluetooth",
            dependencies: ["DarwinHost", runtime("DynamicBluetooth"), runtime("RuntimeNative")],
            swiftSettings: host
        ),
        .target(
            name: "DarwinLocation",
            dependencies: ["DarwinHost", runtime("DynamicLocation")],
            swiftSettings: host
        ),
        .target(
            name: "DarwinMotion",
            dependencies: ["DarwinHost", runtime("DynamicMotion")],
            swiftSettings: host
        ),
        .target(
            name: "DarwinNFC",
            dependencies: ["DarwinHost", runtime("DynamicNFC"), runtime("RuntimeNative")],
            swiftSettings: host,
            linkerSettings: [.linkedFramework("CoreNFC", .when(platforms: [.iOS]))]
        ),
        .target(
            name: "DarwinDevice",
            dependencies: ["DarwinHost", runtime("DynamicDevice")],
            swiftSettings: host,
            linkerSettings: [
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("SystemConfiguration", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "DarwinNetworking",
            dependencies: ["DarwinHost", runtime("DynamicNetworking"), runtime("RuntimeNative")],
            swiftSettings: host
        ),

        // MARK: - SwiftUI renderer

        .target(
            name: "DarwinUI",
            dependencies: ["DarwinHost", runtime("DynamicUI")],
            swiftSettings: host
        ),

        // MARK: - Graphics

        // The gl* functions an app's executable defines over the system's,
        // and the host's own GL calls (`darwin_gl.h`).
        .target(
            name: "CDarwinGL",
            cSettings: [
                .define("GL_SILENCE_DEPRECATION"),
                .define("GLES_SILENCE_DEPRECATION"),
            ],
            linkerSettings: [
                .linkedFramework("OpenGLES", .when(platforms: [.iOS])),
                .linkedFramework("OpenGL", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "DarwinGraphics",
            dependencies: ["DarwinHost", "DarwinUI", "CDarwinGL", runtime("DynamicGraphics")],
            swiftSettings: host,
            linkerSettings: [.linkedFramework("QuartzCore")]
        ),

        // MARK: - Web views

        .target(
            name: "DarwinWebKit",
            dependencies: ["DarwinHost", "DarwinUI", runtime("DynamicWebKit")],
            swiftSettings: host,
            linkerSettings: [.linkedFramework("WebKit")]
        ),

        // MARK: - Files

        // AppRuntime's `HostFiles`, over the app container's directories.
        .target(
            name: "DarwinFiles",
            dependencies: ["DarwinHost", runtime("RuntimeHost"), runtime("DynamicFiles")],
            swiftSettings: host
        ),

        // MARK: - Defaults

        // AppRuntime's `HostDefaults`, over a `UserDefaults` suite.
        .target(
            name: "DarwinDefaults",
            dependencies: ["DarwinHost", runtime("RuntimeHost"), runtime("DynamicDefaults")],
            swiftSettings: host
        ),

        // MARK: - Model store

        // AppRuntime's `HostModelStore`, over Core Data stores in the app's
        // container.
        .target(
            name: "DarwinModelStore",
            dependencies: [
                "DarwinHost", "DarwinFiles", runtime("DynamicCoreModel"), runtime("RuntimeCoreModel"),
                .product(name: "CoreModel", package: "CoreModel"),
                .product(name: "CoreDataModel", package: "CoreModel"),
            ],
            swiftSettings: host
        ),

        // MARK: - Documents

        // AppRuntime's `HostDocuments`, over the platform's pickers and
        // bookmarks.
        .target(
            name: "DarwinDocuments",
            dependencies: [
                "DarwinHost", runtime("RuntimeHost"), runtime("RuntimeDocuments"),
                runtime("DynamicDocuments"), runtime("DynamicFiles"),
            ],
            swiftSettings: host
        ),

        // MARK: - Notifications

        // The notifications contracts: AppRuntime's `HostNotifications`
        // over `UNUserNotificationCenter`, and push through APNs.
        .target(
            name: "DarwinNotifications",
            dependencies: [
                "DarwinHost", runtime("RuntimeHost"), runtime("RuntimeNotifications"),
                runtime("DynamicNotifications"),
            ],
            swiftSettings: host
        ),

        // MARK: - Media

        // The media contracts: AppRuntime's `HostMediaPlayback` over
        // `AVPlayer`, what's playing in `MPNowPlayingInfoCenter`, and the
        // `VideoPlayer` node's view.
        .target(
            name: "DarwinMedia",
            dependencies: [
                "DarwinHost", "DarwinUI", "DarwinFiles", runtime("RuntimeMedia"), runtime("DynamicMedia"),
                runtime("RuntimeNative"),
            ],
            swiftSettings: host
        ),

        // MARK: - Background tasks

        // The background contract: AppRuntime's `HostBackgroundTasks` over
        // `BGTaskScheduler` (iOS) and `NSBackgroundActivityScheduler` (macOS).
        .target(
            name: "DarwinBackgroundTasks",
            dependencies: [
                "DarwinHost", "DarwinFiles", runtime("RuntimeBackgroundTasks"), runtime("DynamicBackgroundTasks"),
            ],
            swiftSettings: host
        ),

        // MARK: - Clipboard

        // The clipboard contract: AppRuntime's `HostClipboard` over
        // `UIPasteboard` (iOS) and `NSPasteboard` (macOS).
        .target(
            name: "DarwinClipboard",
            dependencies: ["DarwinHost", "DarwinFiles", runtime("RuntimeClipboard"), runtime("DynamicClipboard")],
            swiftSettings: host
        ),

        // MARK: - App

        .target(
            name: "DarwinHostApp",
            dependencies: [
                "DarwinHost", "DarwinBluetooth", "DarwinLocation", "DarwinMotion", "DarwinNFC",
                "DarwinDevice", "DarwinNetworking", "DarwinUI", "DarwinGraphics", "DarwinWebKit",
                "DarwinFiles", "DarwinDefaults", "DarwinModelStore", "DarwinDocuments", "DarwinNotifications", "DarwinMedia", "DarwinBackgroundTasks", "DarwinClipboard", runtime("RuntimeFormatting"), runtime("CRuntime"),
            ],
            swiftSettings: host
        ),

        // MARK: - Packager

        // The contract modules give `validate` the descriptors of what this
        // host implements. `RuntimeNative` defines the `rt_*` functions their
        // `DynamicRuntime` links against.
        .target(
            name: "DarwinPackager",
            dependencies: [
                runtime("RuntimeNative"), runtime("DynamicRuntime"), runtime("DynamicBluetooth"), runtime("DynamicLocation"),
                runtime("DynamicMotion"), runtime("DynamicNFC"), runtime("DynamicDevice"),
                runtime("DynamicNetworking"), runtime("DynamicFormatting"), runtime("DynamicUI"),
                runtime("DynamicGraphics"), runtime("DynamicWebKit"), runtime("DynamicFiles"),
                runtime("DynamicDefaults"), runtime("DynamicCoreModel"), runtime("DynamicDocuments"),
                runtime("DynamicNotifications"), runtime("DynamicMedia"), runtime("DynamicBackgroundTasks"),
                runtime("DynamicClipboard"),
            ]
        ),
        .executableTarget(
            name: "DarwinAppTool",
            dependencies: [
                "DarwinPackager",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // MARK: - Tests

        .testTarget(name: "DarwinHostTests", dependencies: ["DarwinHost"], swiftSettings: host),
        .testTarget(name: "DarwinBluetoothTests", dependencies: ["DarwinBluetooth"], swiftSettings: host),
        .testTarget(name: "DarwinLocationTests", dependencies: ["DarwinLocation"], swiftSettings: host),
        .testTarget(name: "DarwinMotionTests", dependencies: ["DarwinMotion"], swiftSettings: host),
        .testTarget(name: "DarwinNFCTests", dependencies: ["DarwinNFC"], swiftSettings: host),
        .testTarget(name: "DarwinDeviceTests", dependencies: ["DarwinDevice"], swiftSettings: host),
        .testTarget(name: "DarwinNetworkingTests", dependencies: ["DarwinNetworking"], swiftSettings: host),
        .testTarget(name: "DarwinUITests", dependencies: ["DarwinUI"], swiftSettings: host),
        .testTarget(name: "DarwinWebKitTests", dependencies: ["DarwinWebKit"], swiftSettings: host),
        .testTarget(name: "DarwinGraphicsTests", dependencies: ["DarwinGraphics"], swiftSettings: host),
        .testTarget(name: "DarwinFilesTests", dependencies: ["DarwinFiles"], swiftSettings: host),
        .testTarget(name: "DarwinDefaultsTests", dependencies: ["DarwinDefaults"], swiftSettings: host),
        .testTarget(name: "DarwinModelStoreTests", dependencies: ["DarwinModelStore", runtime("RuntimeNative")], swiftSettings: host),
        .testTarget(name: "DarwinDocumentsTests", dependencies: ["DarwinDocuments"], swiftSettings: host),
        .testTarget(name: "DarwinNotificationsTests", dependencies: ["DarwinNotifications", runtime("RuntimeNative")], swiftSettings: host),
        .testTarget(name: "DarwinMediaTests", dependencies: ["DarwinMedia"], swiftSettings: host),
        .testTarget(name: "DarwinBackgroundTasksTests", dependencies: ["DarwinBackgroundTasks"], swiftSettings: host),
        .testTarget(name: "DarwinClipboardTests", dependencies: ["DarwinClipboard"], swiftSettings: host),
        .testTarget(name: "DarwinPackagerTests", dependencies: ["DarwinPackager"]),
        .testTarget(name: "DarwinHostAppTests", dependencies: ["DarwinHostApp", "DarwinPackager"], swiftSettings: host),
    ]
)
