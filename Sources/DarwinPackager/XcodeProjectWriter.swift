import CryptoKit
import Foundation

/// The Xcode project `darwin-app xcodeproj` writes (§2): one app target,
/// built by Xcode from the same pieces `package` links, for debugging the
/// host and the guest with Xcode's UI.
///
/// ```
/// <output>/<Name>.xcodeproj
/// <output>/<Name>/main.swift          HostPackage.mainSwift
/// <output>/<Name>/Info.plist          translated (§4)
/// <output>/<Name>/<Name>.entitlements
/// <output>/<Name>/libapp.a            the slice or the wasm2c library
/// <output>/<Name>/Resources/…         strings, privacy manifest, icon, resources/
/// ```
///
/// The target depends on DarwinAppRuntime as a local package, for
/// `DarwinHostApp`, and links `libapp.a` with `OTHER_LDFLAGS`. The project is
/// for one platform, the one it was written for, since the library is.
public struct XcodeProjectWriter: Equatable, Sendable {

    /// The target, product and executable name: the bundle's
    /// `CFBundleExecutable`.
    public var name: String

    public var bundleIdentifier: String

    public var platform: ApplePlatform

    public var deploymentTarget: String

    /// The library's architectures.
    public var architectures: [String]

    /// DarwinAppRuntime's checkout.
    public var hostPackage: URL

    /// The directory the project and its files go in.
    public var directory: URL

    /// The top-level items of `<Name>/Resources`, which are copied into the
    /// app as they are.
    public var resources: [String]

    /// Whether `<Name>/<Name>.entitlements` has any.
    public var hasEntitlements: Bool

    /// The development team, for signing for a device or with restricted
    /// entitlements; without one the app is signed to run locally.
    public var team: String?

    public init(
        name: String,
        bundleIdentifier: String,
        platform: ApplePlatform,
        deploymentTarget: String,
        architectures: [String],
        hostPackage: URL,
        directory: URL,
        resources: [String],
        hasEntitlements: Bool,
        team: String? = nil
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.platform = platform
        self.deploymentTarget = deploymentTarget
        self.architectures = architectures
        self.hostPackage = hostPackage
        self.directory = directory
        self.resources = resources
        self.hasEntitlements = hasEntitlements
        self.team = team
    }

    public var project: URL {
        directory.appendingPathComponent("\(name).xcodeproj")
    }

    /// `<Name>/`, the target's files.
    public var support: URL {
        directory.appendingPathComponent(name)
    }

    public var entitlementsName: String {
        "\(name).entitlements"
    }

    // MARK: Build settings

    var sdkRoot: String {
        platform.isMac ? "macosx" : "iphoneos"
    }

    var deploymentTargetSetting: String {
        platform.isMac ? "MACOSX_DEPLOYMENT_TARGET" : "IPHONEOS_DEPLOYMENT_TARGET"
    }

