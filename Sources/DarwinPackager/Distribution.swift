import Foundation

/// Where an app's files go (step 6): iOS apps are flat, `App.app/…`; macOS
/// apps are `App.app/Contents/{MacOS,Resources,Info.plist}`.
public struct AppLayout: Equatable, Sendable {

    public var app: URL

    public var platform: ApplePlatform

    public init(app: URL, platform: ApplePlatform) {
        self.app = app
        self.platform = platform
    }

    public var contents: URL {
        platform.isMac ? app.appendingPathComponent("Contents") : app
    }

    public var executableDirectory: URL {
        platform.isMac ? contents.appendingPathComponent("MacOS") : app
    }

    public var resources: URL {
        platform.isMac ? contents.appendingPathComponent("Resources") : app
    }

    public var infoPlist: URL {
        contents.appendingPathComponent("Info.plist")
    }

    public var pkgInfo: URL {
        contents.appendingPathComponent("PkgInfo")
    }

    /// Where the provisioning profile is embedded.
    public var embeddedProfile: URL {
        platform.isMac
            ? contents.appendingPathComponent("embedded.provisionprofile")
            : app.appendingPathComponent("embedded.mobileprovision")
    }

    public func executable(named name: String) -> URL {
        executableDirectory.appendingPathComponent(name)
    }
}

/// Step 8: the `.ipa`, notarization, and installing and launching.
public enum Distribution {

    /// Zips `Payload/App.app` into an `.ipa`. `payload` is the `Payload`
    /// directory holding the app.
    public static func ipa(payload: URL, output: URL) -> Command {
        Command("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", payload.path, output.path])
    }

    /// Zips the app for `notarytool`.
    public static func zipForNotarization(app: URL, output: URL) -> Command {
        Command("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, output.path])
    }

    /// Submits the zip and waits for the result, with credentials stored by
    /// `notarytool store-credentials`.
    public static func notarize(zip: URL, keychainProfile: String) -> Command {
        Command("xcrun", ["notarytool", "submit", zip.path, "--keychain-profile", keychainProfile, "--wait"], streamsOutput: true)
    }

    /// Staples the ticket to the app.
    public static func staple(app: URL) -> Command {
        .xcrun("stapler", "staple", app.path)
    }

    /// Installs the app on a simulator, `booted` by default.
    public static func simulatorInstall(app: URL, device: String) -> Command {
        .xcrun("simctl", "install", device, app.path)
    }

    /// Launches the app on a simulator, streaming its output until it
    /// exits. `--terminate-running-process` replaces a running copy.
    public static func simulatorLaunch(bundleIdentifier: String, device: String) -> Command {
        Command("xcrun", ["simctl", "launch", "--console-pty", "--terminate-running-process", device, bundleIdentifier], streamsOutput: true)
    }

    /// Lists the booted simulators.
    public static func bootedSimulators() -> Command {
        .xcrun("simctl", "list", "devices", "booted")
    }

    /// Runs a macOS app's executable directly, so its output streams to the
    /// terminal. The kernel applies the app's sandbox as when it's opened
    /// from Finder.
    public static func macLaunch(executable: URL) -> Command {
        Command(executable.path, [], streamsOutput: true)
    }
}
