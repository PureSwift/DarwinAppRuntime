import Foundation
import Testing
@testable import DarwinPackager

@Suite struct EngineTests {

    let temporary = try! TemporaryDirectory()

    func bundle(without paths: [String] = []) throws -> UniversalBundle {
        var fixture = FixtureBundle()
        for path in paths {
            fixture.files[path] = nil
        }
        return try fixture.read(in: temporary.url)
    }

    @Test func prefersTheSlice() throws {
        let bundle = try bundle()
        for platform in ApplePlatform.allCases {
            #expect(try EngineChoice.choose(for: bundle, platform: platform, requested: nil, configuration: .release).engine == .native)
        }
    }

    @Test func fallsBackToWasm2c() throws {
        let bundle = try bundle(without: ["lib/ios-arm64/libapp.a"])
        #expect(try EngineChoice.choose(for: bundle, platform: .ios, requested: nil, configuration: .release).engine == .wasm2c)
        #expect(try EngineChoice.choose(for: bundle, platform: .macos, requested: nil, configuration: .release).engine == .native)
        #expect(throws: PackagerError.self) {
            try EngineChoice.choose(for: bundle, platform: .ios, requested: .native, configuration: .release)
        }
    }

    @Test func honorsTheRequest() throws {
        let bundle = try bundle()
        #expect(try EngineChoice.choose(for: bundle, platform: .macos, requested: .wasm2c, configuration: .release).engine == .wasm2c)
    }

    @Test func needsSomething() throws {
        let bundle = try bundle(without: ["lib/macos/libapp.a", "wasm32/App.wasm"])
        #expect(throws: PackagerError.self) {
            try EngineChoice.choose(for: bundle, platform: .macos, requested: nil, configuration: .debug)
        }
        #expect(throws: PackagerError.self) {
            try EngineChoice.choose(for: bundle, platform: .ios, requested: .wasm2c, configuration: .debug)
        }
    }

    @Test func refusesTheInterpreter() throws {
        let bundle = try bundle()
        #expect {
            try EngineChoice.choose(for: bundle, platform: .macos, requested: .interpreter, configuration: .release)
        } throws: { ($0 as? PackagerError)?.message.contains("debug builds only") == true }
        #expect {
            try EngineChoice.choose(for: bundle, platform: .macos, requested: .interpreter, configuration: .debug)
        } throws: { ($0 as? PackagerError)?.message.contains("DarwinWasmHost") == true }
    }

    @Test func runsWasm2cShim() throws {
        let build = Wasm2cBuild(
            appRuntime: URL(fileURLWithPath: "/src/AppRuntime"),
            wasm: URL(fileURLWithPath: "/work/bundle/wasm32/App.wasm"),
            output: URL(fileURLWithPath: "/work/wasm2c"),
            platform: .iosSimulator,
            architectures: ["arm64"],
            deploymentTarget: "15.0"
        )
        #expect(build.command == Command("python3", [
            "/src/AppRuntime/Scripts/wasm2c-shim.py", "build",
            "--wasm", "/work/bundle/wasm32/App.wasm", "--output", "/work/wasm2c",
            "--target", "arm64-apple-ios15.0-simulator", "--sdk", "iphonesimulator",
            "--define", "RT_WASM2C_WRITE_FUNCTION=darwin_rt_write",
        ]))
        #expect(build.library.path == "/work/wasm2c/libapp.a")
        let macos = Wasm2cBuild(
            appRuntime: build.appRuntime, wasm: build.wasm, output: build.output,
            platform: .macos, architectures: ["arm64", "x86_64"], deploymentTarget: "12.0"
        )
        #expect(macos.command.arguments.suffix(8) == [
            "--target", "arm64-apple-macos12.0", "--target", "x86_64-apple-macos12.0", "--sdk", "macosx",
            "--define", "RT_WASM2C_WRITE_FUNCTION=darwin_rt_write",
        ])
    }

    @Test func findsAppRuntime() throws {
        #expect(throws: PackagerError.self) {
            try Wasm2cBuild.appRuntime(option: nil, environment: [:])
        }
        #expect(throws: PackagerError.self) {
            try Wasm2cBuild.appRuntime(option: "/nonexistent", environment: [:])
        }
        let directory = try TemporaryDirectory()
        try FileManager.default.createDirectory(at: directory.file("Scripts"), withIntermediateDirectories: true)
        try Data().write(to: directory.file("Scripts/wasm2c-shim.py"))
        #expect(try Wasm2cBuild.appRuntime(option: nil, environment: ["APPRUNTIME_PATH": directory.url.path]).path == directory.url.standardizedFileURL.path)
    }
}