    func projectSettings(debug: Bool) -> [String: Value] {
        var settings: [String: Value] = [
            "ALWAYS_SEARCH_USER_PATHS": "NO",
            "CLANG_ENABLE_MODULES": "YES",
            "SDKROOT": .string(sdkRoot),
            "SUPPORTED_PLATFORMS": .string(platform.sdk),
            deploymentTargetSetting: .string(deploymentTarget),
            "SWIFT_VERSION": "5.0",
        ]
        if debug {
            settings["DEBUG_INFORMATION_FORMAT"] = "dwarf"
            settings["ENABLE_TESTABILITY"] = "YES"
            settings["GCC_OPTIMIZATION_LEVEL"] = "0"
            settings["ONLY_ACTIVE_ARCH"] = "YES"
            settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
            settings["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone"
        } else {
            settings["DEBUG_INFORMATION_FORMAT"] = "dwarf-with-dsym"
            settings["SWIFT_COMPILATION_MODE"] = "wholemodule"
            settings["SWIFT_OPTIMIZATION_LEVEL"] = "-O"
        }
        return settings
    }

    var targetSettings: [String: Value] {
        var settings: [String: Value] = [
            "ARCHS": .string(architectures.joined(separator: " ")),
            "CODE_SIGN_STYLE": "Automatic",
            "DEVELOPMENT_TEAM": .string(team ?? ""),
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": .string("\(name)/Info.plist"),
            "OTHER_LDFLAGS": .array([.string("$(PROJECT_DIR)/\(name)/libapp.a")]),
            "PRODUCT_BUNDLE_IDENTIFIER": .string(bundleIdentifier),
            "PRODUCT_NAME": .string(name),
        ]
        if team == nil {
            // Sign to Run Locally.
            settings["CODE_SIGN_IDENTITY"] = "-"
        }
        if hasEntitlements {
            settings["CODE_SIGN_ENTITLEMENTS"] = .string("\(name)/\(entitlementsName)")
        }
        if platform.isMac {
            settings["LD_RUNPATH_SEARCH_PATHS"] = .array(["$(inherited)", "@executable_path/../Frameworks"])
        } else {
            settings["LD_RUNPATH_SEARCH_PATHS"] = .array(["$(inherited)", "@executable_path/Frameworks"])
            settings["TARGETED_DEVICE_FAMILY"] = "1,2"
        }
        return settings
    }

    /// DarwinAppRuntime's path from the project's directory.
    var hostPackagePath: String {
        Self.relativePath(from: directory, to: hostPackage)
    }

    static func relativePath(from base: URL, to target: URL) -> String {
        let from = base.standardizedFileURL.pathComponents
        let to = target.standardizedFileURL.pathComponents
        var common = 0
        while common < min(from.count, to.count), from[common] == to[common] {
            common += 1
        }
        guard common > 1 else {
            return target.standardizedFileURL.path
        }
        let up = Array(repeating: "..", count: from.count - common)
        let path = (up + to[common...]).joined(separator: "/")
        return path.isEmpty ? "." : path
    }

    // MARK: project.pbxproj

    /// A stable object ID: the same project comes out the same.
    func id(_ key: String) -> String {
        SHA256.hash(data: Data("\(name)/\(key)".utf8))
            .prefix(12)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    /// `project.pbxproj`.
    public var pbxproj: String {
        var objects = [(String, [(String, Value)])]()
        func add(_ key: String, _ fields: [(String, Value)]) -> Value {
            let id = id(key)
            objects.append((id, fields))
            return .string(id)
        }
        func file(_ path: String, type: String) -> Value {
            add("file:\(path)", [
                ("isa", "PBXFileReference"),
                ("lastKnownFileType", .string(type)),
                ("path", .string(path)),
                ("sourceTree", "<group>"),
            ])
        }
        func build(_ key: String, _ reference: Value) -> Value {
            add("build:\(key)", [("isa", "PBXBuildFile"), ("fileRef", reference)])
        }

        // Files.
        let main = file("main.swift", type: "sourcecode.swift")
        let info = file("Info.plist", type: "text.plist.xml")
        let library = file("libapp.a", type: "archive.ar")
        let entitlements = hasEntitlements ? file(entitlementsName, type: "text.plist.entitlements") : nil
        let resourceFiles = resources.map { resource in
            (resource, file(resource, type: Self.fileType(resource, in: support.appendingPathComponent("Resources"))))
        }
        let resourcesGroup = add("group:Resources", [
            ("isa", "PBXGroup"),
            ("children", .array(resourceFiles.map(\.1))),
            ("path", "Resources"),
            ("sourceTree", "<group>"),
        ])
        let appGroup = add("group:app", [
            ("isa", "PBXGroup"),
            ("children", .array([main, info, entitlements, library, resourcesGroup].compactMap { $0 })),
            ("path", .string(name)),
            ("sourceTree", "<group>"),
        ])
        let product = add("product", [
            ("isa", "PBXFileReference"),
            ("explicitFileType", "wrapper.application"),
            ("includeInIndex", "0"),
            ("path", .string("\(name).app")),
            ("sourceTree", "BUILT_PRODUCTS_DIR"),
        ])
        let productsGroup = add("group:Products", [
            ("isa", "PBXGroup"),
            ("children", .array([product])),
            ("name", "Products"),
            ("sourceTree", "<group>"),
        ])
        let mainGroup = add("group:main", [
            ("isa", "PBXGroup"),
            ("children", .array([appGroup, productsGroup])),
            ("sourceTree", "<group>"),
        ])

        // The package.
        let package = add("package", [
            ("isa", "XCLocalSwiftPackageReference"),
            ("relativePath", .string(hostPackagePath)),
        ])
        let hostApp = add("product:DarwinHostApp", [
            ("isa", "XCSwiftPackageProductDependency"),
            ("package", package),
            ("productName", "DarwinHostApp"),
        ])

        // Phases.
        let sources = add("phase:sources", [
            ("isa", "PBXSourcesBuildPhase"),
            ("buildActionMask", "2147483647"),
            ("files", .array([build("main.swift", main)])),
            ("runOnlyForDeploymentPostprocessing", "0"),
        ])
        let frameworks = add("phase:frameworks", [
            ("isa", "PBXFrameworksBuildPhase"),
            ("buildActionMask", "2147483647"),
            ("files", .array([add("build:DarwinHostApp", [("isa", "PBXBuildFile"), ("productRef", hostApp)])])),
            ("runOnlyForDeploymentPostprocessing", "0"),
        ])
        let resourcesPhase = add("phase:resources", [
            ("isa", "PBXResourcesBuildPhase"),
            ("buildActionMask", "2147483647"),
            ("files", .array(resourceFiles.map { build("Resources/\($0.0)", $0.1) })),
            ("runOnlyForDeploymentPostprocessing", "0"),
        ])

        // Configurations.
        func configurations(_ key: String, _ settings: (Bool) -> [String: Value]) -> Value {
            let list = ["Debug", "Release"].map { configuration in
                add("configuration:\(key):\(configuration)", [
                    ("isa", "XCBuildConfiguration"),
                    ("buildSettings", .dictionary(settings(configuration == "Debug"))),
                    ("name", .string(configuration)),
                ])
            }
            return add("configurations:\(key)", [
                ("isa", "XCConfigurationList"),
                ("buildConfigurations", .array(list)),
                ("defaultConfigurationIsVisible", "0"),
                ("defaultConfigurationName", "Debug"),
            ])
        }
        let target = add("target", [
            ("isa", "PBXNativeTarget"),
            ("buildConfigurationList", configurations("target") { _ in targetSettings }),
            ("buildPhases", .array([sources, frameworks, resourcesPhase])),
            ("buildRules", .array([])),
            ("dependencies", .array([])),
            ("name", .string(name)),
            ("packageProductDependencies", .array([hostApp])),
            ("productName", .string(name)),
            ("productReference", product),
            ("productType", "com.apple.product-type.application"),
        ])
        let root = add("project", [
            ("isa", "PBXProject"),
            ("attributes", .dictionary([
                "BuildIndependentTargetsInParallel": "1",
                "LastSwiftUpdateCheck": "1600",
                "LastUpgradeCheck": "1600",
            ])),
            ("buildConfigurationList", configurations("project", projectSettings)),
            ("compatibilityVersion", "Xcode 15.0"),
            ("developmentRegion", "en"),
            ("hasScannedForEncodings", "0"),
            ("knownRegions", .array(["en", "Base"])),
            ("mainGroup", mainGroup),
            ("packageReferences", .array([package])),
            ("productRefGroup", productsGroup),
            ("projectDirPath", ""),
            ("projectRoot", ""),
            ("targets", .array([target])),
        ])

        var text = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 60;\n\tobjects = {\n"
        for (id, fields) in objects.sorted(by: { $0.0 < $1.0 }) {
            text += "\t\t\(id) = {"
            for (key, value) in fields {
                text += "\(Value.quote(key)) = \(value.text(indent: 2)); "
            }
            text += "};\n"
        }
        text += "\t};\n\trootObject = \(root.text(indent: 1));\n}\n"
        return text
    }

    /// A resource's `lastKnownFileType`: a folder is copied as it is.
    static func fileType(_ name: String, in directory: URL) -> String {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "folder"
        }
        return "file"
    }

    // MARK: Scheme

    /// The shared scheme's file, `xcshareddata/xcschemes/<Name>.xcscheme` in
    /// the project. Without it Xcode makes one, but the app's would share
    /// its name with a package's scheme when a library has the app's name
    /// (such as AppRuntime's `ExampleUI`).
    public var schemeFile: URL {
        project.appendingPathComponent("xcshareddata/xcschemes/\(name).xcscheme")
    }

    /// Builds the app and runs it under the debugger.
    public var scheme: String {
        let reference = """
            <BuildableReference
                           BuildableIdentifier = "primary"
                           BlueprintIdentifier = "\(id("target"))"
                           BuildableName = "\(Self.xml(name)).app"
                           BlueprintName = "\(Self.xml(name))"
                           ReferencedContainer = "container:\(Self.xml(name)).xcodeproj">
                        </BuildableReference>
            """
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <Scheme
               LastUpgradeVersion = "1600"
               version = "1.7">
               <BuildAction
                  parallelizeBuildables = "YES"
                  buildImplicitDependencies = "YES">
                  <BuildActionEntries>
                     <BuildActionEntry
                        buildForTesting = "YES"
                        buildForRunning = "YES"
                        buildForProfiling = "YES"
                        buildForArchiving = "YES"
                        buildForAnalyzing = "YES">
                        \(reference)
                     </BuildActionEntry>
                  </BuildActionEntries>
               </BuildAction>
               <LaunchAction
                  buildConfiguration = "Debug"
                  selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
                  selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
                  launchStyle = "0"
                  useCustomWorkingDirectory = "NO"
                  ignoresPersistentStateOnLaunch = "NO"
                  debugDocumentVersioning = "YES"
                  debugServiceExtension = "internal"
                  allowLocationSimulation = "YES">
                  <BuildableProductRunnable
                     runnableDebuggingMode = "0">
                     \(reference)
                  </BuildableProductRunnable>
               </LaunchAction>
               <ProfileAction
                  buildConfiguration = "Release"
                  shouldUseLaunchSchemeArgsEnv = "YES"
                  savedToolIdentifier = ""
                  useCustomWorkingDirectory = "NO"
                  debugDocumentVersioning = "YES">
                  <BuildableProductRunnable
                     runnableDebuggingMode = "0">
                     \(reference)
                  </BuildableProductRunnable>
               </ProfileAction>
               <AnalyzeAction
                  buildConfiguration = "Debug">
               </AnalyzeAction>
               <ArchiveAction
                  buildConfiguration = "Release"
                  revealArchiveInOrganizer = "YES">
               </ArchiveAction>
            </Scheme>

            """
    }

    static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// An old-style property list value.
    enum Value: Equatable, Sendable, ExpressibleByStringLiteral {

        case string(String)
        case array([Value])
        case dictionary([String: Value])

        init(stringLiteral value: String) {
            self = .string(value)
        }

        func text(indent: Int) -> String {
            switch self {
            case .string(let value):
                return Self.quote(value)
            case .array(let values):
                return "(" + values.map { $0.text(indent: indent) + ", " }.joined() + ")"
            case .dictionary(let values):
                return "{" + values.keys.sorted().map { "\(Self.quote($0)) = \(values[$0]!.text(indent: indent)); " }.joined() + "}"
            }
        }

        static let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$/:.")

        static func quote(_ value: String) -> String {
            if !value.isEmpty, value.allSatisfy(plain.contains) {
                return value
            }
            var escaped = ""
            for character in value {
                switch character {
                case "\"": escaped += "\\\""
                case "\\": escaped += "\\\\"
                case "\n": escaped += "\\n"
                case "\t": escaped += "\\t"
                default: escaped.append(character)
                }
            }
            return "\"\(escaped)\""
        }
    }
}
