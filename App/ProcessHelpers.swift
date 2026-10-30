import Foundation

// MARK: - Process helpers (run external commands)

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

struct ProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

/// Runs a process synchronously, then wraps it in an async call.
func runProcessAsync(_ launchPath: String, _ args: [String]) async -> ProcessResult {
    await withCheckedContinuation { (cont: CheckedContinuation<ProcessResult, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launchPath)
            p.arguments = args

            let out = Pipe()
            let err = Pipe()
            p.standardOutput = out
            p.standardError = err

            do {
                try p.run()
            } catch {
                cont.resume(returning: ProcessResult(stdout: "", stderr: error.localizedDescription, exitCode: -1))
                return
            }

            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()

            cont.resume(returning: ProcessResult(
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "",
                exitCode: p.terminationStatus
            ))
        }
    }
}
