import Foundation

/// The app icon (`ManifestPackager.md` §4.3): one 1024×1024 PNG, compiled by
/// `actool` from a generated asset catalog. iOS uses the single-size app
/// icon format; macOS has none, so its icon set has the ten classic sizes,
/// scaled from the PNG.
public struct IconCompiler {

    /// The app icon set's name, and the `--app-icon` `actool` builds.
    public static let iconName = "AppIcon"

    public var platform: ApplePlatform

    public var deploymentTarget: String

    public init(platform: ApplePlatform, deploymentTarget: String) {
        self.platform = platform
        self.deploymentTarget = deploymentTarget
    }

    /// The macOS icon sizes, in points, each at 1x and 2x. macOS has no
    /// single-size app icon in asset catalogs, so the packager scales the
    /// PNG with `sips`.
    public static let macSizes = [16, 32, 128, 256, 512]

    /// One image of the icon set: its file and, on macOS, its pixel size.
    public struct Image: Equatable, Sendable {

        public var filename: String

        /// The size to scale the PNG to; `nil` for the original.
        public var pixels: Int?

        public var entry: [String: String]
    }

    public var images: [Image] {
        if !platform.isMac {
            return [Image(filename: "icon.png", pixels: nil, entry: [
                "filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024",
            ])]
        }
        return Self.macSizes.flatMap { size in
            [1, 2].map { scale in
                let filename = "icon_\(size)x\(size)@\(scale)x.png"
                return Image(filename: filename, pixels: size * scale == 1024 ? nil : size * scale, entry: [
                    "filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)",
                ])
            }
        }
    }

    /// The app icon set's `Contents.json`.
    public var iconSetContents: [String: Any] {
        ["images": images.map(\.entry), "info": ["author": "darwin-app", "version": 1]]
    }

    /// Writes `Assets.xcassets/AppIcon.appiconset` with the icon into
    /// `directory`, scaling it with `sips` for macOS; returns the catalog.
    public func writeCatalog(icon: URL, in directory: URL, runner: any CommandRunner) throws -> URL {
        let fileManager = FileManager.default
        let catalog = directory.appendingPathComponent("Assets.xcassets")
        if fileManager.fileExists(atPath: catalog.path) {
            try fileManager.removeItem(at: catalog)
        }
        let set = catalog.appendingPathComponent("\(Self.iconName).appiconset")
        try fileManager.createDirectory(at: set, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["info": ["author": "darwin-app", "version": 1]], options: [.prettyPrinted, .sortedKeys])
            .write(to: catalog.appendingPathComponent("Contents.json"))
        try JSONSerialization.data(withJSONObject: iconSetContents, options: [.prettyPrinted, .sortedKeys])
            .write(to: set.appendingPathComponent("Contents.json"))
        for image in images {
            let destination = set.appendingPathComponent(image.filename)
            if let pixels = image.pixels {
                try runner.check(Self.scale(icon, to: pixels, output: destination))
            } else {
                try fileManager.copyItem(at: icon, to: destination)
            }
        }
        return catalog
    }

    /// Scales a PNG with `sips`.
    public static func scale(_ icon: URL, to pixels: Int, output: URL) -> Command {
        Command("sips", ["-z", "\(pixels)", "\(pixels)", icon.path, "--out", output.path])
    }

    /// Compiles the catalog into `resources`, writing the icon's
    /// `Info.plist` keys to `partialInfoPlist`.
    public func compile(catalog: URL, into resources: URL, partialInfoPlist: URL) -> Command {
        var arguments = [
            "actool", catalog.path,
            "--compile", resources.path,
            "--platform", platform.sdk,
            "--minimum-deployment-target", deploymentTarget,
            "--app-icon", Self.iconName,
            "--output-partial-info-plist", partialInfoPlist.path,
        ]
        if platform.isMac {
            arguments += ["--target-device", "mac"]
        } else {
            arguments += ["--target-device", "iphone", "--target-device", "ipad"]
        }
        arguments += ["--errors", "--warnings", "--output-format", "human-readable-text"]
        return .xcrun(arguments)
    }
}
