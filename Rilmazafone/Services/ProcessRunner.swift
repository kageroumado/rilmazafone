import Foundation

/// Shared utility for running external processes asynchronously with structured concurrency.
nonisolated enum ProcessRunner {
    nonisolated struct ProcessResult {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    nonisolated struct ProcessError: Error, LocalizedError {
        let executable: String
        let arguments: [String]
        let exitCode: Int32
        let stderr: String

        var errorDescription: String? {
            "\(executable) failed (exit \(exitCode)): \(stderr)"
        }
    }

    /// Runs an executable and returns the result.
    /// Throws `ProcessError` if the exit code is non-zero.
    @discardableResult
    static func run(
        _ executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            if let currentDirectory {
                process.currentDirectoryURL = currentDirectory
            }

            // Drain pipe data concurrently to avoid deadlock when output exceeds
            // the pipe buffer size (~64KB). Without this, the process blocks writing
            // to a full pipe and never terminates.
            //
            // Safety: nonisolated(unsafe) is required because readabilityHandler closures
            // and terminationHandler run on different threads. However, access is safe:
            // readabilityHandler only appends, and terminationHandler first nils out the
            // handlers (stopping appends), then calls readDataToEndOfFile() synchronously.
            // Process.waitUntilExit()/terminationHandler provides the synchronization barrier.
            nonisolated(unsafe) var stdoutData = Data()
            nonisolated(unsafe) var stderrData = Data()
            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            stdoutHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { stdoutData.append(chunk) }
            }
            stderrHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { stderrData.append(chunk) }
            }

            process.terminationHandler = { _ in
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                stdoutData.append(stdoutHandle.readDataToEndOfFile())
                stderrData.append(stderrHandle.readDataToEndOfFile())

                let exitCode = process.terminationStatus

                if exitCode != 0 {
                    let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: ProcessError(
                        executable: executable,
                        arguments: arguments,
                        exitCode: exitCode,
                        stderr: stderrString,
                    ))
                } else {
                    continuation.resume(returning: ProcessResult(
                        stdout: stdoutData,
                        stderr: stderrData,
                        exitCode: exitCode,
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Convenience that runs a process and returns stdout as a String, trimming whitespace.
    static func runString(
        _ executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
    ) async throws -> String {
        let result = try await run(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
        )
        return String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
