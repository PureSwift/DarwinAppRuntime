/// A platform `darwin-app` packages for (`ManifestPackager.md` §3).
public enum ApplePlatform: String, CaseIterable, Sendable {

    /// An iPhone or iPad.
    case ios

    /// The iOS Simulator on this Mac.
    case iosSimulator = "ios-simulator"

    case macos
}

public extension ApplePlatform {

    /// The universal bundle's slice for the platform: `lib/<target>/libapp.a`.
    var sliceTarget: String {
        switch self {
        case .ios: "ios-arm64"
        case .iosSimulator: "ios-simulator"
        case .macos: "macos"
        }
    }

    /// The platform's name in the manifest's `RTPlatforms`. The simulator
    /// uses iOS's.
    var manifestName: String {
        switch self {
        case .ios, .iosSimulator: "ios"
        case .macos: "macos"
        }
    }

    /// The SDK, for `xcrun --sdk`, `actool --platform` and wasm2c-shim's
    /// `--sdk`.
    var sdk: String {
        switch self {
        case .ios: "iphoneos"
        case .iosSimulator: "iphonesimulator"
        case .macos: "macosx"
        }
    }

    /// The oldest OS DarwinAppRuntime supports, its `Package.swift`
    /// minimum.
    var hostMinimum: String {
        switch self {
        case .ios, .iosSimulator: "15.0"
        case .macos: "12.0"
        }
    }

    /// The platform's name for the linker's `-platform_version`.
    var linkerName: String {
        switch self {
        case .ios: "ios"
        case .iosSimulator: "ios-simulator"
        case .macos: "macos"
        }
    }

    /// The `LC_BUILD_VERSION` platform: `PLATFORM_IOS`, … in
    /// `<mach-o/loader.h>`.
    var machOPlatform: UInt32 {
        switch self {
        case .ios: 2
        case .iosSimulator: 7
        case .macos: 1
        }
    }

    /// `CFBundleSupportedPlatforms`.
    var supportedPlatformName: String {
        switch self {
        case .ios: "iPhoneOS"
        case .iosSimulator: "iPhoneSimulator"
        case .macos: "MacOSX"
        }
    }

    /// Whether the app is a macOS bundle, `App.app/Contents/…`.
    var isMac: Bool {
        self == .macos
    }

    /// The `Info.plist` key of the minimum OS.
    var minimumOSKey: String {
        isMac ? "LSMinimumSystemVersion" : "MinimumOSVersion"
    }

    /// The target triple of one architecture, such as
    /// `arm64-apple-ios15.0-simulator`.
    func triple(architecture: String, minimum: String) -> String {
        switch self {
        case .ios: "\(architecture)-apple-ios\(minimum)"
        case .iosSimulator: "\(architecture)-apple-ios\(minimum)-simulator"
        case .macos: "\(architecture)-apple-macos\(minimum)"
        }
    }
}

/// The Mac's own architecture, which simulator builds target.
public enum HostArchitecture {

    public static var current: String {
        #if arch(x86_64)
        "x86_64"
        #else
        "arm64"
        #endif
    }
}

/// `debug` or `release`, as in `swift build -c`.
public enum BuildConfiguration: String, CaseIterable, Sendable {

    case debug

    case release
}
