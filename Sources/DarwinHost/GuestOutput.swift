import Foundation
import os

/// Where a wasm2c-translated app's stdout and stderr go (`ManifestPackager.md`
/// step 4). The packager builds it with
/// `--define RT_WASM2C_WRITE_FUNCTION=darwin_rt_write`, so the guest's writes
/// arrive at `darwin_rt_write` and are logged, a line per entry: stdout at
/// the default level, stderr as errors.
///
/// When the stream is a terminal, such as `darwin-app run`'s console, the
/// output is written there too.
public enum GuestOutput {

    public static let logger = Logger(subsystem: "org.pureswift.DarwinAppRuntime", category: "app")

    /// The longest line kept waiting for its newline; a longer one is logged
    /// in pieces.
    static let maximumLine = 4096

    private static let lock = NSLock()

    nonisolated(unsafe) private static var pending: [Int32: [UInt8]] = [:]

    /// Logs what the guest wrote to `fd`.
    public static func write(_ bytes: UnsafeRawBufferPointer, fd: Int32) {
        if isatty(fd) != 0, let base = bytes.baseAddress {
            _ = Darwin.write(fd, base, bytes.count)
        }
        for line in lines(appending: bytes, fd: fd) {
            if fd == 2 {
                logger.error("\(line, privacy: .public)")
            } else {
                logger.notice("\(line, privacy: .public)")
            }
        }
    }

    /// Adds what the guest wrote to `fd` to its unfinished line, and returns
    /// the lines it completed.
    static func lines(appending bytes: UnsafeRawBufferPointer, fd: Int32) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var buffer = pending[fd, default: []]
        var lines = [String]()
        for byte in bytes {
            if byte == UInt8(ascii: "\n") {
                lines.append(String(decoding: buffer, as: UTF8.self))
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
                if buffer.count == maximumLine {
                    lines.append(String(decoding: buffer, as: UTF8.self))
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
        pending[fd] = buffer
        return lines
    }

    /// Forgets unfinished lines. For tests.
    static func reset() {
        lock.lock()
        pending = [:]
        lock.unlock()
    }
}

/// The wasm2c shim's `RT_WASM2C_WRITE_FUNCTION`:
/// `void darwin_rt_write(int fd, const void *data, size_t size)`.
@_cdecl("darwin_rt_write")
public func darwin_rt_write(_ fd: Int32, _ data: UnsafeRawPointer?, _ size: Int) {
    guard let data, size > 0 else {
        return
    }
    GuestOutput.write(UnsafeRawBufferPointer(start: data, count: size), fd: fd)
}
