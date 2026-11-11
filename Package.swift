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
        .library(name: "DarwinFormatting", targets: ["DarwinFormatting"]),
        .library(name: "DarwinUI", targets: ["DarwinUI"]),
        // The app's main: links every module. The packager links it with
        // the app's library.
        .library(name: "DarwinHostApp", type: .static, targets: ["DarwinHostApp"]),
        .executable(name: "darwin-app", targets: ["DarwinAppTool"]),
    ],
    dependencies: [
        appRuntime,
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
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
        .target(
            name: "DarwinFormatting",
            dependencies: ["DarwinHost", runtime("DynamicFormatting")],
            swiftSettings: host
        ),

        // MARK: - SwiftUI renderer

        .target(
            name: "DarwinUI",
            dependencies: ["DarwinHost", runtime("DynamicUI")],
            swiftSettings: host
        ),

        // MARK: - App

        .target(
            name: "DarwinHostApp",
            dependencies: [
                "DarwinHost", "DarwinBluetooth", "DarwinLocation", "DarwinMotion", "DarwinNFC",
                "DarwinDevice", "DarwinNetworking", "DarwinFormatting", "DarwinUI", runtime("CRuntime"),
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
        .testTarget(name: "DarwinFormattingTests", dependencies: ["DarwinFormatting"], swiftSettings: host),
        .testTarget(name: "DarwinUITests", dependencies: ["DarwinUI"], swiftSettings: host),
        .testTarget(name: "DarwinPackagerTests", dependencies: ["DarwinPackager"]),
        .testTarget(name: "DarwinHostAppTests", dependencies: ["DarwinHostApp", "DarwinPackager"], swiftSettings: host),
    ]
)
