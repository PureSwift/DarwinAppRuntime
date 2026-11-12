import Foundation
import Testing
@testable import DarwinPackager

@Suite struct SliceInspectorTests {

    static let nm = """

        /b/lib/macos/libapp.a(app-x86_64.o) (for architecture x86_64):
        _abort
        _rt_call
        _memcpy

        /b/lib/macos/libapp.a(app-arm64.o) (for architecture arm64):
        _abort
        _rt_call
        ___stack_chk_fail
        ___udivti3
        """

    static let otool = """
        Archive : /b/lib/ios-simulator/libapp.a (architecture x86_64)
        /b/lib/ios-simulator/libapp.a(app-x86_64.o) (architecture x86_64):
        Load command 0
              cmd LC_SEGMENT_64
          cmdsize 312
        Load command 1
              cmd LC_BUILD_VERSION
          cmdsize 24
         platform 7
            minos 13.0
              sdk n/a
        Archive : /b/lib/ios-simulator/libapp.a (architecture arm64)
        /b/lib/ios-simulator/libapp.a(app-arm64.o) (architecture arm64):
        Load command 1
              cmd LC_BUILD_VERSION
          cmdsize 24
         platform IOSSIMULATOR
            minos 14.0
              sdk 26.0
        """

    @Test func parsesUndefinedSymbols() {
        #expect(SliceInspector.parseUndefined(Self.nm) == ["abort", "rt_call", "memcpy", "__stack_chk_fail", "__udivti3"])
    }

    @Test func parsesBuildVersions() {
        let versions = SliceInspector.parseBuildVersions(Self.otool)
        #expect(versions == [
            .init(object: "libapp.a(app-x86_64.o) (architecture x86_64)", platform: 7, minimum: "13.0"),
            .init(object: "libapp.a(app-arm64.o) (architecture arm64)", platform: 7, minimum: "14.0"),
        ])
    }

    func report(symbols: Set<String> = ["rt_call", "malloc"], platform: UInt32 = 7, minimum: String = "13.0", architectures: [String] = ["arm64", "x86_64"]) -> SliceInspector.Report {
        SliceInspector.Report(
            architectures: architectures,
            undefinedSymbols: symbols,
            buildVersions: architectures.map { .init(object: "app-\($0).o", platform: platform, minimum: minimum) }
        )
    }

    @Test func acceptsACleanSlice() {
        #expect(SliceInspector.check(report(), platform: .iosSimulator, architectures: ["arm64"], deploymentTarget: "15.0", engine: .native) == [])
    }

    @Test func rejectsOtherSymbols() {
        let diagnostics = SliceInspector.check(
            report(symbols: ["rt_call", "objc_msgSend", "$s5Swift5printyy", "glClear"]),
            platform: .iosSimulator, architectures: ["arm64"], deploymentTarget: "15.0", engine: .native
        )
        #expect(diagnostics == [.error("the library leaves symbols undefined that only rt_* and libc may: $s5Swift5printyy, glClear, objc_msgSend")])
    }

    @Test func acceptsWasmRuntimeSymbolsFromWasm2cOnly() {
        let symbols: Set<String> = ["rt_call", "mmap", "pthread_mutex_lock", "__stderrp", "darwin_rt_write"]
        #expect(SliceInspector.check(report(symbols: symbols), platform: .iosSimulator, architectures: ["arm64"], deploymentTarget: "15.0", engine: .wasm2c) == [])
        #expect(SliceInspector.check(report(symbols: symbols), platform: .iosSimulator, architectures: ["arm64"], deploymentTarget: "15.0", engine: .native).hasErrors)
    }

    @Test func acceptsCompilerRuntimeHelpers() {
        #expect(SliceInspector.isCompilerRuntime("__udivti3"))
        #expect(SliceInspector.isCompilerRuntime("__floatundidf"))
        #expect(!SliceInspector.isCompilerRuntime("__cxa_throw"))
        #expect(!SliceInspector.isCompilerRuntime("udivti3"))
    }

    @Test func rejectsOtherPlatforms() {
        let diagnostics = SliceInspector.check(report(platform: 2), platform: .iosSimulator, architectures: ["arm64"], deploymentTarget: "15.0", engine: .native)
        #expect(diagnostics.count == 2)
        #expect(diagnostics[0].message == "app-arm64.o is built for iOS, not iOS Simulator")
    }

    @Test func rejectsAHigherMinimum() {
        let diagnostics = SliceInspector.check(report(platform: 1, minimum: "14.0", architectures: ["arm64"]), platform: .macos, architectures: ["arm64"], deploymentTarget: "12.0", engine: .native)
        #expect(diagnostics == [.error("app-arm64.o needs macOS 14.0, above the app's minimum 12.0")])
    }

    @Test func rejectsMissingArchitectures() {
        let diagnostics = SliceInspector.check(report(platform: 1, minimum: "11.0", architectures: ["x86_64"]), platform: .macos, architectures: ["arm64"], deploymentTarget: "12.0", engine: .native)
        #expect(diagnostics == [.error("the library has x86_64, not arm64, which macos needs")])
    }

    @Test func runsTheTools() throws {
        let runner = RecordingRunner()
        runner.answerSliceQueries(platform: .ios, architectures: ["arm64"])
        let diagnostics = try SliceInspector(runner: runner).check(
            URL(fileURLWithPath: "/b/libapp.a"), platform: .ios, architectures: ["arm64"], deploymentTarget: "15.0", engine: .native
        )
        #expect(diagnostics == [])
        #expect(runner.lines == ["xcrun lipo -archs /b/libapp.a", "xcrun nm -u /b/libapp.a", "xcrun otool -l /b/libapp.a"])
    }
}
