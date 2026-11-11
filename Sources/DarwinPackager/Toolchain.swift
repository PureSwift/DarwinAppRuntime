import Foundation

/// The SDK and Xcode the app is built with, for the link's SDK version and
/// the `DT…` keys of `Info.plist`.
public struct SDKInfo: Equatable, Sendable {

    /// `iphoneos`, `iphonesimulator` or `macosx`.
    public var name: String

    public var path: String

    /// Such as `27.2`.
    public var version: String

    /// Such as `24C5089c`.
    public var build: String

    /// Xcode's version, such as `27.2`.
    public var xcodeVersion: String

    /// Xcode's build, such as `27B52`.
    public var xcodeBuild: String

    public init(name: String, path: String, version: String, build: String, xcodeVersion: String, xcodeBuild: String) {
        self.name = name
        self.path = path
        self.version = version
        self.build = build
        self.xcodeVersion = xcodeVersion
        self.xcodeBuild = xcodeBuild
    }

    /// Asks `xcrun` and `xcodebuild` about the selected Xcode.
    public static func read(for platform: ApplePlatform, runner: any CommandRunner) throws -> SDKInfo {
        let path = try runner.output(of: .xcrun("--sdk", platform.sdk, "--show-sdk-path"))
        let version = try runner.output(of: .xcrun("--sdk", platform.sdk, "--show-sdk-version"))
        let build = try runner.output(of: .xcrun("--sdk", platform.sdk, "--show-sdk-build-version"))
        let xcode = try runner.output(of: .xcrun("xcodebuild", "-version"))
        var xcodeVersion = ""
        var xcodeBuild = ""
        for line in xcode.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Xcode ") {
                xcodeVersion = String(line.dropFirst("Xcode ".count))
            } else if line.hasPrefix("Build version ") {
                xcodeBuild = String(line.dropFirst("Build version ".count))
            }
        }
        return SDKInfo(name: platform.sdk, path: path, version: version, build: build, xcodeVersion: xcodeVersion, xcodeBuild: xcodeBuild)
    }

    /// `DTXcode`: `27.2` is `2720`, as Xcode writes it.
    public var xcodeNumber: String {
        let parts = xcodeVersion.split(separator: ".").map { Int($0) ?? 0 }
        let major = parts.first ?? 0
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        return String(format: "%02d%d%d", major, min(minor, 9), min(patch, 9))
    }

    /// The `DT…` keys Xcode writes into an app's `Info.plist`, which App
    /// Store validation reads.
    public func infoPlistKeys(platform: ApplePlatform) -> [String: Any] {
        [
            "CFBundleSupportedPlatforms": [platform.supportedPlatformName],
            "DTPlatformName": name,
            "DTPlatformVersion": version,
            "DTPlatformBuild": build,
            "DTSDKName": name + version,
            "DTSDKBuild": build,
            "DTXcode": xcodeNumber,
            "DTXcodeBuild": xcodeBuild,
        ]
    }
}
