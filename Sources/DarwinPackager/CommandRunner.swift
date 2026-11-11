import Foundation

/// A command the packager runs: a tool of the Xcode toolchain, `swift build`,
/// a script.
///
/// Every external step goes through a `CommandRunner`, so tests can record
/// the commands instead of running them.
public struct Command: Equatable, Hashable, Sendable, CustomStringConvertible {

    /// An absolute path, or a name looked up in `PATH`.
    public var executable: String

    public var arguments: [String]

    /// Variables added to the packager's own environment.
    public var environment: [String: String]

    /// The working directory; `nil` for the packager's.
    public var directory: String?

    /// Whether the command's output goes straight to the terminal instead of
    /// being captured: for long builds and the app's own logs.
    public var streamsOutput: Bool

    public init(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        directory: String? = nil,
        streamsOutput: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.streamsOutput = streamsOutput
    }

    /// A tool of the selected Xcode, through `xcrun`.
    public static func xcrun(_ arguments: String...) -> Command {
        Command("xcrun", arguments)
    }

    /// A tool of the selected Xcode, through `xcrun`.
    public static func xcrun(_ arguments: [String]) -> Command {
        Command("xcrun", arguments)
    }

    /// The command as a shell would take it, for logs.
    public var description: String {
        var words = environment.keys.sorted().map { "\($0)=\(Self.quote(environment[$0]!))" }
        words.append(Self.quote(executable))
        words += arguments.map(Self.quote)
        let line = words.joined(separator: " ")
        if let directory {
            return "(cd \(Self.quote(directory)) && \(line))"
        }
        return line
    }

    static func quote(_ word: String) -> String {
        let plain = word.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_./=:,+@%".unicodeScalars.contains($0)
        }
        if plain && !word.isEmpty {
            return word
        }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// What a command printed, and how it exited.
public struct CommandOutput: Equatable, Sendable {

    public var status: Int32

    /// Empty when the command streamed its output.
    public var standardOutput: String

    /// Empty when the command streamed its output.
    public var standardError: String

    public init(status: Int32 = 0, standardOutput: String = "", standardError: String = "") {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// Runs commands. `ProcessRunner` runs them; tests record them.
public protocol CommandRunner: Sendable {

    /// Runs `command` to completion. A non-zero exit status is returned, not
    /// thrown; `check` throws.
    func run(_ command: Command) throws -> CommandOutput
}

public extension CommandRunner {

    /// Runs `command`, throwing when it exits with a non-zero status.
    @discardableResult
    func check(_ command: Command) throws -> CommandOutput {
        let output = try run(command)
        guard output.status == 0 else {
            var message = "\(command.executable) \(command.arguments.first ?? "") exited with status \(output.status)"
            let details = (output.standardError.isEmpty ? output.standardOutput : output.standardError)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !details.isEmpty {
                message += ":\n" + details
            }
            message += "\ncommand: \(command)"
            throw PackagerError(message)
        }
        return output
    }

    /// The trimmed standard output of a command that must succeed.
    func output(of command: Command) throws -> String {
        try check(command).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Progress messages: the steps and the commands they run.
public struct PackagerLog: Sendable {

    public var write: @Sendable (String) -> Void

    public init(_ write: @escaping @Sendable (String) -> Void) {
        self.write = write
    }

    /// Prints to standard error, so standard output stays the app's.
    public static let standardError = PackagerLog { message in
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    public static let silent = PackagerLog { _ in }

    /// A pipeline step.
    public func step(_ message: String) {
        write("==> \(message)")
    }

    public func info(_ message: String) {
        write("    \(message)")
    }

    public func diagnostic(_ diagnostic: Diagnostic) {
        write(diagnostic.description)
    }
}

/// Runs commands with `Process`, logging each one.
public struct ProcessRunner: CommandRunner {

    public var log: PackagerLog

    public init(log: PackagerLog = .standardError) {
        self.log = log
    }

    public func run(_ command: Command) throws -> CommandOutput {
        log.write("$ \(command)")
        let process = Process()
        if command.executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command.executable] + command.arguments
        }
        if !command.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { $1 }
        }
        if let directory = command.directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        if command.streamsOutput {
            try process.run()
            process.waitUntilExit()
            return CommandOutput(status: process.terminationStatus)
        }
        // Files instead of pipes, so a command that fills one stream while
        // the other is read can't block.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("darwin-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try outputHandle.close()
        try errorHandle.close()
        return CommandOutput(
            status: process.terminationStatus,
            standardOutput: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
            standardError: String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
        )
    }
}
