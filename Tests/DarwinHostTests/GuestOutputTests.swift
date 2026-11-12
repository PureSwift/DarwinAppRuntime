import Testing
@testable import DarwinHost

@Suite("Guest output", .serialized)
struct GuestOutputTests {

    init() {
        GuestOutput.reset()
    }

    func lines(_ text: String, fd: Int32 = 1) -> [String] {
        Array(text.utf8).withUnsafeBytes { GuestOutput.lines(appending: $0, fd: fd) }
    }

    @Test func splitsLines() {
        #expect(lines("one\ntwo\n") == ["one", "two"])
        #expect(lines("\n") == [""])
    }

    @Test func keepsAnUnfinishedLineUntilItsNewline() {
        #expect(lines("wasm2c: ") == [])
        #expect(lines("guest trapped") == [])
        #expect(lines("\nnext") == ["wasm2c: guest trapped"])
        #expect(lines("\n") == ["next"])
    }

    @Test func eachStreamHasItsOwnLine() {
        #expect(lines("out", fd: 1) == [])
        #expect(lines("err\n", fd: 2) == ["err"])
        #expect(lines("\n", fd: 1) == ["out"])
    }

    @Test func splitsOverlongLines() {
        let long = String(repeating: "a", count: GuestOutput.maximumLine + 2)
        #expect(lines(long + "\n") == [String(repeating: "a", count: GuestOutput.maximumLine), "aa"])
    }

    @Test func theShimsFunctionLogs() {
        let text = Array("from the guest\n".utf8)
        text.withUnsafeBytes { darwin_rt_write(1, $0.baseAddress, $0.count) }
        darwin_rt_write(1, nil, 0)
        #expect(lines("") == [])
    }
}
